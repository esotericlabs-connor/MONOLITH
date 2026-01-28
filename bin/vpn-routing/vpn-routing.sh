#!/usr/bin/env bash
#
# /usr/local/bin/vpn-routing.sh
#
# Monolith VPN routing manager
#  - Scope: ONLY 10.100.0.0/24 (LAB on eth1)
#  - Priority: WireGuard (wg0) -> OpenVPN (tun0) -> BLACKHOLE (no WAN)
#  - Router itself + mgmt net (10.99.0.0/24) ALWAYS use eth0 (WAN).

set -euo pipefail

# ---------------- CONFIG ----------------

LAB_NET="10.100.0.0/24"     # LAB subnet to fully tunnel
LAB_GW="10.100.0.1"         # LAB default gateway (router's eth1 IP)
LAB_IF="eth1"               # LAB interface

WAN_IF="eth0"               # router WAN NIC
WAN_GW="10.150.250.1"       # upstream gateway on WAN

WG_IF="wg0"                 # WireGuard interface
OVPN_IF="tun0"              # OpenVPN interface

LAB_TABLE=100               # policy routing table for LAB
LAB_RULE_PRIO=1000          # ip rule priority for LAB (must be < 32766)

LOOP_SLEEP=10               # seconds between checks
LOG_TAG="[monolith-vpn]"

# ------------- HELPER FUNCTIONS ---------

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') MONOLITH-NET01 vpn-routing.sh ${LOG_TAG}: $*" >&2
}
# Check if a VPN interface is "usable":
#  - exists
#  - has an inet address
#  - can ping 1.1.1.1 using that interface

for i in {1..90}; do
    if ip link show tun0 >/dev/null 2>&1; then
        logger "[monolith-vpn] tun0 detected"
        break
    fi
    sleep 1
done

if ! ip link show tun0 >/dev/null 2>&1; then
    logger "[monolith-vpn] ERROR: tun0 never appeared"
    exit 1
fi

vpn_up() {
  local ifname="$1"

  # Interface exists?
  ip link show "$ifname" &>/dev/null || return 1

  # Has IPv4 address?
  ip -4 addr show dev "$ifname" | grep -q 'inet ' || return 1

  # Quick health check
  ping -I "$ifname" -c 2 -W 2 1.1.1.1 &>/dev/null || return 1

  return 0
}

cleanup_routes() {
    ip route del blackhole 10.100.0.0/24 2>/dev/null || true
    ip route del unreachable 10.100.0.0/24 2>/dev/null || true
}

# Ensure router itself always prefers WAN for its own traffic.
ensure_core_defaults() {
  # Remove any VPN defaults from the main table (if wg-quick/OpenVPN added one)
  ip route del default dev "$WG_IF" 2>/dev/null || true
  ip route del default dev "$OVPN_IF" 2>/dev/null || true

  # Ensure the WAN default route exists
  ip route replace default via "$WAN_GW" dev "$WAN_IF" onlink 2>/dev/null || true
}

# Ensure LAB policy base (table + rule) is present.
ensure_lab_base() {
  # Base routes in LAB table
  if ! ip route show table "$LAB_TABLE" | grep -q "$LAB_NET"; then
    ip route add "$LAB_NET" dev "$LAB_IF" src "$LAB_GW" table "$LAB_TABLE" 2>/dev/null || \
    ip route replace "$LAB_NET" dev "$LAB_IF" src "$LAB_GW" table "$LAB_TABLE"
  fi

  # Optional: local WAN subnet in LAB table (helps with local replies)
  if ! ip route show table "$LAB_TABLE" | grep -q "10.150.250.0/24"; then
    ip route add 10.150.250.0/24 dev "$WAN_IF" src 10.150.250.52 table "$LAB_TABLE" 2>/dev/null || true
  fi

  # Policy rule for LAB
  if ! ip rule show | grep -q "from $LAB_NET lookup $LAB_TABLE"; then
    # Clean any stale rule with same net/table first
    ip rule del from "$LAB_NET" lookup "$LAB_TABLE" 2>/dev/null || true
    ip rule add priority "$LAB_RULE_PRIO" from "$LAB_NET" lookup "$LAB_TABLE"
  fi
}

clear_lab_default() {
  ip route del default table "$LAB_TABLE" 2>/dev/null || true
  ip route del blackhole default table "$LAB_TABLE" 2>/dev/null || true
}

set_lab_default_via() {
  local dev="$1"
  clear_lab_default
  ip route add default dev "$dev" table "$LAB_TABLE" 2>/dev/null || \
  ip route replace default dev "$dev" table "$LAB_TABLE"
}

set_lab_blackhole() {
  clear_lab_default
  ip route add blackhole default table "$LAB_TABLE" 2>/dev/null || \
  ip route replace blackhole default table "$LAB_TABLE"
}


# ------------ STATUS OUTPUT --------------

show_status() {
  echo "=== Monolith VPN routing status ==="
  echo
  echo "Interfaces:"
  ip -4 addr show dev "$WAN_IF" 2>/dev/null || true
  ip -4 addr show dev "$LAB_IF" 2>/dev/null || true
  ip -4 addr show dev "$WG_IF" 2>/dev/null || true
  ip -4 addr show dev "$OVPN_IF" 2>/dev/null || true
  echo

  echo "Policy rules:"
  ip rule show
  echo

  echo "Main table:"
  ip route show table main
  echo

  echo "LAB table ($LAB_TABLE):"
  ip route show table "$LAB_TABLE" || echo "(empty)"
  echo

  echo "NAT rules (POSTROUTING):"
  iptables -t nat -S POSTROUTING 2>/dev/null || echo "(iptables-nft or no NAT rules)"
}
# ------------- MAIN LOOP ----------------

if [[ "${1:-}" == "--status" ]]; then
  show_status
  exit 0
fi

log "Starting Monolith VPN routing manager (WireGuard -> OpenVPN, LAB-only)."

# Initial setup
ensure_core_defaults
ensure_lab_base
set_lab_blackhole
log "LAB $LAB_NET initially blackholed (waiting for VPN availability)."

PREV_STATE="none"   # wg | ovpn | none

while true; do
  ensure_core_defaults
  ensure_lab_base

  local_state="none"

  if vpn_up "$WG_IF"; then
    local_state="wg"
  elif vpn_up "$OVPN_IF"; then
    local_state="ovpn"
  else
    local_state="none"
  fi

  if [[ "$local_state" != "$PREV_STATE" ]]; then
    case "$local_state" in
      wg)
        set_lab_default_via "$WG_IF"
        log "LAB $LAB_NET now routed via WireGuard ($WG_IF)."
        ;;
      ovpn)
        set_lab_default_via "$OVPN_IF"
        log "LAB $LAB_NET now routed via OpenVPN ($OVPN_IF)."
        ;;
      none)
        set_lab_blackhole
        log "Both VPNs unavailable; LAB $LAB_NET blackholed (no internet)."
        ;;
    esac
    PREV_STATE="$local_state"
  fi

  sleep "$LOOP_SLEEP"
done




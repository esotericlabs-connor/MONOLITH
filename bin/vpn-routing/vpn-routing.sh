#!/bin/bash
# MONOLITH Unified VPN Routing (WG → OVPN → Tor → WAN for router only)

set -euo pipefail

LAN_IF="eth1"
WAN_IF="eth0"
WG_IF="wg0"
OVPN_IF="tun0"
WAN_GW="10.150.250.1"

log() { echo "[vpn-routing] $*"; }

iface_up() { ip link show "$1" up >/dev/null 2>&1; }
iface_has_ipv4() { ip -4 addr show dev "$1" | grep -q "inet "; }

# -------------------------------
# Latency + jitter test
# -------------------------------
vpn_health_check() {
    local iface="$1"
    local target="1.1.1.1"

    # Generate 5 pings, parse output
    local result
    result=$(ping -I "$iface" -c 5 -W 1 "$target" 2>/dev/null || echo "fail")

    if [[ "$result" == "fail" ]]; then
        log "$iface health: ping failed"
        return 1
    fi

    local loss
    loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)')
    local avg
    avg=$(echo "$result" | grep -oP '(?<=avg = )[^/]+')
    local jitter
    jitter=$(echo "$result" | grep -oP '(?<=mdev = )[0-9.]+')

    log "$iface health: loss=${loss}% avg=${avg}ms jitter=${jitter}ms"

    # thresholds
    if (( loss > 40 )) || (( ${avg%.*} > 300 )) || (( ${jitter%.*} > 100 )); then
        log "$iface rejected: latency/jitter/loss too high"
        return 1
    fi

    log "$iface accepted as healthy"
    return 0
}

cleanup_defaults() {
    ip route del 0.0.0.0/1 2>/dev/null || true
    ip route del 128.0.0.0/1 2>/dev/null || true
    ip route del default 2>/dev/null || true
}

set_default_vpn() {
    local iface="$1"
    ip route add default dev "$iface" metric 50
    ip route add default via "$WAN_GW" dev "$WAN_IF" metric 500
}

set_default_wan() {
    ip route add default via "$WAN_GW" dev "$WAN_IF" metric 100
}

# -----------------------
# Tor routing setup
# -----------------------
enable_tor_redirects() {
    log "Enabling Tor transparent proxy routing..."

    # Clear older tor rules
    iptables -t nat -F TOR_OUT 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$LAN_IF" -j TOR_OUT 2>/dev/null || true
    iptables -t nat -X TOR_OUT 2>/dev/null || true

    iptables -t nat -N TOR_OUT

    # Redirect TCP to Tor TransPort
    iptables -t nat -A TOR_OUT -i "$LAN_IF" -p tcp -j REDIRECT --to-ports 9040

    # Redirect DNS to Tor DNSPort
    iptables -t nat -A TOR_OUT -i "$LAN_IF" -p udp --dport 53 -j REDIRECT --to-ports 5353

    # hook PREROUTING
    iptables -t nat -A PREROUTING -i "$LAN_IF" -j TOR_OUT
}

disable_tor_redirects() {
    iptables -t nat -F TOR_OUT 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$LAN_IF" -j TOR_OUT 2>/dev/null || true
    iptables -t nat -X TOR_OUT 2>/dev/null || true
}

# -----------------------
# Main logic
# -----------------------
sleep 2
log "Flushing conntrack..."
conntrack -F || true

MODE="wan"

# Prefer WireGuard
if iface_up "$WG_IF" && iface_has_ipv4 "$WG_IF"; then
    log "Checking WireGuard..."
    if vpn_health_check "$WG_IF"; then
        MODE="wireguard"
    fi
fi

# Try OpenVPN only if WG not selected
if [[ "$MODE" == "wan" ]]; then
    if iface_up "$OVPN_IF" && iface_has_ipv4 "$OVPN_IF"; then
        log "Checking OpenVPN..."
        if vpn_health_check "$OVPN_IF"; then
            MODE="openvpn"
        fi
    fi
fi

# Try Tor only if both VPNs fail
if [[ "$MODE" == "wan" ]]; then
    log "Testing Tor fallback..."

    # Test Tor by curling via SOCKS proxy
    if torify curl -s --max-time 4 https://check.torproject.org >/dev/null 2>&1; then
        log "Tor is online and reachable"
        MODE="tor"
    else
        log "Tor test failed"
    fi
fi

log "MODE chosen: $MODE"

cleanup_defaults
disable_tor_redirects

case "$MODE" in
    wireguard)
        disable_tor_redirects
        set_default_vpn "$WG_IF"
        ;;

    openvpn)
        disable_tor_redirects
        set_default_vpn "$OVPN_IF"
        ;;

    tor)
        log "Entering Tor fallback mode..."
        enable_tor_redirects
        set_default_wan   # router uses WAN but LAB uses Tor
        ;;

    wan)
        log "No VPN or Tor available → router WAN only"
        set_default_wan
        ;;
esac

log "Final routing table:"
ip route

log "vpn-routing DONE."


# EXTRA LEFT OVER code

# set -euo pipefail

# LAN_IF="eth1"
# WAN_IF="eth0"
# WG_IF="wg0"
# OVPN_IF="tun0"
# WAN_GW="10.150.250.1"   # adjust if your WAN gateway changes

# log() { echo "[vpn-routing] $*"; }

# iface_up() {
#     ip link show "$1" up >/dev/null 2>&1
# }

# iface_has_ipv4() {
#     ip -4 addr show dev "$1" | grep -q "inet "
# }

# # ---- Tor helpers (transparent proxy for LAN) ----

# enable_tor_redirects() {
#     log "Enabling Tor transparent proxy routing for $LAN_IF..."
#     iptables -t nat -F TOR_OUT 2>/dev/null || true
#     iptables -t nat -D PREROUTING -i "$LAN_IF" -j TOR_OUT 2>/dev/null || true
#     iptables -t nat -X TOR_OUT 2>/dev/null || true

#     iptables -t nat -N TOR_OUT
#     # redirect all LAN TCP to Tor TransPort
#     iptables -t nat -A TOR_OUT -i "$LAN_IF" -p tcp -j REDIRECT --to-ports 9040
#     # redirect LAN DNS to Tor DNSPort
#     iptables -t nat -A TOR_OUT -i "$LAN_IF" -p udp --dport 53 -j REDIRECT --to-ports 5353
#     iptables -t nat -A PREROUTING -i "$LAN_IF" -j TOR_OUT
# }

# disable_tor_redirects() {
#     iptables -t nat -F TOR_OUT 2>/dev/null || true
#     iptables -t nat -D PREROUTING -i "$LAN_IF" -j TOR_OUT 2>/dev/null || true
#     iptables -t nat -X TOR_OUT 2>/dev/null || true
# }

# tor_available() {
#     # consider Tor usable if service is active
#     systemctl is-active --quiet tor.service
# }

# # ---- Routing helpers ----

# cleanup_routes() {
#     log "Cleaning old default and split routes..."
#     ip route del 0.0.0.0/1 2>/dev/null || true
#     ip route del 128.0.0.0/1 2>/dev/null || true
#     ip route del default 2>/dev/null || true
# }

# set_default_vpn() {
#     local iface="$1"
#     log "Setting default via VPN interface $iface"
#     ip route add default dev "$iface" metric 50
#     ip route add default via "$WAN_GW" dev "$WAN_IF" metric 500 2>/dev/null || true
# }

# set_default_wan() {
#     local metric="${1:-100}"
#     log "Setting default via WAN $WAN_IF (metric $metric)"
#     ip route add default via "$WAN_GW" dev "$WAN_IF" metric "$metric" 2>/dev/null || true
# }

# # ---- Latency measurement ----
# # Returns: avg RTT in ms, or 999999 on failure

# measure_latency() {
#     local iface="$1"
#     local target="1.1.1.1"

#     if ! iface_up "$iface" || ! iface_has_ipv4 "$iface"; then
#         echo 999999
#         return 1
#     fi

#     # quiet ping (summary only)
#     local out
#     if ! out=$(ping -q -I "$iface" -c 4 -W 1 "$target" 2>/dev/null); then
#         echo 999999
#         return 1
#     fi

#     # parse the rtt line: rtt min/avg/max/mdev = 10.123/20.456/30.789/0.555 ms
#     local avg
#     avg=$(echo "$out" | awk -F'/' '/^rtt|^round-trip/ {print $5}' | tail -n1)

#     # strip decimals; fallback if empty
#     avg=${avg%.*}
#     [[ -z "$avg" ]] && avg=999999

#     echo "$avg"
#     return 0
# }

# # ---- main ----

# sleep 1
# log "Flushing conntrack..."
# conntrack -F || true

# log "Measuring WireGuard latency..."
# WG_LAT=$(measure_latency "$WG_IF") || WG_OK=false
# : "${WG_OK:=true}"

# log "wg0 latency = ${WG_LAT}ms"

# log "Measuring OpenVPN latency..."
# OVPN_LAT=$(measure_latency "$OVPN_IF") || OVPN_OK=false
# : "${OVPN_OK:=true}"

# log "tun0 latency = ${OVPN_LAT}ms"

# MODE="wan"
# BEST_IF=""

# # Decide best VPN based on latency
# if [[ "$WG_LAT" -lt 999999 || "$OVPN_LAT" -lt 999999 ]]; then
#     if [[ "$WG_LAT" -lt "$OVPN_LAT" ]]; then
#         MODE="wireguard"
#         BEST_IF="$WG_IF"
#         log "Choosing WireGuard (wg0) as best VPN."
#     elif [[ "$OVPN_LAT" -lt "$WG_LAT" ]]; then
#         MODE="openvpn"
#         BEST_IF="$OVPN_IF"
#         log "Choosing OpenVPN (tun0) as best VPN."
#     else
#         # tie → prefer WireGuard
#         MODE="wireguard"
#         BEST_IF="$WG_IF"
#         log "Tie on latency; preferring WireGuard."
#     fi
# else
#     log "Both VPN links appear down or unreachable."
# fi

# # If no VPN usable, try Tor
# if [[ "$MODE" == "wan" ]]; then
#     if tor_available; then
#         MODE="tor"
#         log "Tor is available; using Tor fallback."
#     else
#         log "Tor not available; falling back to plain WAN for router only."
#     fi
# fi

# cleanup_routes
# disable_tor_redirects

# case "$MODE" in
#     wireguard|openvpn)
#         disable_tor_redirects
#         set_default_vpn "$BEST_IF"
#         ;;

#     tor)
#         enable_tor_redirects
#         # router uses WAN to reach Tor, LAN is transparently proxied via Tor
#         set_default_wan 100
#         ;;

#     wan)
#         # last resort: router WAN only, LAB still blocked by nftables (no NAT on eth0)
#         set_default_wan 100
#         ;;
# esac

# log "Final routing table:"
# ip route

# log "vpn-routing DONE."

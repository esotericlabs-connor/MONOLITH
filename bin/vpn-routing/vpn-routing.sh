#!/bin/bash
# MONOLITH Unified VPN Routing (WG → OVPN → Tor → WAN for router only)

set -euo pipefail

LAN_IF="eth1"
WAN_IF="eth0"
WG_IF="wg0"
OVPN_IF="tun0"
WAN_GW="10.150.250.1"
MGMT_IF="eth2"

VPN_TABLE=100
LAN_NET="10.100.0.0/24"
MGMT_NET="10.99.0.0/24"

# Hysteresis tuning
MAX_LATENCY_MS=300
MAX_JITTER_MS=100
MAX_LOSS=40
WG_PREFERENCE_MS=40
SWITCH_DELTA_MS=75

STATE_FILE="/run/vpn-routing.mode"

log() { echo "[vpn-routing] $*"; }

iface_up() { ip link show "$1" up >/dev/null 2>&1; }
iface_has_ipv4() { ip -4 addr show dev "$1" | grep -q "inet "; }

# -------------------------------
# Latency + jitter test
# -------------------------------
vpn_health_check() {
    local iface="$1"
    local target="1.1.1.1"

    local result
    result=$(ping -I "$iface" -c 5 -W 1 "$target" 2>/dev/null || true)

    if [[ -z "$result" ]]; then
        log "$iface health: ping failed"
        return 1
    fi

    local loss
    loss=$(echo "$result" | grep -oP '\\d+(?=% packet loss)' | head -n1)
    local avg
    avg=$(echo "$result" | grep -oP '(?<=avg = )[^/]+' | head -n1)
    local jitter
    jitter=$(echo "$result" | grep -oP '(?<=mdev = )[0-9.]+' | head -n1)

    if [[ -z "$loss" || -z "$avg" || -z "$jitter" ]]; then
        log "$iface health: parse error"
        return 1
    fi

    log "$iface health: loss=${loss}% avg=${avg}ms jitter=${jitter}ms"

    if (( loss > MAX_LOSS )) || (( ${avg%.*} > MAX_LATENCY_MS )) || (( ${jitter%.*} > MAX_JITTER_MS )); then
        log "$iface rejected: latency/jitter/loss too high"
        return 1
    fi

    HEALTH_AVG_MS=${avg%.*}
    return 0
}

# -----------------------
# Routing helpers
# -----------------------
ensure_main_routes() {
    ip route replace "$LAN_NET" dev "$LAN_IF"
    ip route replace "$MGMT_NET" dev "$MGMT_IF" 2>/dev/null || true
    ip route replace default via "$WAN_GW" dev "$WAN_IF" metric 100
}

ensure_policy_rule() {
    if ! ip rule list | grep -q "iif $LAN_IF lookup $VPN_TABLE"; then
        ip rule add iif "$LAN_IF" lookup "$VPN_TABLE" priority 100
    fi
}

clear_policy_rule() {
    ip rule delete iif "$LAN_IF" lookup "$VPN_TABLE" priority 100 2>/dev/null || true
}

flush_vpn_table() {
    ip route flush table "$VPN_TABLE"
    ip route add unreachable default table "$VPN_TABLE"
}

set_default_vpn() {
    local iface="$1"
    flush_vpn_table
    ip route add "$LAN_NET" dev "$LAN_IF" table "$VPN_TABLE"
    ip route add 0.0.0.0/1 dev "$iface" table "$VPN_TABLE" metric 50
    ip route add 128.0.0.0/1 dev "$iface" table "$VPN_TABLE" metric 50
    ip route replace default via "$WAN_GW" dev "$WAN_IF" metric 500
}

set_default_wan() {
    flush_vpn_table
    ip route replace default via "$WAN_GW" dev "$WAN_IF" metric 100
}

# -----------------------
# Tor routing setup
# -----------------------
enable_tor_redirects() {
    log "Enabling Tor transparent proxy routing..."
    nft -f - <<EOF_TOR
flush table inet tor 2> /dev/null

table inet tor {
    chain prerouting {
        type nat hook prerouting priority -100;
        iif "$LAN_IF" tcp redirect to :9040
        iif "$LAN_IF" udp dport 53 redirect to :5353
    }
}
EOF_TOR
}

disable_tor_redirects() {
    nft delete table inet tor 2>/dev/null || true
}

# -----------------------
# Main logic
# -----------------------
sleep 2
log "Flushing conntrack..."
conntrack -F || true

ensure_main_routes
ensure_policy_rule

MODE="wan"
PREV_MODE=$(cat "$STATE_FILE" 2>/dev/null || echo "wan")
WG_SCORE=999999
OVPN_SCORE=999999

# Prefer WireGuard when healthy
if iface_up "$WG_IF" && iface_has_ipv4 "$WG_IF"; then
    log "Checking WireGuard..."
    if vpn_health_check "$WG_IF"; then
        WG_SCORE=$HEALTH_AVG_MS
    fi
fi

# Check OpenVPN
if iface_up "$OVPN_IF" && iface_has_ipv4 "$OVPN_IF"; then
    log "Checking OpenVPN..."
    if vpn_health_check "$OVPN_IF"; then
        OVPN_SCORE=$HEALTH_AVG_MS
    fi
fi

if (( WG_SCORE < 999999 )) && (( OVPN_SCORE < 999999 )); then
    # Both healthy – prefer WireGuard unless it is substantially worse
    if (( WG_SCORE <= OVPN_SCORE + WG_PREFERENCE_MS )); then
        MODE="wireguard"
    else
        MODE="openvpn"
    fi
elif (( WG_SCORE < 999999 )); then
    MODE="wireguard"
elif (( OVPN_SCORE < 999999 )); then
    MODE="openvpn"
else
    MODE="wan"
fi

# Avoid rapid flapping: if current mode is healthy, stay unless poor
if [[ "$PREV_MODE" == "wireguard" ]] && (( WG_SCORE < 999999 )); then
    MODE="wireguard"
elif [[ "$PREV_MODE" == "openvpn" ]] && (( OVPN_SCORE < 999999 )) && (( WG_SCORE > OVPN_SCORE + SWITCH_DELTA_MS )); then
    MODE="openvpn"
fi

# Try Tor only if both VPNs fail
if [[ "$MODE" == "wan" ]]; then
    log "Testing Tor fallback..."
    if systemctl is-active --quiet tor || systemctl is-active --quiet tor@default; then
        if torify curl -s --max-time 4 https://check.torproject.org >/dev/null 2>&1; then
            log "Tor is online and reachable"
            MODE="tor"
        else
            log "Tor test failed"
        fi
    else
        log "Tor service not active"
    fi
fi

log "MODE chosen: $MODE (prev: $PREV_MODE)"

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
        set_default_wan   # router uses WAN but LAN is redirected into Tor
        ;;

    wan)
        log "No VPN or Tor available → router WAN only (LAN blocked)"
        disable_tor_redirects
        set_default_wan
        ;;

    *)
        log "Unknown mode $MODE"
        ;;
esac

echo "$MODE" > "$STATE_FILE"

log "Final routing tables (main + vpn):"
ip route show table main
ip route show table "$VPN_TABLE"

log "vpn-routing DONE."
#!/bin/bash
# Unified VPN routing + recovery script
# Debian Router // "Monolith"

set -euo pipefail

LAN_IF="eth1"
WAN_IF="eth0"
VPN_CANDIDATES=("wg0" "tun0")
WAN_GW="10.150.250.1"
TOR_CONF="/etc/nftables.tor.conf"
TOR_SERVICE="tor@default.service"

sleep 2

echo "[vpn-routing] Flushing conntrack..."
conntrack -F || true

echo "[vpn-routing] Cleaning default routes..."
ip route del default || true

echo "[vpn-routing] Selecting preferred VPN interface..."
ACTIVE_VPN=""
for cand in "${VPN_CANDIDATES[@]}"; do
    if ip link show "${cand}" up >/dev/null 2>&1; then
        ACTIVE_VPN="${cand}"
        break
    fi
done

if [[ -n "${ACTIVE_VPN}" ]]; then
    echo "[vpn-routing] ${ACTIVE_VPN} detected — applying VPN default..."
    ip route add default dev "${ACTIVE_VPN}" metric 50 || true
else
    echo "[vpn-routing] No VPN interface detected; enabling Tor fallback..."
fi

echo "[vpn-routing] Adding WAN failover..."
ip route add default via "${WAN_GW}" dev "${WAN_IF}" metric 500 || true

echo "[vpn-routing] Reloading firewall safely..."
nft flush ruleset 2>/dev/null || true
nft -f /etc/nftables.conf 2>/dev/null || true

if [[ -z "${ACTIVE_VPN}" ]] && [[ -f "${TOR_CONF}" ]]; then
    systemctl start "${TOR_SERVICE}" || true
    nft -f "${TOR_CONF}" 2>/dev/null || true
    echo "[vpn-routing] Tor transparent proxy ruleset loaded as emergency path."
else
    echo "[vpn-routing] Tor fallback not required."
fi

echo "[vpn-routing] DONE."
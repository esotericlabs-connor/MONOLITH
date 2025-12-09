#!/bin/bash
# Unified VPN routing + recovery script
# Debian Router // "Monolith"

LAN_IF="eth1"
WAN_IF="eth0"
VPN_IF="tun0"

LAN_NET="10.100.0.0/24"
WAN_GW="10.150.250.1"
VPN_GW="10.98.0.1"

sleep 2

echo "[vpn-routing] Flushing conntrack..."
conntrack -F || true

echo "[vpn-routing] Cleaning default routes..."
ip route del default || true

echo "[vpn-routing] Rebuilding routing table..."

# If tun0 exists → make VPN primary
if ip link show $VPN_IF up >/dev/null 2>&1; then
    echo "[vpn-routing] tun0 detected — applying VPN default..."
    ip route add default dev $VPN_IF metric 50 || true
else
    echo "[vpn-routing] tun0 NOT detected — skipping VPN default."
fi

# Always add WAN failover (high metric)
echo "[vpn-routing] Adding WAN failover..."
ip route add default via $WAN_GW dev $WAN_IF metric 500 || true

echo "[vpn-routing] Waiting for tun0 to stabilize..."
for i in {1..10}; do
    if ip link show tun0 >/dev/null 2>&1; then
        break
    fi
    echo "[vpn-routing] tun0 not ready yet... ($i)"
    sleep 1
done

echo "[vpn-routing] Reloading firewall safely..."
nft flush ruleset 2>/dev/null || true
nft -f /etc/nftables.conf 2>/dev/null || true


echo "[vpn-routing] DONE."

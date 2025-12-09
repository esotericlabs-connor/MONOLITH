#!/bin/bash
# debian-vpn-router-bootstrap.sh
# Build the MONOLITH-NET01-style VPN router from scratch.

set -e

### ---------- CONFIGURABLE VARS (EDIT IF NEEDED) ----------
WAN_IF="eth0"
LAN_IF="eth1"
MGMT_IF="eth2"

WAN_IP="10.150.250.52"
WAN_GW="10.150.250.1"
WAN_NETMASK="255.255.255.0"

LAN_IP="10.100.0.1"
LAN_NET="10.100.0.0/24"
LAN_NETMASK="255.255.255.0"

MGMT_IP="10.99.0.1"
MGMT_NET="10.99.0.0/24"
MGMT_NETMASK="255.255.255.0"

VPN_IF="tun0"
VPN_OVPN="/etc/openvpn/client/proton.ovpn"   # drop your Proton config here later

PIHOLE_TZ="America/Los_Angeles"
PIHOLE_WEBPW="changeme"

### ---------- SAFETY ----------
if [[ $EUID -ne 0 ]]; then
  echo "Run this as root." >&2
  exit 1
fi

echo "[*] Updating apt and installing core packages..."
apt update
apt install -y \
  nftables ufw \
  openvpn \
  docker.io \
  cockpit cockpit-ufw \
  conntrack \
  iproute2 tcpdump net-tools

### ---------- NETWORK INTERFACES ----------
echo "[*] Writing /etc/network/interfaces..."
cat >/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto ${WAN_IF}
iface ${WAN_IF} inet static
    address ${WAN_IP}
    netmask ${WAN_NETMASK}
    gateway ${WAN_GW}

auto ${LAN_IF}
iface ${LAN_IF} inet static
    address ${LAN_IP}
    netmask ${LAN_NETMASK}

auto ${MGMT_IF}
iface ${MGMT_IF} inet static
    address ${MGMT_IP}
    netmask ${MGMT_NETMASK}
EOF

echo "[*] Enabling IP forwarding and disabling IPv6 on LAN/MGMT..."
cat >/etc/sysctl.d/99-router.conf <<EOF
net.ipv4.ip_forward = 1
EOF

cat >/etc/sysctl.d/99-lan-ipv6.conf <<EOF
net.ipv6.conf.${LAN_IF}.disable_ipv6 = 1
net.ipv6.conf.${MGMT_IF}.disable_ipv6 = 1
EOF

sysctl --system

### ---------- NFTABLES ----------
echo "[*] Writing /etc/nftables.conf..."
cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

############################
# FILTER TABLE
############################
table inet filter {

    chain logdrop {
        limit rate 5/second
        log prefix "NFT-DROP: "
        drop
    }

    chain input {
        type filter hook input priority 0;

        # Allow loopback
        iif "lo" accept

        # Established / related
        ct state { established, related } accept

        # Optional: ICMP ping from LAN + MGMT
        ip saddr { ${LAN_NET}, ${MGMT_NET} } icmp type echo-request accept

        ########################
        # DHCP from LAN
        ########################
        iif "${LAN_IF}" udp dport { 67, 68 } accept

        ########################
        # MANAGEMENT ACCESS
        ########################
        tcp dport 22   ip saddr { ${LAN_NET}, ${MGMT_NET} } accept
        tcp dport 9090 ip saddr { ${LAN_NET}, ${MGMT_NET} } accept

        ########################
        # PI-HOLE ACCESS
        ########################
        tcp dport { 80, 443 } ip saddr { ${LAN_NET}, ${MGMT_NET} } accept

        # Strict DNS to router/Pi-hole only
        ip saddr { ${LAN_NET}, ${MGMT_NET} } ip daddr { ${LAN_IP}, ${MGMT_IP} } udp dport 53 accept
        ip saddr { ${LAN_NET}, ${MGMT_NET} } ip daddr { ${LAN_IP}, ${MGMT_IP} } tcp dport 53 accept

        # Default: log + drop
        jump logdrop
    }

    chain forward {
        type filter hook forward priority 0;

        ct state { established, related } accept

        # LAN -> VPN ONLY
        iif "${LAN_IF}" oifname "${VPN_IF}" accept
        iif "${LAN_IF}" drop

        # MGMT is never routed
        iif "${MGMT_IF}" drop
        oif "${MGMT_IF}" drop

        jump logdrop
    }

    chain output {
        type filter hook output priority 0;
        accept
    }
}

############################
# NAT TABLE
############################
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100;
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        ip saddr ${LAN_NET} oifname "${VPN_IF}" masquerade
    }
}
EOF

echo "[*] Enabling nftables..."
systemctl enable --now nftables

### ---------- UFW ----------
echo "[*] Configuring UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

ufw allow from ${MGMT_NET} to any port 22 proto tcp
ufw allow from ${LAN_NET}  to any port 22 proto tcp

ufw allow from ${MGMT_NET} to any port 9090 proto tcp
ufw allow from ${LAN_NET}  to any port 9090 proto tcp

ufw allow from ${MGMT_NET} to any port 80,443 proto tcp
ufw allow from ${LAN_NET}  to any port 80,443 proto tcp

ufw allow from ${MGMT_NET} to any port 53
ufw allow from ${LAN_NET}  to any port 53

ufw deny in on ${WAN_IF}
ufw deny in on ${WAN_IF} proto ipv6

ufw --force enable

### ---------- DOCKER + PI-HOLE ----------
echo "[*] Setting up Pi-hole (Docker, host network)..."
mkdir -p /etc/pihole /etc/dnsmasq.d

docker pull pihole/pihole:latest || true

docker rm -f pihole 2>/dev/null || true

docker run -d \
  --name pihole \
  --network host \
  -e TZ="${PIHOLE_TZ}" \
  -e WEBPASSWORD="${PIHOLE_WEBPW}" \
  -e DNSMASQ_LISTENING=all \
  -v /etc/pihole:/etc/pihole \
  -v /etc/dnsmasq.d:/etc/dnsmasq.d \
  --restart unless-stopped \
  pihole/pihole:latest

### ---------- COCKPIT ----------
echo "[*] Enabling Cockpit..."
systemctl enable --now cockpit.socket

### ---------- OPENVPN CLIENT ----------
echo "[*] Preparing OpenVPN client..."
mkdir -p /etc/openvpn/client

if [[ -f "${VPN_OVPN}" ]]; then
  echo "[*] Patching existing ${VPN_OVPN}..."
  grep -q 'pull-filter ignore "route-ipv6"' "${VPN_OVPN}"  || echo 'pull-filter ignore "route-ipv6"'  >> "${VPN_OVPN}"
  grep -q 'pull-filter ignore "ifconfig-ipv6"' "${VPN_OVPN}" || echo 'pull-filter ignore "ifconfig-ipv6"' >> "${VPN_OVPN}"
  grep -q 'route-noexec' "${VPN_OVPN}" || echo 'route-noexec' >> "${VPN_OVPN}"
  grep -q 'up /usr/local/bin/vpn-routing.sh' "${VPN_OVPN}"   || echo 'up /usr/local/bin/vpn-routing.sh'   >> "${VPN_OVPN}"
  grep -q 'down /usr/local/bin/vpn-routing.sh' "${VPN_OVPN}" || echo 'down /usr/local/bin/vpn-routing.sh' >> "${VPN_OVPN}"
else
  echo "[!] ${VPN_OVPN} does not exist yet."
  echo "    After this script, copy your Proton .ovpn to ${VPN_OVPN}"
  echo "    and add:"
  echo "      pull-filter ignore \"route-ipv6\""
  echo "      pull-filter ignore \"ifconfig-ipv6\""
  echo "      route-noexec"
  echo "      up /usr/local/bin/vpn-routing.sh"
  echo "      down /usr/local/bin/vpn-routing.sh"
fi

### ---------- VPN ROUTING SCRIPT ----------
echo "[*] Creating /usr/local/bin/vpn-routing.sh..."
cat >/usr/local/bin/vpn-routing.sh <<EOF
#!/bin/bash
# Unified VPN routing + recovery script – Debian Router

set -e

LAN_IF="${LAN_IF}"
WAN_IF="${WAN_IF}"
VPN_IF="${VPN_IF}"
LAN_NET="${LAN_NET}"
WAN_GW="${WAN_GW}"

sleep 2

echo "[vpn-routing] Flushing conntrack..."
command -v conntrack >/dev/null 2>&1 && conntrack -F || true

echo "[vpn-routing] Cleaning default routes..."
ip route del default || true

echo "[vpn-routing] Rebuilding routing table..."
if ip link show "\${VPN_IF}" up >/dev/null 2>&1; then
    echo "[vpn-routing] \${VPN_IF} detected – setting VPN as primary default..."
    ip route add default dev "\${VPN_IF}" metric 50 || true
else
    echo "[vpn-routing] \${VPN_IF} not detected – skipping VPN default..."
fi

echo "[vpn-routing] Adding WAN failover (metric 500)..."
ip route add default via "\${WAN_GW}" dev "\${WAN_IF}" metric 500 || true

echo "[vpn-routing] Reloading nftables..."
nft flush ruleset
nft -f /etc/nftables.conf

echo "[vpn-routing] DONE."
EOF

chmod +x /usr/local/bin/vpn-routing.sh

### ---------- vpn-routing.service ----------
echo "[*] Creating systemd unit for vpn-routing..."
cat >/etc/systemd/system/vpn-routing.service <<EOF
[Unit]
Description=Apply VPN routing + nftables after VPN comes up
After=network-online.target openvpn@proton.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-routing.service || true

### ---------- FINAL INFO ----------
echo
echo "======================================================="
echo "Base build complete."
echo
echo "NEXT STEPS:"
echo "1) Copy your Proton .ovpn file to:"
echo "     ${VPN_OVPN}"
echo "   and re-run: systemctl restart openvpn@proton.service"
echo
echo "2) In Pi-hole web UI:"
echo "   - Enable DHCP for ${LAN_NET}"
echo "   - Gateway: ${LAN_IP}"
echo "   - DNS: ${LAN_IP}"
echo
echo "3) Reboot once to verify everything comes up clean:"
echo "     sudo reboot"
echo
echo "Then plug a VM into the LAB (10.100.0.0/24) and confirm:"
echo "   - It gets IP/DNS via DHCP from Pi-hole"
echo "   - whatismyip shows Proton exit IP"
echo "   - Stopping openvpn kills internet for LAB (no WAN leak)"
echo "======================================================="

# MONOLITH
A secure, prebuilt linux virutal network appliance preinstalled with Pi-Hole DNS/DHCP, Cockpit, UFW, Fail2Ban, and self optimizing, self-healing full tunnel VPN routing using Wireguard, OpenVPN and Tor.

<img width="350" height="350" alt="5f79c419-dc39-4403-a5fe-8c95557a8559" src="https://github.com/user-attachments/assets/a3c6d89f-337d-41f8-9b19-ab0f8e51bc04" />

MONOLITH is a hardened linux virtual router built for lab environments (HyperV or VirtualBox recommneded). It enforces full-tunnel VPN routing, strict LAN isolation, DNS/DHCP via Pi-hole, and secure admin access over a dedicated MGMT network (guide included). The entire network is designed for privacy, malware-containment, penetration-testing labs, and secure DevOps environments.

The system guarantees:
  Zero traffic leaks
  Mandatory VPN routing with a cryptographic killswitch
  Dedicated management network that never touches VPN/LAB paths
  Auto-repairing routing layer
  High-performance, auto-tuned OpenVPN tunnel
  Clean reproducibility for new deployments

---

## System Architecture

The Hyper-V host holding MONOLITH will require two physical NICs: one for itself and one dedicated to the MONOLITH VM.  
Three vSwitches will be required: WAN / LAB / MGMT networks.
LAB traffic is **forced into a full-tunnel VPN** with a strict killswitch.  
MGMT provides safe admin access with zero routing or NAT.  
nftables isolates every boundary.  
A custom daemon handles VPN failover, self-healing, and MTU optimization.  
The result is a fully isolated, leakproof, self-healing virtual router appliance.

PHYSICAL INTERNET  
        

        Host NIC #1 (Windows only)  
        Host NIC #2 (Dedicated WAN feed)  
                ▼

        +-------------------------------+  
        |     Hyper-V Virtual Switches  |  
        +-------------------------------+  
                │               │               │  
                ▼               ▼               ▼  
          WAN vSwitch     LAB vSwitch     MGMT vSwitch  
           (External)       (Internal)      (Internal)  
                │               │               │  
                ▼               ▼               ▼  
        Debian Router       LAB VMs       Windows Host (mgmt only)  
            eth0              eth1             10.99.x  
                              │  
                              └──► tun0 ► VPN (OpenVPN, Wireguard, Tor) - Full Tunnel  

WAN Internet  

---

## Hyper-V Requirements

Host OS:  
    • Windows 10/11  
    • Hyper-V enabled  

NIC Layout:  
    • NIC #1 → Windows host only  
    • NIC #2 → Dedicated WAN feed for router VM  

VM Layout:  
    • VM1: MONOLITH-NET01 (Debian router)  
    • VM2…N: LAB VMs (Windows, Kali, Linux)  

---

## Virtual Switch Layout

### vSwitch-WAN (EXTERNAL)
    • Bound to NIC #2  
    • Windows host does NOT share this NIC  
    • Provides WAN only to Debian eth0  

### vSwitch-LAB (INTERNAL)
    • 10.100.0.0/24 isolated network  
    • No host/home LAN visibility  
    • DHCP + DNS from Pi-hole  
    • Full-tunnel VPN enforced  

### vSwitch-MGMT (INTERNAL)
    • 10.99.0.0/24 management network  
    • Not routed  
    • Not NATed  
    • Always reachable even if VPN dies  

---

## Router Network Layout

Interfaces:  
    eth0 = WAN (DHCP)  
    eth1 = LAB LAN (10.100.0.1/24)  
    eth2 = MGMT LAN (10.99.0.1/24)  
    tun0 = VPN tunnel  

---

## Routing Policy

VPN Mandatory Routes:  
    0.0.0.0/1     via tun0  
    128.0.0.0/1   via tun0  

Fallback:  
    default via eth0 metric 500  

Local Networks:  
    10.99.0.0/24 dev eth2  
    10.100.0.0/24 dev eth1  

LAB → tun0 ONLY  
MGMT → never forwarded or NATed  

---

## Firewall (nftables)

### INPUT Rules  
    • Allow loopback  
    • Drop IPv6 on eth1 & eth2  
    • Allow DHCP on eth1  
    • Allow SSH (22) & Cockpit (9090) from LAN/MGMT  
    • DNS allowed only to router  

### FORWARD Rules  
    • eth1 → tun0 only  
    • eth2 → drop  
    • default → drop  

### NAT Rules  
    • 10.100.0.0/24 → tun0 (MASQ)  
    • MGMT not NATed  

---

## Pi-hole DNS/DHCP

    • Runs in docker host-mode  
    • Listens directly on eth1  
    • Provides DHCP for LAB  
    • DNS filter + adblock  
    • UI: ports 80/443  
    • External DNS blocked by firewall  

---

## VPN Subsystem

Directory: `/etc/openvpn/client/`

Contains:  
    • Multiple *.ovpn configs  
    • active.ovpn symlink  
    • auth.txt  

Systemd service: openvpn@proton.service


Defaults:  
    • route-nopull  
    • IPv6 stripped  
    • MTU auto-tuned via daemon  

---

## Dynamic VPN Failover Daemon

File: `/usr/local/bin/vpn-failover.sh`

Features:  
    • Latency + packet-loss monitoring  
    • Auto-switch Proton servers  
    • Auto-rebuild tun0  
    • Auto MTU discovery  
    • Cached MTU per server  
    • Zero-touch operation  

Systemd:  vpn-failover.service


---

## Router Repair Script

File: `/usr/local/bin/router-repair.sh`

Tasks:  
    • Restore nftables  
    • Reapply sysctl hardening  
    • Disable IPv6 on LAN/MGMT  
    • Restart OpenVPN + failover daemons  
    • Rebuild routing stack  
    • No reboot required  

---

## Sysctl Hardening

File: `/etc/sysctl.d/99-router.conf`

Key values:  
    • Disable IPv6 on eth1 & eth2  
    • Block rogue RA  
    • rp_filter = 1  
    • No redirects  
    • Enable IPv4 forwarding  

---

## Cockpit Web UI

    • Installed via apt  
    • Port 9090 allowed only from LAB + MGMT  
    • Optional “repair” button integration  

---

## Installation Steps

1. Create Hyper-V switches  
vSwitch-WAN = External (NIC #2), mgmt disabled
vSwitch-LAB = Internal
vSwitch-MGMT = Internal

2. Deploy Debian VM  
    • 2 vCPUs  
    • 2–4 GB RAM  
    • 20 GB disk  
    • 3 NICs (WAN / LAB / MGMT)  

3. Install packages  
apt update
apt install openvpn nftables cockpit docker.io git


4. Deploy Pi-hole (host mode)  
docker run --network=host --name pihole ...


5. Apply firewall/sysctl configs  

systemctl enable --now nftables


6. Configure VPN  
ln -s /etc/openvpn/client/<server>.ovpn /etc/openvpn/client/active.ovpn
systemctl enable --now openvpn@proton


7. Start failover daemon  

systemctl enable --now vpn-failover.service


---

## Verification

Check VPN:  

ip a | grep tun0


Check routes:  

ip route


Check firewall:  

nft list ruleset

Check Pi-hole:  

pihole -t


---

## Features

Isolation:  
    • LAB cannot reach host or home LAN  
    • MGMT cannot reach LAB or WAN  
    • IPv6 fully suppressed  

Privacy:  
    • 100% LAB traffic routed through VPN  
    • Forced DNS → Pi-hole  

Resilience:  
    • Auto-failover  
    • Auto-MTU tuning  
    • Auto-repair  

Control:  
    • Cockpit always reachable  
    • MGMT always up  

---

If you have any questions/comments about the project, email me at github@connormail.slmail.me.

**MONOLITH is distributed under the MIT license and intended for lawful, ethical use only.**
Made with ♥️ at ExoterikLabs©



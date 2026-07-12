# Phase 01 — Static Network Addressing (Netplan)

> Establishment of the Layer 3 topology: static IP assignment via Netplan across all seven
> VMs, activation of IP forwarding on the router, and intra-zone connectivity validation.

---

## Table of Contents

- [Objective](#objective)
- [Interface Mapping — Router](#interface-mapping--router)
- [Addressing Plan](#addressing-plan)
- [Configuration Method](#configuration-method)
- [Netplan Configurations](#netplan-configurations)
- [IP Forwarding](#ip-forwarding)
- [Challenges and Resolutions](#challenges-and-resolutions)
- [Validation](#validation)
- [Outcome](#outcome)

---

## Objective

Deploy a rigorous static IP addressing plan across all seven VMs using Netplan under
Ubuntu Server 22.04 LTS. This phase establishes the Layer 3 foundation of the
infrastructure — each VM receives the address defined in the project's network plan — and
transforms the router into a functional multi-homed gateway by activating IP forwarding.

---

## Interface Mapping — Router

The router exposes five network interfaces. Before writing any Netplan configuration, the
MAC address of each VMware network adapter is cross-referenced against the output of
`ip link show` to establish the definitive interface-to-zone mapping. This step is critical:
an incorrect assignment produces a configuration that appears valid but routes traffic to
the wrong zone.

| Interface | VMnet | Zone | Role |
|---|---|---|---|
| ens33 | NAT | WAN | Internet uplink — DHCP |
| ens34 | VMnet10 | DMZ | Gateway for HAProxy and Apache nodes |
| ens35 | VMnet11 | Clients | Gateway for the client workstation |
| ens36 | VMnet12 | Internal Servers | Gateway for the MySQL instance |
| ens37 | VMnet13 | Supervision | Gateway for the ELK stack |

All internal interfaces (ens34–ens37) carry no `gateway4` directive. The router does not
require a default route on its internal-facing interfaces — it *is* the gateway for those
segments.

---

## Addressing Plan

| VM | Interface | Address / CIDR | Gateway | Notes |
|---|---|---|---|---|
| routeur | ens33 | DHCP | Via WAN | Internet uplink |
| routeur | ens34 | 172.16.40.254/24 | — | DMZ gateway |
| routeur | ens35 | 192.168.10.254/24 | — | Clients gateway |
| routeur | ens36 | 192.168.20.254/24 | — | Servers gateway |
| routeur | ens37 | 192.168.30.254/24 | — | Supervision gateway |
| haproxy | ens33 | 172.16.40.10/24 | 172.16.40.254 | Load balancer — DMZ |
| apache-1 | ens33 | 172.16.40.11/24 | 172.16.40.254 | Web node 1 — DMZ |
| apache-2 | ens33 | 172.16.40.12/24 | 172.16.40.254 | Web node 2 — DMZ |
| client | ens33 | 192.168.10.100/24 | 192.168.10.254 | Temporary static — replaced by DHCP in Phase 04 |
| mysql | ens33 | 192.168.20.10/24 | 192.168.20.254 | Database — Internal Servers |
| elk | ens33 | 192.168.30.10/24 | 192.168.30.254 | SIEM — Supervision |

The client VM receives a temporary static address (192.168.10.100) in the planned DHCP
range (.100–.200). This allows intra-zone and later inter-zone validation before the DHCP
server is deployed in Phase 04. The configuration will be replaced by `dhcp4: true` once
`isc-dhcp-server` is operational.

---

## Configuration Method

Ubuntu Server 22.04 in minimized profile does not include standard text editors by default.
All Netplan YAML files are written using `tee` to inject content while preserving strict
YAML indentation (2 spaces per level, no tabs):

```bash
sudo tee /etc/netplan/00-installer-config.yaml << 'EOF'
<yaml content>
EOF
```

The following three-step sequence is applied to every VM after writing the configuration
file, mirroring production deployment practice:

```bash
sudo chmod 600 /etc/netplan/00-installer-config.yaml
# Netplan emits a security warning if the file is world-readable

sudo netplan try
# Applies the configuration temporarily; automatically reverts after 120 seconds
# if the administrator does not confirm — prevents permanent loss of connectivity
# from a syntax error

sudo netplan apply
# Commits the configuration permanently
```

---

## Netplan Configurations

### Router (5 interfaces)

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens33:
      dhcp4: true
    ens34:
      addresses: [172.16.40.254/24]
    ens35:
      addresses: [192.168.10.254/24]
    ens36:
      addresses: [192.168.20.254/24]
    ens37:
      addresses: [192.168.30.254/24]
```

### DMZ Nodes (HAProxy, Apache-1, Apache-2)

Shown for Apache-1; adapt `addresses` and `gateway4` per the addressing plan:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens33:
      addresses: [172.16.40.11/24]
      gateway4: 172.16.40.254
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```

### Internal Servers (MySQL) and Supervision (ELK)

Shown for MySQL; adapt `addresses` and `gateway4` per the addressing plan:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens33:
      addresses: [192.168.20.10/24]
      gateway4: 192.168.20.254
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```

### Client (temporary static address)

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens33:
      addresses: [192.168.10.100/24]
      gateway4: 192.168.10.254
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```

---

## IP Forwarding

With Netplan applied, the router correctly routes within each directly attached subnet but
does not yet forward packets between zones. IP forwarding is a kernel-level capability that
must be explicitly enabled.

A persistent configuration file is used rather than `sysctl -w`, which does not survive
a reboot:

```bash
sudo tee /etc/sysctl.d/99-forwarding.conf << 'EOF'
net.ipv4.ip_forward=1
EOF

sudo sysctl -p /etc/sysctl.d/99-forwarding.conf
```

Verification:

```bash
cat /proc/sys/net/ipv4/ip_forward
# Expected output: 1
```

Enabling IP forwarding at this stage is a prerequisite for Phase 02 (inter-zone routing)
but has no observable effect yet: without iptables rules or a NAT rule, internal VMs have
no route to reach any zone other than their own.

---

## Challenges and Resolutions

**Text editor unavailability on minimized systems**
The absence of `nano`, `vi`, or any standard editor on the minimized Ubuntu profile required
an alternative approach for writing YAML configuration files. The `tee` utility, which reads
from standard input and writes to a file, provides an effective substitute while
mathematically preserving YAML indentation hierarchy — critical for Netplan, which is
intolerant of any indentation inconsistency.

**Risk of irreversible connectivity loss**
A YAML syntax error applied with `netplan apply` can permanently lock an administrator
out of a VM, particularly on headless systems where console access is inconvenient. The
`netplan try` command mitigates this by applying the configuration temporarily: if the
administrator does not issue a confirmation within 120 seconds, the previous configuration
is automatically restored. This procedure is adopted as a standard for all Netplan operations
in this project.

**Diagnostic tool unavailability on internal VMs**
Internal VMs in the minimized profile do not include `ping` or `traceroute` by default.
At this stage, with no internet access available to internal VMs (NAT is not yet active),
installing these tools is not possible. Connectivity validation for internal VMs is therefore
performed centrally from the router, which has direct logical access to all zones via its
attached interfaces. This approach validates Layer 3 reachability without installing any
potentially unnecessary tooling on production nodes.

**Inactive inter-VLAN routing by default**
Despite correct Netplan configuration, the Linux kernel on the router silently drops
packets arriving on one interface and destined for a different subnet unless IP forwarding
is explicitly enabled. Without `net.ipv4.ip_forward=1`, the router behaves as a host — not
a router — and all inter-zone traffic is discarded. This is resolved through the persistent
sysctl configuration described above.

---

## Validation

Validation at this stage focuses on intra-zone reachability — each VM reaching its gateway
— and router-level visibility across all zones.

**Per-VM address verification**
```bash
ip -br addr show
# Executed on all 7 VMs to confirm correct IP/prefix assignment on the correct interface
```

**Intra-zone ping (from router)**
In the absence of diagnostic tools on internal VMs, ping tests are executed from the router,
which has direct interface-level access to all zones:

```
ping -c 4 172.16.40.10    # HAProxy (DMZ)       → 0% packet loss
ping -c 4 172.16.40.11    # Apache-1 (DMZ)      → 0% packet loss
ping -c 4 172.16.40.12    # Apache-2 (DMZ)      → 0% packet loss
ping -c 4 192.168.10.100  # Client (Clients)    → 0% packet loss
ping -c 4 192.168.20.10   # MySQL (Servers)     → 0% packet loss
ping -c 4 192.168.30.10   # ELK (Supervision)   → 0% packet loss
```

**WAN internet access (router)**
```bash
ping -c 4 google.com
# Validates both outbound routing and DNS resolution via the WAN interface
```

**IP forwarding confirmed**
```bash
cat /proc/sys/net/ipv4/ip_forward   # → 1
```

> Note: tests executed from the router to internal zone IPs confirm Layer 3 reachability
> within directly attached subnets. They do not validate inter-zone routing — a packet
> originating from the router and destined for 172.16.40.10 exits via ens34 without crossing
> any zone boundary. True inter-zone routing validation (traffic crossing from one zone to
> another) is the subject of Phase 02.

---

## Outcome

The Layer 3 topology is fully deployed and validated:

- 7 Netplan configurations written, secured (`chmod 600`), and applied
- All VMs respond to ping from the router with 0% packet loss
- Router has verified internet access via WAN and DNS resolution
- IP forwarding is active and persistent across reboots
- Client VM holds a temporary static IP (192.168.10.100) pending DHCP deployment in Phase 04

**Next phase:** [Phase 02 — Inter-Zone Routing and NAT](phase-02-inter-zone-routing.md)

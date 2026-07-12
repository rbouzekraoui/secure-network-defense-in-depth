# Phase 00 — Environment Setup and VM Provisioning

> Deployment of the virtualized hardware foundation and Layer 2 isolation enforced through
> dedicated VMnets before any software configuration layer is applied.

---

## Table of Contents

- [Objective](#objective)
- [Technology Choices](#technology-choices)
- [Network Isolation Design — Layer 2](#network-isolation-design--layer-2)
- [Virtual Machine Specifications](#virtual-machine-specifications)
- [Provisioning Strategy](#provisioning-strategy)
- [Post-Deployment Health Checks](#post-deployment-health-checks)
- [Initial System Provisioning](#initial-system-provisioning)
- [Outcome](#outcome)

---

## Objective

Provision a robust, isolated virtualized hardware foundation for the defense-in-depth
architecture. The goal of this phase is to establish absolute network separation between
trust zones at the hypervisor level — before any operating system configuration, routing,
or firewall policy is applied.

Zone isolation is enforced here at Layer 2 through distinct VMnet assignments, guaranteeing
that no frame leakage between zones is possible regardless of the software configuration
state of any given VM.

---

## Technology Choices

| Component | Choice | Rationale |
|---|---|---|
| Hypervisor | VMware Workstation 17.x | Native isolated VMnet management; Type-2; free for personal and educational use |
| Operating system | Ubuntu Server 22.04 LTS | Long-term support (5 years); kernel 5.15+ with native support for advanced network primitives |
| Installation profile | Minimized | Eliminates all non-essential packages, reducing RAM footprint and attack surface from the first boot |
| Remote access | OpenSSH pre-installed | Enables secure remote administration from the host without requiring post-install setup |
| Disk partitioning | Standard (no LVM) | Simplifies disk management on a hypervisor; eliminates LVM overhead for VMs that do not require it |

---

## Network Isolation Design — Layer 2

Five virtual network segments are defined in VMware's Virtual Network Editor, each mapped
to a distinct trust zone. The VMware DHCP service is explicitly disabled on all internal
VMnets — address assignment is managed by the infrastructure itself in later phases.

| VMnet | Zone | Subnet | Mode | VMware DHCP |
|---|---|---|---|---|
| NAT (VMnet8) | WAN | Dynamic (ISP) | NAT | Enabled (WAN simulation) |
| VMnet10 | DMZ | 172.16.40.0/24 | Host-only | **Disabled** |
| VMnet11 | Clients | 192.168.10.0/24 | Host-only | **Disabled** |
| VMnet12 | Internal Servers | 192.168.20.0/24 | Host-only | **Disabled** |
| VMnet13 | Supervision (SIEM) | 192.168.30.0/24 | Host-only | **Disabled** |

Host-only mode confines each VMnet to the hypervisor host and the VMs explicitly attached
to it. Combined with distinct VMnet IDs, this provides Layer 2 isolation functionally
equivalent to physical VLAN separation.

---

## Virtual Machine Specifications

Resources are allocated asymmetrically to match each service's operational requirements.
The ELK VM receives elevated resources to meet Elasticsearch's minimum heap requirements.

| VM | Strategic Role | VMnet Connectivity | vCPU | RAM | Storage |
|---|---|---|---|---|---|
| routeur | Central firewall, inter-zone routing, NAT gateway | NAT + VMnet10, 11, 12, 13 | 1 | 1 GB | 10 GB |
| haproxy | HTTP/HTTPS load balancer | VMnet10 | 1 | 1 GB | 10 GB |
| apache-1 | Primary web node | VMnet10 | 1 | 1 GB | 10 GB |
| apache-2 | Secondary web node (redundancy) | VMnet10 | 1 | 1 GB | 10 GB |
| client | User workstation, test origin | VMnet11 | 1 | 1 GB | 10 GB |
| mysql | Application backend database | VMnet12 | 1 | 1 GB | 15 GB |
| elk | Elasticsearch + Logstash + Kibana | VMnet13 | 2 | 5 GB | 30 GB |

The router is the only VM with multiple network interfaces (5 total), reflecting its role
as the sole inter-zone gateway. Every other VM is connected to exactly one VMnet,
corresponding to the zone in which it operates.

---

## Provisioning Strategy

**Fresh instantiation — no cloning.**
All seven VMs are created from scratch using new VMware instances. Cloning is explicitly
avoided to guarantee unique MAC addresses and unique Ubuntu machine IDs (`/etc/machine-id`)
across the entire fleet. On the router, where five interfaces are required, each additional
network adapter has its MAC address manually regenerated using VMware's "Generate" function
to prevent any address collision.

**Standardized administrator credentials.**
A single administrative account with a strong password is configured identically across all
VMs during installation. This account will later be secured through Ed25519-only SSH
authentication and Fail2ban enforcement in Phase 06.

**OpenSSH enabled at installation.**
The OpenSSH server is selected during the Ubuntu Server installer's package selection step
on all VMs, enabling immediate SSH access for remote administration from the host machine.

---

## Post-Deployment Health Checks

Upon completion of all seven installations, the following verification sequence is executed
locally on the console of each VM to confirm viability before network configuration begins.

**System stability**
```bash
systemctl is-system-running
# Expected: "running" or "degraded"
# "degraded" is acceptable at this stage — it reflects the absence of network
# connectivity, not a critical service failure.
```

**Hostname verification**
```bash
hostnamectl
# Verifies that the static hostname matches the intended topology label
# (routeur / haproxy / apache1 / apache2 / client / mysql / elk)
```

**Network interface detection**
```bash
ip link show
# Confirms that VMware has correctly exposed the expected number of virtual
# interfaces to the OS. The router must show 5 interfaces (ens33 through ens37).
# All other VMs must show exactly 1 interface.
```

**Storage availability**
```bash
df -h /
# Confirms disk utilization below 50% post-install on all VMs.
```

---

## Initial System Provisioning

Due to the strict Layer 2 isolation enforced by the VMnet design, only the router has
internet access at this stage via its WAN interface (NAT). Internal VMs — haproxy,
apache-1, apache-2, client, mysql, elk — have no outbound connectivity.

System updates and diagnostic package installation are therefore performed exclusively on
the router during Phase 00:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y net-tools curl wget vim git
```

Updates on all internal nodes are intentionally deferred to Phase 02, after NAT/MASQUERADE
is configured on the router. This sequencing preserves the integrity of the defense-in-depth
model: internal VMs are never provisioned in an uncontrolled network state.

---

## Outcome

The virtualized infrastructure foundation is operational:

- 4 isolated VMnets created with VMware DHCP service disabled
- 7 Ubuntu Server 22.04 LTS VMs provisioned with correct resource allocations
- Unique MAC addresses and machine IDs confirmed across the fleet
- All VMs start cleanly; no critical service failures at boot
- Router internet access confirmed via WAN NAT interface
- Internal VM updates deferred pending NAT activation in Phase 02

**Next phase:** [Phase 01 — Static Network Addressing (Netplan)](phase-01-network-configuration.md)

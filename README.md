# Defense-in-Depth Network Infrastructure

A production-grade, single-site virtualized network implementing strict trust-zone isolation,
stateful packet filtering, load-balanced web services, centralized SIEM monitoring, and
full deployment automation — with an effective migration to AWS using native cloud security
primitives.

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Features](#features)
- [Technologies](#technologies)
- [Repository Structure](#repository-structure)
- [Deployment Guide](#deployment-guide)
- [Security Architecture](#security-architecture)
- [AWS Deployment](#aws-deployment)
- [Validation & Benchmarks](#validation--benchmarks)
- [Future Improvements](#future-improvements)
- [License](#license)
- [Author](#author)

---

## Executive Summary

This project designs, deploys, and validates a single-site virtualized network infrastructure
built on defense-in-depth principles. Seven Ubuntu Server 22.04 LTS virtual machines are
organized across four strictly isolated trust zones — DMZ, Clients, Internal Servers, and
Supervision — interconnected exclusively through a stateful Linux router-firewall that enforces
a default-deny policy on all inter-zone traffic.

The infrastructure delivers HTTP/HTTPS load balancing with automatic failover through HAProxy,
real-time security event monitoring through a centralized ELK stack, and automated system
hardening aligned with the CIS Benchmark for Ubuntu Server 22.04. All configuration is
delivered through four idempotent Bash scripts, making the entire deployment reproducible and
auditable from a clean state.

The architecture is validated against fourteen functional and offensive test scenarios covering
network isolation, firewall policy enforcement, authentication security, intrusion detection,
and performance benchmarks. It extends to an effective deployment on AWS, replicating the
local security model using native cloud primitives — VPC, EC2, ALB, AWS WAF, IAM roles,
KMS encryption, and CloudTrail.

---

## Project Overview

### Context

Modern organizations face an increasingly hostile threat landscape: external reconnaissance,
lateral movement, data exfiltration, and supply-chain compromise demand a fundamental departure
from perimeter-only security models. This project implements a multi-layer defense-in-depth
architecture in which every infrastructure component actively contributes to the overall
security posture, rather than relying on a single boundary control.

The proliferation of attack vectors imposes a break with traditional perimeter security in
favor of a multi-layered approach where isolation, filtering, authentication, intrusion
response, and supervision operate as independent, complementary controls.

### Problem Statement

How does one design, deploy, and validate a segmented, highly available, supervised, and
cloud-migratable network infrastructure — capable of strictly isolating trust zones, automating
its own deployment through idempotent scripts, demonstrating resilience against controlled
attack scenarios, and mapping its entire security model directly onto AWS native services?

### Objectives

**Functional**
- Deploy a four-zone segmented architecture with load-balanced and redundant web services in
  the DMZ
- Enforce strict zone isolation following the principle of least privilege at the network level
- Centralize real-time security event monitoring via a dedicated SIEM (ELK stack)
- Deploy and validate an equivalent architecture on AWS

**Technical**
- Implement an industry-compliant security stack: default-deny iptables policy, Ed25519
  asymmetric authentication, HAProxy load balancing, centralized SIEM
- Operate in a fully reproducible, documented, and auditable virtualized environment automated
  through idempotent Bash scripts
- Validate architecture resilience through controlled offensive scenarios (Red Team approach)
- Deploy on AWS with EBS encryption via KMS, an Application Load Balancer, and AWS WAF

**Professional**
- Apply rigorous engineering methodology: requirements analysis, architecture design,
  automation, validation, and critical analysis
- Demonstrate operational mastery of cloud-native AWS environments and DevSecOps automation
  practices

---

## Architecture

### Infrastructure Overview

The infrastructure follows a single-site model anchored by a multi-homed Linux router that
acts as the sole gateway between zones. No direct communication exists between trust zones —
all inter-zone traffic is forced through the router's stateful iptables firewall. Zone
isolation is enforced at both Layer 2 (separate VMnets with no shared broadcast domain) and
Layer 3 (default-deny FORWARD chain).

```
                            Internet / WAN
                                  |
               ┌──────────────────▼──────────────────┐
               │            ROUTER-FIREWALL           │
               │    iptables · NAT/MASQUERADE         │
               │    ip_forward=1 · default DROP/FWD   │
               │    5 interfaces: ens33 – ens37       │
               │    systemd rollback timer (60s)       │
               └──┬──────────┬──────────┬──────────┬──┘
                  │          │          │          │
       ┌──────────▼──┐  ┌────▼────┐  ┌─▼──────┐  ┌▼─────────────┐
       │     DMZ     │  │ Clients │  │Servers │  │ Supervision  │
       │172.16.40/24 │  │192.168  │  │192.168 │  │ 192.168.30   │
       │             │  │.10.0/24 │  │.20.0/24│  │   .0/24      │
       │  ┌────────┐ │  │         │  │        │  │              │
       │  │HAProxy │ │  │ Client  │  │ MySQL  │  │  ELK Stack   │
       │  │  .10   │ │  │  DHCP   │  │  8.0   │  │ ES+LS+Kibana │
       │  └──┬──┬──┘ │  │.100–200 │  │  .10   │  │    .10       │
       │     │  │    │  │         │  │        │  │              │
       │  ┌──▼┐┌▼──┐ │  └─────────┘  └────────┘  └──────────────┘
       │  │A-1││A-2│ │       ▲              ▲              ▲
       │  │.11││.12│ │       │              │              │
       │  └───┘└───┘ │       └──────────────┴──────────────┘
       └─────────────┘         rsyslog UDP/514 from all zones
              │
              │ 3306/tcp (only authorized DMZ → Servers flow)
              └──────────────────────────────────────────────►MySQL
```

### Network Segmentation

| Zone | VMnet | Subnet | Gateway | IP Assignment |
|---|---|---|---|---|
| DMZ | VMnet10 | 172.16.40.0/24 | 172.16.40.254 | Static — .10 HAProxy, .11 Apache-1, .12 Apache-2 |
| Clients | VMnet11 | 192.168.10.0/24 | 192.168.10.254 | DHCP — range .100–.200 |
| Internal Servers | VMnet12 | 192.168.20.0/24 | 192.168.20.254 | Static — .10 MySQL |
| Supervision | VMnet13 | 192.168.30.0/24 | 192.168.30.254 | Static — .10 ELK Stack |

Gateways are positioned at .254 on every zone. The absence of a transit or management subnet
eliminates the VPN attack surface present in traditional hub-and-spoke models and simplifies
the addressing plan.

### Virtual Machine Inventory

| VM | Role | Zone | Address | Resources |
|---|---|---|---|---|
| routeur | Multi-homed router-firewall, NAT gateway, DHCP server | All zones | .254/zone + DHCP (WAN) | 1 vCPU · 1 GB |
| haproxy | HTTP/HTTPS load balancer, sole public entry point | DMZ | 172.16.40.10 | 1 vCPU · 1 GB |
| apache-1 | Primary web node | DMZ | 172.16.40.11 | 1 vCPU · 1 GB |
| apache-2 | Secondary web node (redundancy) | DMZ | 172.16.40.12 | 1 vCPU · 1 GB |
| client | User workstation, test origin | Clients | DHCP (.100–.200) | 1 vCPU · 1 GB |
| mysql | Application database (MySQL 8.0) | Internal Servers | 192.168.20.10 | 1 vCPU · 1 GB |
| elk | Elasticsearch + Logstash + Kibana | Supervision | 192.168.30.10 | 2 vCPU · 5 GB |

### Inter-Zone Traffic Matrix

| Source | Destination | Protocol / Port | Action |
|---|---|---|---|
| Internet (WAN) | HAProxy (172.16.40.10) | TCP 80, 443 | ACCEPT |
| HAProxy | Apache-1, Apache-2 | TCP 80, 443 | ACCEPT |
| DMZ — Apache | MySQL (192.168.20.10) | TCP 3306 | ACCEPT |
| DMZ — Apache | All other internal zones | Any | LOG + DROP [FW-BLOCK] |
| Clients | HAProxy (172.16.40.10) | TCP 80, 443 | ACCEPT |
| Any zone | Any VM (administration) | TCP 22 | ACCEPT |
| Any zone | ELK (192.168.30.10) | UDP 514 | ACCEPT |
| Any | Any (undefined) | Any | LOG + DROP [FW-BLOCK] |

### End-to-End Request Flow

A complete HTTP request from an external client traverses eight steps:

1. The client sends a request to the router's WAN address on port 80 or 443. iptables accepts
   the packet on those ports toward the DMZ only.
2. The router forwards the packet to HAProxy (172.16.40.10) via NAT/FORWARD.
3. HAProxy selects a backend in round-robin — Apache-1 or Apache-2 — based on its active
   health-check state.
4. The selected Apache node queries MySQL (192.168.20.10:3306), the only authorized flow
   from the DMZ into the Servers zone.
5. All VMs continuously forward their logs to ELK (192.168.30.10:514) via rsyslog in parallel
   with all application traffic.
6. MySQL returns the query result to the Apache backend.
7. Apache returns the HTTP response to HAProxy.
8. HAProxy forwards the final response through the router back to the originating client.

---

## Features

**Trust-zone isolation**
Four network segments with no shared broadcast domain. Layer 2 isolation is provided by
separate VMnets; Layer 3 isolation is enforced by the stateful firewall. No zone can reach
another without an explicit authorization in the traffic matrix.

**Default-deny stateful firewall with rollback safety**
The iptables FORWARD chain enforces a DROP-by-default policy. Every rejected packet is
logged with the `[FW-BLOCK]` prefix for SIEM correlation. Silent DROP (no RST emitted)
prevents infrastructure fingerprinting. A systemd-based rollback timer automatically
restores connectivity if the administrator does not confirm new rules within 60 seconds,
preventing accidental self-lockout.

**Load-balanced, redundant web tier**
HAProxy distributes HTTP/HTTPS traffic across two Apache nodes in round-robin mode with an
active HTTP health-check every 4 seconds. A node is removed from rotation after two
consecutive failures (8 seconds total) and reintegrated after three successive checks pass.
Failover is automatic and transparent. A custom HTTP 503 page is returned if both nodes
fail simultaneously. Content between Apache-1 and Apache-2 is kept in sync through a
scheduled rsync job (every 5 minutes), guaranteeing consistency across failovers.

**Centralized SIEM with near-real-time detection**
Every machine forwards its logs to the dedicated Supervision zone via rsyslog (UDP/514).
Logstash parses events using Grok patterns tailored to iptables, HAProxy, SSH, and MySQL.
Elasticsearch indexes all events with a 30-day retention policy. Kibana dashboards cover
SSH intrusion attempts, blocked traffic ([FW-BLOCK]), HAProxy activity, and MySQL
connections. Target mean time to detection (MTTD): under 10 seconds.

**Asymmetric SSH authentication**
SSH password authentication is structurally disabled at the OpenSSH configuration level
across all VMs. Access is exclusively through Ed25519 key pairs. Ed25519 is preferred over
RSA for its stronger security guarantees, smaller key footprint, and resistance to
timing-based side-channel attacks.

**Automated intrusion response**
Fail2ban monitors `/var/log/auth.log` and issues dynamic iptables DROP rules after detecting
three failed authentication attempts within a 600-second rolling window. Ban latency target:
under 60 seconds from the triggering event.

**Idempotent Bash automation**
All deployment is scripted through four idempotent Bash scripts — `firewall.sh`,
`deploy_haproxy.sh`, `deploy_elk.sh`, and `hardening.sh`. Scripts can be re-executed
repeatedly without altering the expected final state, enabling safe updates, reproductions
from scratch, and recovery from configuration drift.

**CIS Benchmark compliance verification**
The hardening script applies CIS Benchmark controls for Ubuntu Server 22.04 and verifies
compliance using Lynis. Target score: above 70/100.

**AWS cloud migration**
The entire local architecture is replicated on AWS using native security primitives,
providing a direct cloud-native equivalent of every local security control.

---

## Technologies

| Category | Technology | Version | Role |
|---|---|---|---|
| Virtualization | VMware Workstation Player | 17.x | Type-2 hypervisor, isolated VMnet management |
| Operating System | Ubuntu Server | 22.04 LTS | All VMs — minimized installation profile |
| Firewall | iptables | 1.8.7 legacy | Stateful filtering, default DROP, [FW-BLOCK] logging |
| Anti-bruteforce | Fail2ban | Latest stable | SSH protection — 3 failures/600s → iptables ban |
| Secure shell | OpenSSH | Latest stable | Ed25519 key-only remote administration |
| Compliance audit | Lynis | Latest stable | CIS Benchmark verification, hardening scoring |
| Load balancer | HAProxy | 2.4 LTS+ | L7 round-robin, active health-check every 4s |
| Content sync | rsync | Native Ubuntu | Apache-1 → Apache-2 content synchronization via cron |
| DHCP | isc-dhcp-server | Latest stable | Client address distribution — range .100–.200 |
| Web server | Apache HTTP Server | 2.4 | Dual-instance DMZ web nodes |
| Database | MySQL Server | 8.0 | Application backend — zone Servers |
| Log agent | rsyslog | Native Ubuntu | UDP/514 forwarding from all VMs to the SIEM |
| Log pipeline | Logstash | 8.x | Grok parsing for iptables, HAProxy, SSH, MySQL |
| Search engine | Elasticsearch | 8.x | Event indexing, full-text search, 30-day retention |
| Visualization | Kibana | 8.x | Real-time dashboards and alerting |
| Performance | iperf3, ApacheBench | Latest stable | Network throughput and HTTP benchmarking |

---

## Repository Structure

```
secure-network-defense-in-depth/
│
├── README.md
├── LICENSE
├── .gitignore
│
├── docs/
│   ├── phase-00-environment-setup.md
│   ├── phase-01-network-configuration.md
│   ├── phase-02-inter-zone-routing.md
│   ├── phase-03-firewall-policy.md
│   ├── phase-04-application-services.md
│   ├── phase-05-elk-siem.md
│   ├── phase-06-hardening.md
│   ├── phase-07-aws-deployment.md
│   ├── phase-08-validation.md
│   └── architecture/
│       └── network-diagram.png
│
├── scripts/
│   ├── firewall.sh          # iptables policy, NAT, [FW-BLOCK] logging, rollback timer
│   ├── deploy_haproxy.sh    # HAProxy, rsync cron, DHCP
│   ├── deploy_elk.sh        # Elasticsearch, Logstash, Kibana, rsyslog pipeline
│   └── hardening.sh         # Fail2ban, SSH hardening, CIS Benchmark controls
│
├── configs/
│   ├── netplan/             # Per-VM Netplan YAML configuration files
│   ├── haproxy/             # haproxy.cfg
│   ├── logstash/            # Pipeline definition, Grok patterns, GeoIP
│   └── kibana/              # Dashboard exports (.ndjson)
│
├── evidence/
│   ├── phase-00/
│   ├── phase-01/
│   ├── phase-02/
│   └── ...                  # Terminal captures and screenshots per phase
│
└── aws/
    ├── security-groups.md   # Security Group rules mirroring the inter-zone matrix
    └── architecture-aws.md  # AWS deployment documentation
```

---

## Deployment Guide

### Prerequisites

- Host machine with a minimum of 8 GB RAM (16 GB recommended) and 50 GB free disk space
- VMware Workstation Player 17.x
- Ubuntu Server 22.04 LTS ISO
- An AWS account (Free Tier compatible for most resources; ALB and AWS WAF incur minor
  charges — activate billing alerts before creating any resources)

### Environment Setup

Create four isolated host-only VMnets (VMnet10 through VMnet13) in VMware's Virtual Network
Editor with the VMware DHCP service disabled on each. Provision seven Ubuntu Server 22.04
VMs using the hardware allocations from the inventory table. Allocate a minimum of 5 GB RAM
to the ELK VM — Elasticsearch will not start reliably below this threshold.

All VMs should be created from scratch (not cloned) to guarantee unique MAC addresses and
machine IDs across the fleet.

### Static Network Addressing

Configure each VM's network interfaces via Netplan (`/etc/netplan/`). The router receives
five interfaces: DHCP on the WAN interface and static .254 gateways on each internal zone
with no `gateway4` directive on the internal interfaces. Apply configurations with:

```bash
sudo chmod 600 /etc/netplan/*.yaml
sudo netplan try    # validates the configuration; auto-rolls back after 120s if unconfirmed
sudo netplan apply
```

Enable IP forwarding persistently on the router:

```bash
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-forwarding.conf
sudo sysctl -p /etc/sysctl.d/99-forwarding.conf
```

### Inter-Zone Routing and NAT

Deploy a MASQUERADE rule on the router's WAN interface to provide internet access to
internal VMs and enable deferred system updates:

```bash
sudo iptables -t nat -A POSTROUTING -o ens33 -j MASQUERADE
sudo apt install -y iptables-persistent   # persists the NAT rule across reboots
```

Verify inter-zone reachability from the Client VM using `ping` and `traceroute` to all other
zones. The traceroute output must show the router's gateway IP as the first hop — confirming
that no zone-bypass exists at Layer 2.

### Firewall Policy

Deploy `scripts/firewall.sh` on the router. The script enforces the inter-zone traffic
matrix, configures [FW-BLOCK] logging on all DROP decisions, and arms a systemd timer that
automatically restores connectivity if the administrator does not confirm the new ruleset
within 60 seconds:

```bash
sudo bash scripts/firewall.sh
```

The script is idempotent: re-running it flushes and rebuilds the ruleset without leaving
orphaned rules. Verify with `nmap -sS` from each zone — zero unauthorized ports should be
reachable across zone boundaries.

### Application Services

Deploy the full application tier using `scripts/deploy_haproxy.sh`. This script configures
the DHCP server on the router, generates and deploys Ed25519 SSH key pairs across all VMs,
installs and configures Apache on both DMZ web nodes, installs MySQL 8.0 on the Servers VM,
deploys HAProxy with round-robin load balancing and a 4-second active health-check, and
schedules rsync content synchronization from Apache-1 to Apache-2 every 5 minutes:

```bash
sudo bash scripts/deploy_haproxy.sh
```

Validate: HAProxy distributes requests across both Apache nodes when both are healthy, and
fails over automatically in under 10 seconds when a node stops responding.

### ELK Stack and Centralized Logging

Deploy `scripts/deploy_elk.sh` on the ELK VM. The script installs Elasticsearch 8.x with
appropriate JVM heap sizing and a 30-day index retention policy, Logstash with Grok patterns
for iptables, HAProxy, SSH, and MySQL events, and Kibana with pre-built dashboards for
intrusion attempts, blocked traffic, load balancer activity, and database connections.
rsyslog is configured on all VMs to forward events to 192.168.30.10:514:

```bash
sudo bash scripts/deploy_elk.sh
```

Validate: generate a test log entry with `logger "test"` on any VM and confirm visibility
in Kibana within 15 seconds.

### System Hardening

Deploy `scripts/hardening.sh` on all VMs. The script configures Fail2ban with a 3-attempt
threshold and 600-second rolling window, disables SSH password authentication at the
configuration level, applies CIS Benchmark controls (service minimization, file permissions,
umask), and runs a Lynis audit. Add the administrator's IP to the Fail2ban whitelist before
executing any offensive test scenarios:

```bash
sudo bash scripts/hardening.sh
```

Target Lynis score: above 70/100.

### AWS Deployment

Replicate the architecture on AWS in the following order:

1. Activate billing alerts before creating any resource
2. Create a VPC with public subnets (DMZ equivalent) and private subnets (Servers,
   Supervision)
3. Launch EC2 instances (Ubuntu 22.04) replicating each local VM role
4. Configure Security Groups mirroring the inter-zone traffic matrix
5. Create a KMS Customer Managed Key (CMK) and enable EBS encryption on all volumes
6. Create IAM roles with least-privilege policies per EC2 instance — no shared credentials,
   no long-lived access keys
7. Deploy an Application Load Balancer and attach an AWS WAF Web ACL using the Core Rule Set
   (protection against SQLi, XSS, and HTTP flood)
8. Enable CloudTrail for full API call audit logging

---

## Security Architecture

### Defense-in-Depth Model

Security is implemented across six independent and complementary layers. A breach at any
single layer does not compromise the overall posture — every other layer continues to enforce
its controls independently.

| Layer | Control | Implementation |
|---|---|---|
| 1 — Network isolation | Zone segmentation | 4 trust zones with no shared broadcast domain; all inter-zone traffic forced through the firewall |
| 2 — Stateful filtering | Default-deny firewall | iptables DROP policy on FORWARD chain; [FW-BLOCK] logging; silent DROP; 60s rollback |
| 3 — Authentication | Asymmetric SSH only | Ed25519 keys; PasswordAuthentication no at config level — not just policy |
| 4 — Intrusion response | Automated banning | Fail2ban; 3 failures / 600s window; ban < 60s; whitelist for admin IPs |
| 5 — Supervision | Real-time SIEM | rsyslog → Logstash → Elasticsearch → Kibana; MTTD < 10s; logs stored in an isolated zone |
| 6 — Cloud-native security | AWS primitives | KMS, IAM least privilege, Security Groups, ALB + WAF, CloudTrail |

### Firewall Policy Detail

The `firewall.sh` script applies the following iptables configuration on the router:

- **INPUT chain:** DROP by default; ACCEPT established/related traffic and explicitly
  permitted services (SSH on the management port)
- **FORWARD chain:** DROP by default; ACCEPT only flows defined in the inter-zone traffic
  matrix; all other packets are logged with the `[FW-BLOCK]` prefix before being dropped
- **OUTPUT chain:** ACCEPT (router-originated traffic)
- **NAT/POSTROUTING:** MASQUERADE on the WAN interface for outbound internet access from
  internal zones

Silent DROP (without emitting an RST packet) is intentional: it prevents external adversaries
from mapping the internal topology through response behavior differences.

The rollback mechanism arms a systemd one-shot timer at script startup. If the administrator
does not send a confirmation signal within 60 seconds, the timer fires, flushes all rules,
and restores a temporary ACCEPT policy — preventing permanent accidental self-lockout.

### Known Architectural Limitations

The following limitations are explicitly documented and accepted within the scope of this
project, with planned resolution paths:

| Domain | Limitation | Severity | Planned Resolution |
|---|---|---|---|
| Infrastructure | Single point of failure on the router-firewall | High | Keepalived/VRRP; or AWS Multi-AZ |
| Load balancing | HAProxy itself is a SPOF in the current design | High | Second HAProxy instance with Keepalived/VRRP |
| Storage | Local VM disks are unencrypted at rest | High | LUKS full-disk encryption on local volumes |
| Detection | No network-level IDS/IPS | Medium | Suricata integration (planned) |
| Identity | No multi-factor authentication on admin accounts | Medium | TOTP via libpam-google-authenticator |
| Content sync | rsync introduces up to 5 minutes of eventual consistency | Low | Shared NFS or GlusterFS for strong consistency |

---

## AWS Deployment

### Architecture Mapping

| AWS Service | Local Equivalent | Configuration |
|---|---|---|
| VPC + Subnets | VMware VMnets | Public subnets for DMZ, private subnets for Servers and Supervision |
| EC2 (Ubuntu 22.04) | VMware VMs | One instance per logical role |
| Application Load Balancer | HAProxy | HTTPS termination, HTTP/2, distribution across web EC2 instances |
| AWS WAF | No local equivalent | Core Rule Set: SQLi, XSS, HTTP flood; attached to the ALB |
| IAM Roles | Local root access | One role per EC2 instance; minimal permissions; no shared credentials |
| AWS KMS (CMK) | No local disk encryption | Customer-managed key encrypting all EBS volumes at rest |
| Security Groups | iptables | Stateful allowlist; reproduces the inter-zone traffic matrix |
| CloudTrail | rsyslog / ELK | Full audit trail of all AWS API calls across all services |

### Cost Considerations

Most services used in this project fall within the AWS Free Tier (EC2 t2.micro/t3.micro,
VPC, Security Groups, IAM, CloudTrail). The Application Load Balancer and AWS WAF fall
outside Free Tier and incur minor but real charges. Activate a billing alert at a threshold
appropriate for a student project — such as $10 — before creating any resources. Terminate
all resources at the end of the project.

---

## Validation & Benchmarks

### Test Matrix

| ID | Component | Tooling | Success Criteria |
|---|---|---|---|
| T-01 | Intra-zone routing | ping, traceroute, ip route | 100% of zones reachable through their designated gateways |
| T-02 | Firewall policy | nmap -sS, nc, curl | 0 unauthorized ports accessible across zone boundaries; rollback tested without lockout |
| T-03 | DHCP service | dhclient, ip addr | Client receives a lease in the .100–.200 range in under 10 seconds |
| T-04 | SSH key authentication | ssh with Ed25519 key | Connection established successfully |
| T-05 | SSH password authentication | ssh with password | Access denied systematically |
| T-06 | Fail2ban | hydra, fail2ban-client status | Effective ban in under 60s after 3 failures within a 600s window |
| T-07 | rsyslog → ELK pipeline | logger, Kibana | Log entry visible in Kibana in under 15 seconds after generation |
| T-08 | SSH attack MTTD | Kibana alert timestamp | Detection time under 10 seconds |
| T-09 | DMZ / internal isolation | nmap from DMZ, nc | Zero internal services reachable from the DMZ except TCP 3306 |
| T-10 | HAProxy load balancing | curl, ApacheBench | Round-robin distribution confirmed; automatic failover in under 10s |
| T-11 | Content sync (rsync) | ApacheBench, md5sum | HTTP 200 on ports 80 and 443; identical MD5 checksums post-sync |
| T-12 | External reconnaissance | nmap -sS -sV -O | Only ports 80 and 443 visible; no version or internal service information disclosed |
| T-13 | AWS connectivity | curl, AWS Console | EC2 reachable exclusively via ALB; HTTP 200 response confirmed |
| T-14 | EBS encryption | AWS Console, describe-volumes | Volumes marked Encrypted; CMK identified; access logged in CloudTrail |

### Performance Targets

| Metric | Target | Measurement Tool |
|---|---|---|
| Local network throughput (VM-to-VM) | > 900 Mbps | iperf3 |
| HTTP throughput through HAProxy | > 5,000 req/s | ApacheBench (ab) |
| HAProxy automatic failover time | < 10 seconds | Node failure test |
| ELK event processing throughput | > 1,000 events/min | rsyslog load test |
| Log ingestion latency (rsyslog → Kibana) | < 15 seconds | logger timestamp delta |
| SSH attack detection time (MTTD) | < 10 seconds | Kibana alert timestamp |
| Fail2ban ban latency | < 60 seconds | hydra + fail2ban-client |
| Elasticsearch log retention | 30 days | Index lifecycle policy |
| Lynis hardening score | > 70 / 100 | Lynis audit report |

---

## Future Improvements

**High availability (0–3 months)**
Deploy a second router-firewall instance with Keepalived/VRRP to eliminate the gateway
single point of failure. Apply the same redundancy pattern to HAProxy with a floating virtual
IP, removing the only remaining applicative SPOF.

**Infrastructure as Code (0–3 months)**
Replace the current Bash scripts with an Ansible role-based structure (router, haproxy,
apache, mysql, hardening, supervision) for fully declarative local deployment. Provision the
entire AWS topology through Terraform modules (VPC, subnets, Security Groups, EC2, KMS, WAF).

**Containerization and orchestration (3–6 months)**
Transform HAProxy, Apache, MySQL, and ELK into Docker containers using hardened base images
(Alpine or distroless). Deploy on a Kubernetes cluster — kubeadm locally or EKS on AWS —
for native auto-healing, horizontal scaling, and rolling updates.

**Zero Trust architecture (6–12 months)**
Implement mutual TLS (mTLS) between all services so that each component authenticates its
peers through X.509 certificates, tolerating no plaintext inter-service communication.
Replace static iptables rules with Cilium eBPF network policies for dynamic microsegmentation
and network-level identity enforcement.

**Advanced cloud security**
Activate Amazon GuardDuty for ML-based threat detection across CloudTrail, VPC Flow Logs,
and DNS. Aggregate findings centrally in AWS Security Hub alongside Inspector and Macie
results. Enforce continuous resource compliance through AWS Config Rules.

**Identity hardening**
Implement TOTP-based multi-factor authentication on all administrator accounts. Migrate to
short-lived SSH certificates issued by a certificate authority (HashiCorp Vault or AWS IAM
Roles Anywhere), eliminating static long-lived key management.

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

## Author

**Reda Bouzekraoui**
Engineering student — GSR (*Génie des Systèmes et Réseaux*)
ENSA Tanger, Morocco

[LinkedIn](linkedin.com/in/reda-bouzekraoui-055a3a377) · [Email](redabouzekraui@gmail.com)

---

*Educational lab environment built as a capstone engineering project. Not intended for
production deployment.*
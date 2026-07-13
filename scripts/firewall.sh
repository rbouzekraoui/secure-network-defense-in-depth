#!/bin/bash

set -euo pipefail

# INTERFACES
WAN="ens33"
DMZ="ens34"
CLIENTS="ens35"
SERVERS="ens36"
SUPERVISION="ens37"

# IP ADDRESSES
LB_IP="172.16.40.10"
APACHE1_IP="172.16.40.11"
APACHE2_IP="172.16.40.12"
MYSQL_IP="192.168.20.10"
ELK_IP="192.168.30.10"

# ROLLBACK MECHANISM
# Arms a 60 second systemd timer. If the administrator does not confirm the new ruleset within this window, iptables is flushed and a temporary ACCEPT policy is restored to prevent accidental administrator lockout.

# Cancel any existing timer (idempotence)
systemctl stop firewall-rollback.timer 2>/dev/null || true
systemctl reset-failed firewall-rollback.service 2>/dev/null || true

systemd-run \
  --unit=firewall-rollback \
  --description="Firewall rollback safety timer" \
  --on-active=60 \
  /bin/bash -c "
    iptables -F;
    iptables -F -t nat;
    iptables -P INPUT ACCEPT;
    iptables -P FORWARD ACCEPT;
    iptables -P OUTPUT ACCEPT;
    logger -t firewall '[firewall.sh] ROLLBACK TRIGGERED — rules flushed, temporary ACCEPT policy restored';
  "

echo "[firewall.sh] Rollback timer armed (60s)."
echo "[firewall.sh] To confirm ruleset: sudo systemctl stop firewall-rollback.timer"

# FLUSH EXISTING RULES (idempotence)
# Every execution starts from a clean state; no orphaned rules possible.
iptables -F
iptables -F -t nat
iptables -F -t mangle
iptables -X 2>/dev/null || true

# DEFAULT POLICIES
iptables -P INPUT   DROP    # All traffic destined for the router: denied by default
iptables -P FORWARD DROP    # All inter-zone transit: denied by default
iptables -P OUTPUT  ACCEPT  # Traffic originated by the router itself: allowed

# STATEFUL TRACKING
# Allow responses to already-established connections (stateful inspection)
iptables -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# LOOPBACK
iptables -A INPUT -i lo -j ACCEPT

# INPUT CHAIN : Traffic destined for the router itself

# SSH : administration from all zones
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# DHCP : client requests (Clients zone)
iptables -A INPUT -i "$CLIENTS" -p udp --dport 67 -j ACCEPT

# rsyslog : local log forwarding from the router to ELK
iptables -A INPUT -p udp --dport 514 -j ACCEPT

# All other traffic toward the router: logged then silently dropped
iptables -A INPUT -j LOG --log-prefix "[FW-BLOCK] " --log-level 4
iptables -A INPUT -j DROP

# NAT / MASQUERADE 
# SNAT: rewrites internal source addresses on the WAN interface
# Provides internet access to all internal zones via the router
iptables -t nat -A POSTROUTING -o "$WAN" -j MASQUERADE

# FORWARD CHAIN : Inter-zone traffic matrix (CDC §5.3) 

# 1. Internet → HAProxy (ports 80 and 443 only)
iptables -A FORWARD -i "$WAN"     -o "$DMZ" -d "$LB_IP" -p tcp --dport 80  -j ACCEPT
iptables -A FORWARD -i "$WAN"     -o "$DMZ" -d "$LB_IP" -p tcp --dport 443 -j ACCEPT

# 2. Clients zone → HAProxy (ports 80 and 443 only)
iptables -A FORWARD -i "$CLIENTS" -o "$DMZ" -d "$LB_IP" -p tcp --dport 80  -j ACCEPT
iptables -A FORWARD -i "$CLIENTS" -o "$DMZ" -d "$LB_IP" -p tcp --dport 443 -j ACCEPT

# 3. DMZ (Apache) → MySQL (port 3306 only, sole authorized DMZ → Servers flow)
iptables -A FORWARD -i "$DMZ" -o "$SERVERS" -s "$APACHE1_IP" -d "$MYSQL_IP" -p tcp --dport 3306 -j ACCEPT
iptables -A FORWARD -i "$DMZ" -o "$SERVERS" -s "$APACHE2_IP" -d "$MYSQL_IP" -p tcp --dport 3306 -j ACCEPT

# 4. SSH : inter-zone administration (any zone to any VM)
iptables -A FORWARD -p tcp --dport 22 -j ACCEPT

# 5. rsyslog : all zones → ELK (UDP/514)
iptables -A FORWARD -o "$SUPERVISION" -d "$ELK_IP" -p udp --dport 514 -j ACCEPT

# 6. Outbound internet : all internal zones via NAT (required for apt and updates)
iptables -A FORWARD -i "$DMZ"        -o "$WAN" -j ACCEPT
iptables -A FORWARD -i "$CLIENTS"    -o "$WAN" -j ACCEPT
iptables -A FORWARD -i "$SERVERS"    -o "$WAN" -j ACCEPT
iptables -A FORWARD -i "$SUPERVISION" -o "$WAN" -j ACCEPT

# LOGGING AND FINAL DROP
# Any packet not explicitly authorized: logged with [FW-BLOCK] prefix, then silently dropped (no RST emitted, prevents infrastructure fingerprinting)
iptables -A FORWARD -j LOG --log-prefix "[FW-BLOCK] " --log-level 4
iptables -A FORWARD -j DROP

# SUMMARY
echo "[firewall.sh] Policy applied successfully."
echo ""
echo "  REMINDER: rollback timer expires in 60 seconds."
echo "  To permanently confirm the ruleset:"
echo "  sudo systemctl stop firewall-rollback.timer"
echo ""
iptables -L FORWARD --line-numbers -n
#!/bin/bash

# IMPORTANT — set ROUTER_MODE="yes" ONLY when running on the router VM.
# The router legitimately forwards traffic between zones; applying the full CIS network ruleset there (rp_filter, accept_redirects, send_redirects) would break inter-zone routing.
# PREREQUISITE — Ed25519 SSH keys must already be deployed and verified on every VM (Phase 04). This script disables password authentication; running it before key access is confirmed will lock the administrator out.

set -euo pipefail

# ROUTER SAFETY FLAG
ROUTER_MODE="no"

# FAIL2BAN WHITELIST
# Internal administration networks exempt from banning.
# Temporarily remove the source subnet when running offensive tests (T-06).
TRUSTED_NET="192.168.10.0/24 172.16.40.0/24 192.168.20.0/24 192.168.30.0/24"

echo "[hardening.sh] Starting system hardening v2.1 (ROUTER_MODE=${ROUTER_MODE})..."

# 1. FAIL2BAN AND AUDIT TOOLING
apt-get update -y
apt-get install -y fail2ban libpam-tmpdir acct lynis auditd rkhunter \
                   debsums libpam-pwquality

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${TRUSTED_NET}
bantime  = 600
findtime = 600
maxretry = 3
banaction = iptables-multiport

[sshd]
enabled  = true
port     = 22
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
findtime = 600
bantime  = 600
mode     = aggressive
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# 2. LOCAL ACCOUNT POLICY AND SYSTEM LIMITS
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 90/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS 1/'  /etc/login.defs
sed -i 's/^UMASK.*/UMASK 027/'                /etc/login.defs

# Disable core dumps (prevents memory disclosure through crash dumps)
echo "* hard core 0" > /etc/security/limits.d/disable-coredumps.conf

# Legal warning banner (pre- and post-authentication)
echo "WARNING: Authorized access only." > /etc/issue
echo "WARNING: Authorized access only." > /etc/issue.net

# 3. SSH HARDENING — key-only authentication
# Ubuntu 22.04 may carry cloud-init drop-ins that re-enable password auth; they are neutralized first, then the main config is set.
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' \
  /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true

sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/'  /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'                /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/'     /etc/ssh/sshd_config
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/'                    /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/'                       /etc/ssh/sshd_config
sed -i 's/^#*AllowTcpForwarding.*/AllowTcpForwarding no/'          /etc/ssh/sshd_config
sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/'         /etc/ssh/sshd_config
sed -i 's/^#*Compression.*/Compression no/'                        /etc/ssh/sshd_config
sed -i 's/^#*LogLevel.*/LogLevel VERBOSE/'                         /etc/ssh/sshd_config

# Validate configuration before restarting — aborts on syntax error
sshd -t
systemctl restart ssh

# 4. CIS KERNEL PARAMETERS AND MODULE BLOCKLIST
# Disable rare filesystems and network protocols — attack surface reduction
cat > /etc/modprobe.d/cis-disable.conf << 'EOF'
install dccp /bin/true
install sctp /bin/true
install usb-storage /bin/true
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true
EOF

# Network parameters — role-dependent 
if [ "$ROUTER_MODE" = "yes" ]; then
  # Router: protections that do not interfere with packet forwarding.
  # rp_filter is included — empirically validated on this topology, where each zone is a single subnet behind a single interface, making all return paths strictly symmetric. See docs/phase-06-hardening.md for the validation.
  cat > /etc/sysctl.d/99-cis-hardening-net.conf << 'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
EOF
else
  # Endpoint servers: full CIS network hardening
  cat > /etc/sysctl.d/99-cis-hardening-net.conf << 'EOF'
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
EOF
fi

# System parameters — applied on every VM including the router
cat > /etc/sysctl.d/99-cis-hardening-sys.conf << 'EOF'
kernel.sysrq = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
fs.suid_dumpable = 0
EOF

sysctl -p /etc/sysctl.d/99-cis-hardening-net.conf
sysctl -p /etc/sysctl.d/99-cis-hardening-sys.conf

# 5. FILE PERMISSIONS
chmod 600 /etc/ssh/sshd_config
chmod 644 /etc/passwd
chmod 640 /etc/shadow

# 6. LYNIS COMPLIANCE AUDIT
echo ""
echo "[hardening.sh] Hardening applied. Running Lynis audit..."
lynis audit system --quick | grep -i "hardening index" || true

echo ""
echo "[hardening.sh] Complete. Full report: /var/log/lynis.log"

#!/bin/bash

set -euo pipefail

APACHE1="172.16.40.11"
APACHE2="172.16.40.12"
ELK="192.168.30.10"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
ERRORS_DIR="/etc/haproxy/errors"

echo "[deploy_haproxy.sh] Starting HAProxy deployment..."

# INSTALLATION
apt-get update -y
apt-get install -y haproxy rsync rsyslog cron

# HAPROXY CONFIGURATION
cat > "$HAPROXY_CFG" << 'EOF'
global
    log         /dev/log local0
    log         /dev/log local1 notice
    chroot      /var/lib/haproxy
    stats       socket /run/haproxy/admin.sock mode 660 level admin
    stats       timeout 30s
    user        haproxy
    group       haproxy
    daemon

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect  5s
    timeout client   30s
    timeout server   30s
    errorfile 503 /etc/haproxy/errors/503.http

frontend http_front
    bind *:80
    # bind *:443 ssl crt /etc/ssl/certs/haproxy.pem (A decommenter lors de la phase SSL)
    default_backend apache_pool

backend apache_pool
    balance     roundrobin
    option      httpchk GET /
    http-check  expect status 200
    server      apache1 172.16.40.11:80 check inter 4s fall 2 rise 3
    server      apache2 172.16.40.12:80 check inter 4s fall 2 rise 3
EOF

# CUSTOM 503 PAGE
mkdir -p "$ERRORS_DIR"
cat > "$ERRORS_DIR/503.http" << 'EOF'
HTTP/1.0 503 Service Unavailable
Cache-Control: no-cache
Connection: close
Content-Type: text/html

<!DOCTYPE html>
<html>
<head><title>Service Unavailable</title></head>
<body>
<h1>Service temporarily unavailable</h1>
<p>Our servers are currently undergoing maintenance. Please try again shortly.</p>
</body>
</html>
EOF

# VALIDATE CONFIG BEFORE RESTART 
echo "[deploy_haproxy.sh] Validating HAProxy configuration..."
haproxy -c -f "$HAPROXY_CFG"

# RSYSLOG → ELK 
cat > /etc/rsyslog.d/49-haproxy.conf << EOF
if \$programname == 'haproxy' then @${ELK}:514
& stop
EOF

# RSYNC CRON (Robust against set -e) 
CRON_JOB="*/5 * * * * rsync -avz --delete reda@${APACHE1}:/var/www/html/ /tmp/web_sync/ && rsync -avz --delete /tmp/web_sync/ reda@${APACHE2}:/var/www/html/"

# Extract current cron (ignore error if empty), filter out our job, and recreate
crontab -l 2>/dev/null | grep -v "web_sync" > /tmp/current_cron || true
echo "$CRON_JOB" >> /tmp/current_cron
crontab /tmp/current_cron
rm /tmp/current_cron

# ENABLE AND RESTART SERVICES
systemctl restart rsyslog
systemctl restart haproxy

echo "[deploy_haproxy.sh] Deployment complete."
echo ""
systemctl status haproxy --no-pager | grep "Active:"
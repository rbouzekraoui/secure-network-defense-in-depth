#!/bin/bash
# EC2 user data for sndid-db, in the private subnet without a public IP.
# Needs outbound access to the Ubuntu archive. Without a NAT Gateway (ADR-003), the script stops at apt-get.
# Replace DB_PASSWORD before launch and never commit the real value.

set -euo pipefail

DB_NAME="appdb"
DB_USER="appuser"
DB_PASSWORD="REPLACE_WITH_STRONG_PASSWORD"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y mysql-server

# Private IP from the instance metadata service (IMDSv2).
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

# Listen on the private interface only, never on 0.0.0.0.
sed -i "s/^bind-address.*/bind-address = ${PRIVATE_IP}/" /etc/mysql/mysql.conf.d/mysqld.cnf
sed -i "s/^mysqlx-bind-address.*/mysqlx-bind-address = ${PRIVATE_IP}/" \
  /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true

systemctl enable mysql
systemctl restart mysql

# Same cleanup as mysql_secure_installation, without prompts.
mysql -u root << SQL
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

# Application database and user. Host '%' relies on sndid-sg-db (TCP 3306 from sndid-sg-web only).
mysql -u root << SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

hostnamectl set-hostname sndid-db

echo "[user-data] MySQL ready — bound to ${PRIVATE_IP}:3306, database ${DB_NAME} created."

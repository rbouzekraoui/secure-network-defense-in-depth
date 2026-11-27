#!/bin/bash
# EC2 user data for sndid-apache-1 (eu-west-3a) and sndid-apache-2 (eu-west-3b).
# Set NODE_NAME to "Apache-1" or "Apache-2" before launch.

NODE_NAME="Apache-1"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apache2

# Page that names the node, so the ALB distribution is visible.
echo "<h1>${NODE_NAME} — AWS $(hostname -f)</h1>" > /var/www/html/index.html

# Hide the Apache version, as on the local web servers (T-12).
sed -i 's/^ServerTokens.*/ServerTokens Prod/'     /etc/apache2/conf-available/security.conf
sed -i 's/^ServerSignature.*/ServerSignature Off/' /etc/apache2/conf-available/security.conf

systemctl enable --now apache2
systemctl reload apache2

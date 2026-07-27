#!/bin/bash

set -euo pipefail

ELK_IP="192.168.30.10"

echo "[deploy_elk.sh] Starting ELK stack deployment..."

# KERNEL PARAMETER (required by Elasticsearch)
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-elasticsearch.conf

# ELASTIC REPOSITORY (idempotent)
if [ ! -f /usr/share/keyrings/elasticsearch-keyring.gpg ]; then
  wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
    | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
fi

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list

apt-get update
apt-get install -y elasticsearch logstash kibana

# ELASTICSEARCH CONFIGURATION
cat > /etc/elasticsearch/elasticsearch.yml << EOF
cluster.name: siem-monosite
node.name: elk-node-1
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: ${ELK_IP}
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
EOF

mkdir -p /etc/elasticsearch/jvm.options.d
cat > /etc/elasticsearch/jvm.options.d/heap.options << EOF
-Xms2g
-Xmx2g
EOF

# LOGSTASH PIPELINE
cat > /etc/logstash/conf.d/siem-pipeline.conf << 'PIPELINE'
input {
  udp {
    port => 514
    type => "syslog"
  }
}

filter {
  if [message] =~ /FW-BLOCK/ {
    grok {
      match => { "message" => "%{GREEDYDATA:fw_prefix}\[FW-BLOCK\]%{GREEDYDATA:fw_details} SRC=%{IP:src_ip} DST=%{IP:dst_ip}%{GREEDYDATA} PROTO=%{WORD:protocol}(?:%{GREEDYDATA} DPT=%{INT:dst_port})?" }
      add_tag => [ "firewall_block" ]
    }
  }

  if [message] =~ /sshd/ {
    grok {
      match => { "message" => "%{GREEDYDATA:ssh_msg} (?:Failed|Accepted) %{WORD:auth_method} for %{USERNAME:ssh_user} from %{IP:ssh_src_ip}" }
      add_tag => [ "ssh_auth" ]
    }
    if [message] =~ /Failed password/ {
      mutate { add_tag => [ "ssh_failed" ] }
    }
  }

  if [program] == "haproxy" {
    grok {
      match => { "message" => "%{IP:client_ip}:%{INT:client_port} \[%{HTTPDATE:haproxy_time}\] %{NOTSPACE:frontend} %{NOTSPACE:backend}/%{NOTSPACE:server} %{GREEDYDATA} %{INT:http_status}" }
      add_tag => [ "haproxy_access" ]
    }
  }

  if [src_ip] {
    geoip {
      source => "src_ip"
      target => "geoip"
    }
  }
}

output {
  elasticsearch {
    hosts => ["http://192.168.30.10:9200"]
    index => "siem-%{+YYYY.MM.dd}"
  }
}
PIPELINE

# LOGSTASH PRIVILEGED PORT BINDING (CAP_NET_BIND_SERVICE)
# Logstash runs as a non-privileged user and cannot bind syslog port UDP/514 (< 1024) by default. Rather than running the service as root, grant the specific network capability via a systemd override — least-privilege approach.
mkdir -p /etc/systemd/system/logstash.service.d
cat > /etc/systemd/system/logstash.service.d/override.conf << EOF
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
EOF

# KIBANA CONFIGURATION
cat > /etc/kibana/kibana.yml << EOF
server.port: 5601
server.host: "${ELK_IP}"
server.name: "kibana-siem"
elasticsearch.hosts: ["http://${ELK_IP}:9200"]
EOF

# ENABLE AND START SERVICES
systemctl daemon-reload
systemctl enable elasticsearch logstash kibana
systemctl restart elasticsearch
sleep 30   
systemctl restart logstash kibana

# ILM RETENTION POLICY (30 days)
sleep 20
curl -X PUT "http://${ELK_IP}:9200/_ilm/policy/siem-retention" \
  -H 'Content-Type: application/json' -d'
{
  "policy": {
    "phases": {
      "hot":    { "actions": {} },
      "delete": { "min_age": "30d", "actions": { "delete": {} } }
    }
  }
}'

echo ""
echo "[deploy_elk.sh] Deployment complete."
echo "[deploy_elk.sh] Kibana: http://${ELK_IP}:5601 (allow 1-2 min to start)"
echo "[deploy_elk.sh] Access Kibana via SSH tunnel through the router bastion:"
echo "[deploy_elk.sh]   ssh -L 5601:${ELK_IP}:5601 reda@<router-wan-ip>"
# 開発環境用 Edge Gateway VMのサービスアカウント
resource "google_service_account" "edge_sa" {
  account_id   = "edge-gateway-sa"
  display_name = "Edge Gateway VM Service Account"
}

# Edge Gateway VM
resource "google_compute_instance" "edge_gateway" {
  name         = "edge-gateway"
  machine_type = "e2-micro"
  zone         = var.zone

  can_ip_forward = true
  allow_stopping_for_update = true

  tags = ["http-server", "https-server"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.subnet_main.id
    access_config {
      // Ephemeral external IP
    }
  }

  service_account {
    email  = google_service_account.edge_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    "startup-script" = <<-EOT
    #!/bin/bash
    sudo apt-get update && sudo apt-get install -y caddy jq iptables-persistent netfilter-persistent

    # 1. IPマスカレード（NAT）の有効化
    sudo sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
    sudo iptables -t nat -A POSTROUTING -o ens4 -j MASQUERADE
    sudo netfilter-persistent save

    # 2. Caddyの設定追従用スクリプト作成
    cat <<'EOF' > /usr/local/bin/sync-gke-nodes.sh
    #!/bin/bash
    IPS=$(gcloud compute instances list --filter="name~'^gke-${var.cluster_name}-'" --format="value(networkInterfaces[0].networkIP)")
    
    CADDYFILE_NEW=":80 {\n$(for ip in $IPS; do echo "    reverse_proxy $ip:30080"; done)\n}\n:443 {\n$(for ip in $IPS; do echo "    reverse_proxy $ip:30443"; done)\n}"
    
    if [ "$CADDYFILE_NEW" != "$(cat /etc/caddy/Caddyfile 2>/dev/null)" ]; then
        echo -e "$CADDYFILE_NEW" > /etc/caddy/Caddyfile
        systemctl reload caddy
    fi
    EOF
    chmod +x /usr/local/bin/sync-gke-nodes.sh
    /usr/local/bin/sync-gke-nodes.sh
    echo "* * * * * root /usr/local/bin/sync-gke-nodes.sh" > /etc/cron.d/sync-gke-nodes

    # 3. Cloudflare DNS更新スクリプト
    cat <<'SCRIPT' > /usr/local/bin/sync-cloudflare-dns.sh
    #!/bin/bash
    set -euo pipefail
    
    CF_API_TOKEN=$(gcloud secrets versions access latest --secret="cloudflare-api-token" 2>/dev/null | tr -d '\n\r') || exit 0
    CF_ZONE_ID=$(gcloud secrets versions access latest --secret="cloudflare-zone-id" 2>/dev/null | tr -d '\n\r') || exit 0
    CF_API="https://api.cloudflare.com/client/v4"
    
    EDGE_IP=$(curl -sf http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google") || true
    PROD_IP="${google_compute_global_address.prod_static_ip.address}"
    
    update_dns() {
      local host=$1 ip=$2 proxied=$3
      [ -z "$ip" ] && return 0
      local record rid cur
      record=$(curl -sf "$${CF_API}/zones/$${CF_ZONE_ID}/dns_records?name=$${host}&type=A" -H "Authorization: Bearer $${CF_API_TOKEN}")
      rid=$(echo "$record" | jq -r '.result[0].id // empty')
      cur=$(echo "$record" | jq -r '.result[0].content // empty')
      [ "$cur" = "$ip" ] && return 0
      
      if [ -z "$rid" ]; then
        curl -sf -X POST "$${CF_API}/zones/$${CF_ZONE_ID}/dns_records" \
          -H "Authorization: Bearer $${CF_API_TOKEN}" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"A\",\"name\":\"$${host}\",\"content\":\"$${ip}\",\"proxied\":$${proxied},\"ttl\":1}" > /dev/null
      else
        curl -sf -X PUT "$${CF_API}/zones/$${CF_ZONE_ID}/dns_records/$${rid}" \
          -H "Authorization: Bearer $${CF_API_TOKEN}" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"A\",\"name\":\"$${host}\",\"content\":\"$${ip}\",\"proxied\":$${proxied},\"ttl\":1}" > /dev/null
      fi
    }
    
    update_dns "dev.wax100.io"  "$EDGE_IP" false
    update_dns "stag.wax100.io" "$EDGE_IP" false
    update_dns "wax100.io"      "$PROD_IP" true
    update_dns "www.wax100.io"  "$PROD_IP" true
    SCRIPT
    chmod +x /usr/local/bin/sync-cloudflare-dns.sh
    echo "*/5 * * * * root /usr/local/bin/sync-cloudflare-dns.sh >> /var/log/cloudflare-dns-sync.log 2>&1" > /etc/cron.d/sync-cloudflare-dns
  EOT
  }

  lifecycle {
    ignore_changes = [
      boot_disk[0].initialize_params
    ]
  }
}

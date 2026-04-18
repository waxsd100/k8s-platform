# 1. Edge Gateway 用サービスアカウント
# 開発環境用 Edge Gateway VMのサービスアカウント
resource "google_service_account" "edge_sa" {
  account_id   = "edge-gateway-sa"
  display_name = "Edge Gateway VM Service Account"
}

# 2. Edge Gateway VM 本体
# Edge Gateway VM
resource "google_compute_instance" "edge_gateway" {
  name         = "edge-gateway"
  machine_type = "e2-micro"
  zone         = var.zone

  can_ip_forward            = true
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
    set -euo pipefail

    # 0. Caddyのインストールとユーザー作成
    apt-get update && apt-get install -y caddy jq iptables-persistent netfilter-persistent
    id caddy &>/dev/null || useradd -r -s /usr/sbin/nologin -d /var/lib/caddy caddy
    mkdir -p /var/lib/caddy /var/log/caddy /run/caddy /etc/caddy/certs
    chown caddy:caddy /var/lib/caddy /var/log/caddy /run/caddy /etc/caddy/certs

    # 1. IPマスカレード（NAT）の有効化
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" | tee -a /etc/sysctl.conf
    iptables -t nat -A POSTROUTING -o ens4 -j MASQUERADE
    netfilter-persistent save

    # 2. Cloudflare Origin証明書の配置（Edge VMでTLS終端するため）
    gcloud secrets versions access latest --secret="cloudflare-origin-cert" 2>/dev/null > /etc/caddy/certs/origin.crt || true
    gcloud secrets versions access latest --secret="cloudflare-origin-key" 2>/dev/null > /etc/caddy/certs/origin.key || true
    chown caddy:caddy /etc/caddy/certs/*

    # 3. GKEノード追従用Caddyfile生成スクリプト
    # Edge VMが全環境のHTTP/HTTPS入口（TLS終端）を担う
    cat <<'EOF' > /usr/local/bin/sync-gke-nodes.sh
    #!/bin/bash
    IPS=$(gcloud compute instances list --filter="name~'^gke-${var.cluster_name}-'" --format="value(networkInterfaces[0].networkIP)" 2>/dev/null)
    [ -z "$IPS" ] && exit 0

    UPSTREAM=""
    for ip in $IPS; do
        UPSTREAM="$UPSTREAM $ip:30080"
    done

    CADDYFILE=":80 {
    reverse_proxy$UPSTREAM {
        header_up X-Forwarded-Proto https
    }
}
:443 {
    tls /etc/caddy/certs/origin.crt /etc/caddy/certs/origin.key
    reverse_proxy$UPSTREAM {
        header_up X-Forwarded-Proto https
    }
}"

    CURRENT=$(cat /etc/caddy/Caddyfile 2>/dev/null || true)
    if [ "$CADDYFILE" != "$CURRENT" ]; then
        echo "$CADDYFILE" > /etc/caddy/Caddyfile
        systemctl reload caddy 2>/dev/null || systemctl restart caddy
    fi
    EOF
    chmod +x /usr/local/bin/sync-gke-nodes.sh
    /usr/local/bin/sync-gke-nodes.sh
    systemctl enable --now caddy
    echo "* * * * * root /usr/local/bin/sync-gke-nodes.sh" > /etc/cron.d/sync-gke-nodes

    # 4. Cloudflare DNS更新スクリプト
    # 全環境(dev/stag/prod)をEdge VM経由に統一
    cat <<'SCRIPT' > /usr/local/bin/sync-cloudflare-dns.sh
    #!/bin/bash
    set -euo pipefail
    
    CF_API_TOKEN=$(gcloud secrets versions access latest --secret="cloudflare-api-token" 2>/dev/null | tr -d '\n\r') || exit 0
    CF_ZONE_ID=$(gcloud secrets versions access latest --secret="cloudflare-zone-id" 2>/dev/null | tr -d '\n\r') || exit 0
    CF_API="https://api.cloudflare.com/client/v4"
    
    EDGE_IP=$(curl -sf http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google") || true
    [ -z "$EDGE_IP" ] && exit 0

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
    
    # Dev/StagのみEdge VM経由（ProdはGCP LB経由のため除外）
    update_dns "dev.wax100.io"  "$EDGE_IP" true
    update_dns "stag.wax100.io" "$EDGE_IP" true
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

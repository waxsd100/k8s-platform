# 1. VPC ネットワーク本体
resource "google_compute_network" "vpc_network" {
  name                     = var.vpc_name
  auto_create_subnetworks  = false
  enable_ula_internal_ipv6 = true
  depends_on               = [google_project_service.enabled_apis]
}

# 2. サブネット群
# メインサブネット
resource "google_compute_subnetwork" "subnet_main" {
  name                     = var.subnet_main_name
  region                   = var.region
  network                  = google_compute_network.vpc_network.id
  ip_cidr_range            = var.subnet_main_cidr
  private_ip_google_access = true

  lifecycle {
    ignore_changes = [ipv6_access_type]
  }
}

# ロードバランサ用サブネット
resource "google_compute_subnetwork" "subnet_lb" {
  name          = var.subnet_lb_name
  region        = var.region
  network       = google_compute_network.vpc_network.id
  ip_cidr_range = var.subnet_lb_cidr

  lifecycle {
    ignore_changes = [role]
  }
}

# 3. ファイアウォールルール
# ファイアウォールルール (HTTP)
resource "google_compute_firewall" "vpc_allow_http" {
  name    = "wax100-vpc-allow-http"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"]
}

# ファイアウォールルール (HTTPS)
resource "google_compute_firewall" "vpc_allow_https" {
  name    = "wax100-vpc-allow-https"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["https-server"]
}

# 内部ヘルスチェック用
resource "google_compute_firewall" "vpc_allow_health_checks" {
  name    = "wax100-vpc-allow-health-check"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22", "209.85.152.0/22", "209.85.204.0/22"]
  target_tags   = ["lb-health-check"]
}

# IAP (Identity-Aware Proxy) 用セキュアSSH (既存ルールの上書き)
resource "google_compute_firewall" "vpc_allow_ssh" {
  name        = "wax100-allow-ssh"
  network     = google_compute_network.vpc_network.name
  description = "任意の送信元からネットワーク上の任意のインスタンスへのポート 22 を使用した TCP 接続を許可します。"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
}

# 内部ネットワーク通信（VPC内）の許可
resource "google_compute_firewall" "vpc_allow_internal" {
  name        = "wax100-vpc-allow-internal"
  network     = google_compute_network.vpc_network.name
  description = "VPC内のすべての内部トラフィックを許可"

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/8"]
}

# Webhook用ファイアウォール (Private GKE用)
# Kyverno等のAdmission WebhookはGKEマスターノードからワーカーノードへのコールバックを必要とする。
# Private GKEクラスターではマスターのCIDR(master_ipv4_cidr_block)からのアクセスが
# デフォルトでは443のみ許可されるが、8443/9443等のカスタムポートは明示的に開放が必要。
resource "google_compute_firewall" "vpc_allow_webhooks" {
  name        = "wax100-vpc-allow-webhooks"
  network     = google_compute_network.vpc_network.name
  description = "GKEマスターからワーカーへのWebhook通信を許可（Private Cluster用）"

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "9443"]
  }

  # GKEマスターノードのCIDR。gke.tf と同じ変数を参照し、片方だけ変わる事故を防ぐ
  source_ranges = [var.master_ipv4_cidr_block]
}

# 4. Cloud Router と Cloud NAT
# Cloud Router
resource "google_compute_router" "router" {
  name    = "${var.project_id}-router"
  region  = var.region
  network = google_compute_network.vpc_network.id
}

# Cloud NAT (Prodなどのデフォルト出口)
resource "google_compute_router_nat" "nat" {
  name                               = "${var.project_id}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# =============================================================================
# VPC
# =============================================================================
resource "google_compute_network" "vpc_network" {
  name                     = var.vpc_name
  auto_create_subnetworks  = false
  enable_ula_internal_ipv6 = true
  depends_on               = [google_project_service.enabled_apis]
}

# ノード用サブネット（Pod / Service は GKE が作る secondary range）
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

# =============================================================================
# ファイアウォール
# =============================================================================
# NOTE: 以前ここにあった HTTP / HTTPS / LB ヘルスチェック用のルールと LB 用サブネットは、
#       外部 LB を使っていた頃の名残で削除した。今は外部 IP も LB も持たず、
#       入口は Cloudflare Tunnel（クラスタから外向きに張る接続）だけ。

# IAP (Identity-Aware Proxy) 経由の SSH。送信元は IAP の TCP 転送レンジだけ。
# ノードに入るには IAP の権限 (roles/iap.tunnelResourceAccessor) も別途必要。
resource "google_compute_firewall" "vpc_allow_ssh" {
  name        = "wax100-allow-ssh"
  network     = google_compute_network.vpc_network.name
  description = "IAP TCP 転送 (35.235.240.0/20) からの SSH のみ許可"

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

# =============================================================================
# Cloud Router / Cloud NAT（private ノードの外向き通信）
# =============================================================================
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

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

# 内部ネットワーク通信の許可。送信元はノードのサブネット（var.subnet_main_cidr）と Pod の範囲（var.pods_cidr）だけ。
# 以前は 10.0.0.0/8 全体だった。/8 にはこのクラスタ以外の範囲（他 VPC や
# 後からピアリングする先など）も含まれてしまうため、狭めている。
# Service の IP はパケットの送信元にならないので含めない。
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

  source_ranges = [var.subnet_main_cidr, var.pods_cidr]
}

# Webhook用ファイアウォール (Private GKE用)
# Kyverno (9443) / KubeVela (9443) / Config Sync (admission-webhook: 8676) 等の Admission Webhook は
# GKE マスターノードからワーカーノードへのコールバックを必要とする。
# Private GKE クラスターではマスターの CIDR (master_ipv4_cidr_block) からのアクセスが
# デフォルトでは 443/10250 のみ許可されるため、8443/8676/9443/10260 等のカスタムポートは明示的に開放する。
# 注: 10260 を待ち受けるコンポーネントは本リポジトリにない（全体を grep して確認）。リポジトリ外で使われていなければ削除してよい。
resource "google_compute_firewall" "vpc_allow_webhooks" {
  name        = "wax100-vpc-allow-webhooks"
  network     = google_compute_network.vpc_network.name
  description = "GKEマスターからワーカーへのWebhook通信を許可（Private Cluster用）"

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "8676", "9443", "10260"]
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

  # 動的ポート割り当てで、単一ノードからの大量アウトバウンド（イメージ取得・バックアップ等）時の
  # 既定 64 ポート枯渇による NAT ドロップを防ぐ。
  enable_dynamic_port_allocation = true
  min_ports_per_vm               = 64
  max_ports_per_vm               = 4096
}

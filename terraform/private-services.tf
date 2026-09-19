# =============================================================================
# Private Services Access (Cloud SQL ⇔ VPC のプライベート接続)
#
# Cloud SQL インスタンス本体は canine.tf 側で定義する。
# ここはインスタンスをまたいで共有されるネットワーク側の土台のみを置く。
# =============================================================================

# Cloud SQL とのプライベート接続に使用する予約済み IP アドレスレンジ
resource "google_compute_global_address" "private_ip_range" {
  name          = "cloudsql-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc_network.id
}

# VPC ピアリング接続（Cloud SQL ⇔ VPC）
resource "google_service_networking_connection" "private_vpc_connection" {
  network = google_compute_network.vpc_network.id
  service = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [
    google_compute_global_address.private_ip_range.name
  ]

  depends_on = [google_project_service.enabled_apis]
}

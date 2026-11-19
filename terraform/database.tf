# =============================================================================
# Canine 用の Cloud SQL for PostgreSQL インスタンス
#
# インスタンス名はプロジェクト名ベースで維持している（wax100-db）が、用途は Canine
# 専用（canine.tf の canine_production / canine）。一般アプリは Kyverno の
# NetworkPolicy と Cloud SQL Auth Proxy の SSL 強制によりこのインスタンスへ接続できない。
#
# NOTE: 負荷が増えたら var.db_tier を上げる（変更時は再起動が入る）。
#
# ネットワークは private-services.tf の Private Services Access（VPC ピアリング）を使う。
# =============================================================================

resource "google_sql_database_instance" "main" {
  name             = var.db_instance_name
  database_version = "POSTGRES_16"
  region           = var.region

  # NOTE: 誤削除防止。削除時は先に両方 false にして apply する
  #   deletion_protection         : terraform destroy を止める
  #   deletion_protection_enabled : コンソールや gcloud からの削除を止める
  deletion_protection = true

  settings {
    deletion_protection_enabled = true

    tier                  = var.db_tier
    edition               = "ENTERPRISE"
    availability_type     = "ZONAL" # シングルゾーン（コスト最適化）
    disk_type             = "PD_SSD"
    disk_size             = 10
    disk_autoresize       = true
    disk_autoresize_limit = 50

    # db-f1-micro（614 MiB RAM）の既定値（25、管理予約を除くと実効約 20）では Canine の
    # web + worker（GoodJob）のローリング更新時に接続数が枯渇しやすいため引き上げる。
    # 50 だと 614 MiB RAM で OOM リスクが上がるため、ピーク約 20 接続＋メンテ余力を安全に賄える 35 に設定。
    # 注意: この flag を変えると Cloud SQL インスタンスが再起動する。apply は利用の少ない時間帯に行う。
    database_flags {
      name  = "max_connections"
      value = "35"
    }

    # プライベート IP のみ（パブリック IP 無効）
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc_network.id
      allocated_ip_range                            = google_compute_global_address.private_ip_range.name
      enable_private_path_for_google_cloud_services = true
      # Cloud SQL Auth Proxy（IAM の cloudsql.client で発行される一時的なクライアント証明書）を
      # 通した接続だけを受ける。パスワードを知っていても、VPC 内から 5432 に直接つなぐことはできない。
      # アプリの Pod からの経路は Kyverno の NetworkPolicy（environment-isolation）でも遮断しているが、
      # そちらが外れても DB 側で止まるようにする。
      ssl_mode = "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true    # PostgreSQL は WAL ベースの PITR
      start_time                     = "17:00" # UTC 17:00 (JST 02:00)
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
      }
    }

    maintenance_window {
      day          = 7  # UTC 日曜日
      hour         = 20 # UTC 日曜 20:00 = JST 月曜 05:00
      update_track = "stable"
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

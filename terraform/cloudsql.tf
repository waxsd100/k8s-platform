# =============================================================================
# Cloud SQL for MySQL — Production 用
# =============================================================================

# 1. プライベート IP 接続用の IP レンジ確保
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
  network                 = google_compute_network.vpc_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]

  depends_on = [google_project_service.enabled_apis]
}

# 2. Cloud SQL インスタンス
resource "google_sql_database_instance" "blog_db" {
  name             = "wax100-blog-db"
  database_version = "MYSQL_8_0"
  region           = var.region

  # NOTE: 誤削除防止。インスタンス削除時は先にこのフラグをfalseにしてapplyする必要がある
  deletion_protection = true

  settings {
    tier              = "db-f1-micro"
    edition           = "ENTERPRISE"
    availability_type = "ZONAL" # シングルゾーン（コスト最適化）
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = true
    disk_autoresize_limit = 50 # コスト青天井防止のための上限設定

    # プライベート IP のみ（パブリック IP 無効）
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc_network.id
      enable_private_path_for_google_cloud_services = true
    }

    # バックアップ設定（1日1回、7日保持）
    backup_configuration {
      enabled                        = true
      binary_log_enabled             = true # ポイントインタイムリカバリ用
      start_time                     = "03:00" # UTC 03:00 (JST 12:00)
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
      }
    }

    # MySQL 設定
    database_flags {
      name  = "character_set_server"
      value = "utf8mb4"
    }
    database_flags {
      name  = "default_collation_server"
      value = "utf8mb4_unicode_ci"
    }

    # メンテナンスウィンドウ（日曜 JST 早朝）
    maintenance_window {
      day          = 7 # 日曜日
      hour         = 20 # UTC 20:00 = JST 05:00
      update_track = "stable"
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

# 3. データベース & ユーザー作成
resource "google_sql_database" "ghost" {
  name      = "ghost"
  instance  = google_sql_database_instance.blog_db.name
  charset   = "utf8mb4"
  collation = "utf8mb4_unicode_ci"
}

# Ghost 用 DB パスワード（自動生成）
resource "random_password" "db_password" {
  length  = 32
  special = false # Cloud SQL のパスワード制約に合わせて記号なし
}

resource "google_sql_user" "ghost" {
  name     = "ghost"
  instance = google_sql_database_instance.blog_db.name
  password = random_password.db_password.result
}

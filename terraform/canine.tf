# =============================================================================
# Canine (Kubernetes 向け PaaS コントロールプレーン) 用リソース
#
# - Cloud SQL for PostgreSQL (Canine は Rails + GoodJob で PostgreSQL 必須)
# - Secret Manager (DB パスワード / SECRET_KEY_BASE)
# - Workload Identity (KSA: canine/canine-sa -> GSA: canine-sa)
#
# ネットワーク(VPC ピアリング)は cloudsql.tf の
# google_service_networking_connection.private_vpc_connection を再利用する。
# =============================================================================

# 1. Cloud SQL インスタンス (PostgreSQL)
resource "google_sql_database_instance" "canine_db" {
  name             = "canine-db"
  database_version = "POSTGRES_16"
  region           = var.region

  # NOTE: 誤削除防止。削除時は先に false にして apply する
  deletion_protection = true

  settings {
    tier                  = var.canine_db_tier
    edition               = "ENTERPRISE"
    availability_type     = "ZONAL" # シングルゾーン（コスト最適化）
    disk_type             = "PD_SSD"
    disk_size             = 10
    disk_autoresize       = true
    disk_autoresize_limit = 50

    # プライベート IP のみ（パブリック IP 無効）
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc_network.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true    # PostgreSQL は WAL ベースの PITR
      start_time                     = "03:00" # UTC 03:00 (JST 12:00)
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
      }
    }

    maintenance_window {
      day          = 7  # 日曜日
      hour         = 20 # UTC 20:00 = JST 05:00
      update_track = "stable"
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

# 2. データベース & ユーザー
# NOTE: DB 名/ユーザー名は Canine の config/database.yml の production 設定
#       (database: canine_production / username: canine) に合わせる必要がある。
resource "google_sql_database" "canine" {
  name     = "canine_production"
  instance = google_sql_database_instance.canine_db.name
}

resource "random_password" "canine_db_password" {
  length  = 32
  special = false
}

resource "google_sql_user" "canine" {
  name     = "canine"
  instance = google_sql_database_instance.canine_db.name
  password = random_password.canine_db_password.result
}

# 3. Secret Manager
resource "google_secret_manager_secret" "canine_db_password" {
  secret_id = "canine-db-password"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "canine_db_password_version" {
  secret      = google_secret_manager_secret.canine_db_password.id
  secret_data = random_password.canine_db_password.result
}

# Rails の SECRET_KEY_BASE (openssl rand -hex 64 相当)
resource "random_id" "canine_secret_key_base" {
  byte_length = 64
}

resource "google_secret_manager_secret" "canine_secret_key_base" {
  secret_id = "canine-secret-key-base"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "canine_secret_key_base_version" {
  secret      = google_secret_manager_secret.canine_secret_key_base.id
  secret_data = random_id.canine_secret_key_base.hex
}

# 4. Canine 用 GSA と Workload Identity バインディング
resource "google_service_account" "canine_sa" {
  account_id   = "canine-sa"
  display_name = "Canine PaaS control plane"
}

# Cloud SQL Auth Proxy 用
resource "google_project_iam_member" "canine_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.canine_sa.email}"
}

# KSA (canine/canine-sa) から GSA を借用できるようにする
resource "google_service_account_iam_member" "canine_workload_identity" {
  service_account_id = google_service_account.canine_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[canine/canine-sa]"
}

# NOTE: ESO へのシークレット参照権限は secrets.tf の
#       google_project_iam_member.eso_secret_accessor (プロジェクトレベル) で
#       付与済みのため、ここでは個別付与しない。

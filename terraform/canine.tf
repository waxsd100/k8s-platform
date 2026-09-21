# =============================================================================
# Canine (Kubernetes 向け PaaS コントロールプレーン) 用リソース
#
# - 共有の Cloud SQL インスタンス (database.tf) の中の、Canine 用 DB とユーザー
#   （Canine は Rails + GoodJob で PostgreSQL 必須）
# - Secret Manager (DB パスワード / SECRET_KEY_BASE)
# - Workload Identity (KSA: canine/canine -> GSA: canine-sa)
#
# =============================================================================

# --- データベースとユーザー ---
# NOTE: DB 名/ユーザー名は Canine の config/database.yml の production 設定
#       (database: canine_production / username: canine) に合わせる必要がある。
resource "google_sql_database" "canine" {
  name     = "canine_production"
  instance = google_sql_database_instance.main.name
}

resource "random_password" "canine_db_password" {
  length  = 32
  special = false

  depends_on = [google_project_service.enabled_apis]
}

resource "google_sql_user" "canine" {
  name     = "canine"
  instance = google_sql_database_instance.main.name
  password = random_password.canine_db_password.result
}

# --- Secret Manager（Terraform が値を生成して書き込む） ---
resource "google_secret_manager_secret" "canine_db_password" {
  secret_id = "canine-db-password"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_secret_manager_secret_version" "canine_db_password_version" {
  secret      = google_secret_manager_secret.canine_db_password.id
  secret_data = random_password.canine_db_password.result
}

# Rails の SECRET_KEY_BASE (openssl rand -hex 64 相当)
resource "random_id" "canine_secret_key_base" {
  byte_length = 64

  depends_on = [google_project_service.enabled_apis]
}

resource "google_secret_manager_secret" "canine_secret_key_base" {
  secret_id = "canine-secret-key-base"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_secret_manager_secret_version" "canine_secret_key_base_version" {
  secret      = google_secret_manager_secret.canine_secret_key_base.id
  secret_data = random_id.canine_secret_key_base.hex
}

# --- Canine 用 GSA と Workload Identity ---
resource "google_service_account" "canine_sa" {
  account_id   = "canine-sa"
  display_name = "Canine PaaS control plane"

  depends_on = [google_project_service.enabled_apis]
}

# Cloud SQL Auth Proxy 用
resource "google_project_iam_member" "canine_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.canine_sa.email}"
}

# KSA から GSA を借用できるようにする。
# NOTE: KSA 名は Helm チャートの fullname（= リリース名 "canine"）であって
#       "canine-sa" ではない。ここを間違えると Cloud SQL Auth Proxy が
#       "failed to get credentials" で起動しない。
resource "google_service_account_iam_member" "canine_workload_identity" {
  service_account_id = google_service_account.canine_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[canine/canine]"
}

# NOTE: ESO へのシークレット参照権限は secrets.tf の
#       google_project_iam_member.eso_secret_accessor (プロジェクトレベル) で
#       付与済みのため、ここでは個別付与しない。

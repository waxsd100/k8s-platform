# =============================================================================
# 本番アプリ用の Cloud SQL for MySQL（MySQL しか使えないアプリ向け。例: Ghost）
#
# PostgreSQL で済むアプリは wax100-db（database.tf / app-databases.tf）を使う。
# ここは MySQL が必須のアプリだけのためのインスタンスで、var.mysql_app_databases が
# 空なら作らない（固定費を持たない）。
#
# 使い方:
#   1. var.mysql_app_databases にアプリ名（= dev の Namespace 名）を足して apply
#      → インスタンス（初回のみ）、DB <app>_production、ユーザー <app>、
#        Secret Manager の prod-<app>-mysql ができる
#   2. dev の Namespace に wax100.io/prod-db=mysql のラベルを付ける
#      → 昇格ジョブが prod-<app>-mysql をアプリの環境変数に足し、dev の MySQL を持ち込まない
#
# prod-<app>-mysql の中身は Ghost の設定と同じ形の環境変数（database__client ほか）。
# Ghost は nconf で `__` 区切りの環境変数を設定として読む。
#
# NOTE: Cloud SQL の API で作った MySQL ユーザーは、同じインスタンスの他の DB にも
#       権限を持つ（FILE と SUPER 以外のすべて）。アプリ同士を分けたいときは
#       インスタンスを分けるか、ユーザーの権限を手で絞る。
# NOTE: 名前を全部消すとインスタンスも消える。deletion_protection = true なので
#       apply はそこで止まる。本当に消すときは先に false にして apply する。
# =============================================================================

locals {
  mysql_app_db  = { for app in var.mysql_app_databases : app => replace(app, "-", "_") }
  mysql_enabled = length(var.mysql_app_databases) > 0
}

resource "google_sql_database_instance" "mysql" {
  count = local.mysql_enabled ? 1 : 0

  name             = var.mysql_instance_name
  database_version = var.mysql_version
  region           = var.region

  # NOTE: 誤削除防止。削除時は先に false にして apply する
  deletion_protection = true

  settings {
    tier                  = var.mysql_tier
    edition               = "ENTERPRISE"
    availability_type     = "ZONAL" # シングルゾーン（コスト最適化）
    disk_type             = "PD_SSD"
    disk_size             = 10
    disk_autoresize       = true
    disk_autoresize_limit = 50

    # プライベート IP のみ。暗号化していない接続は受け付けない
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc_network.id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      binary_log_enabled             = true    # MySQL の PITR はバイナリログが要る
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

resource "google_sql_database" "mysql_app" {
  for_each = local.mysql_app_db

  name      = "${each.value}_production"
  instance  = google_sql_database_instance.mysql[0].name
  charset   = "utf8mb4" # Ghost は utf8mb4 で接続する
  collation = "utf8mb4_0900_ai_ci"
}

resource "random_password" "mysql_app" {
  for_each = local.mysql_app_db

  length  = 32
  special = false
}

resource "google_sql_user" "mysql_app" {
  for_each = local.mysql_app_db

  name     = each.value
  host     = "%" # 接続元は Pod（IP は決まらない）。経路は private IP だけ
  instance = google_sql_database_instance.mysql[0].name
  password = random_password.mysql_app[each.key].result
}

resource "google_secret_manager_secret" "mysql_app" {
  for_each = local.mysql_app_db

  # 昇格ジョブ (promote.rb) が参照する ID。名前を変えるときは promote.rb も合わせる
  secret_id = "prod-${each.key}-mysql"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_secret_manager_secret_version" "mysql_app" {
  for_each = local.mysql_app_db

  secret = google_secret_manager_secret.mysql_app[each.key].id
  # キーがそのまま環境変数名になる（ExternalSecret の dataFrom.extract）
  secret_data = jsonencode({
    "database__client"               = "mysql"
    "database__connection__host"     = google_sql_database_instance.mysql[0].private_ip_address
    "database__connection__port"     = "3306"
    "database__connection__user"     = google_sql_user.mysql_app[each.key].name
    "database__connection__password" = random_password.mysql_app[each.key].result
    "database__connection__database" = google_sql_database.mysql_app[each.key].name
    # ssl_mode = ENCRYPTED_ONLY なので TLS が要る。サーバー証明書の検証はしない
    # （PostgreSQL 側の sslmode=require と同じ扱い。経路は VPC 内の private IP）
    "database__connection__ssl__rejectUnauthorized" = "false"
  })
}

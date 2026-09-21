# =============================================================================
# 本番アプリ用の DB（共有インスタンス wax100-db の中）
#
# 本番に昇格したアプリの DB は、クラスタ内の PostgreSQL（Canine のアドオン =
# bitnami/postgresql、Spot ノード上の PVC、バックアップ無し）ではなく
# Cloud SQL の wax100-db に置く。バックアップと PITR の対象になり、Spot の回収にも影響されない。
# dev は Canine のアドオンのまま（dev のデータは本番に持ち込まない）。
#
# 使い方:
#   1. var.app_databases にアプリ名（= dev の Namespace 名）を足して apply
#      → DB <app>_production、ユーザー <app>、Secret Manager の prod-<app>-database-url ができる
#   2. dev の Namespace に wax100.io/prod-db=true のラベルを付ける
#      → 昇格ジョブが本番の DATABASE_URL をこの Secret から渡し、dev の PostgreSQL を持ち込まない
#
# 接続は private IP に直接（Pod から VPC ピアリング経由で届く）。sslmode=require で暗号化する。
# NOTE: ここから名前を消すと DB とユーザーが消える（データも消える）。
#       消す前に gcloud sql export でバックアップを取ること。
# =============================================================================

locals {
  # PostgreSQL の識別子にハイフンは使いにくいので、アンダースコアに置き換える
  app_db = { for app in var.app_databases : app => replace(app, "-", "_") }
}

resource "google_sql_database" "app" {
  for_each = local.app_db

  name     = "${each.value}_production"
  instance = google_sql_database_instance.main.name
}

resource "random_password" "app_db" {
  for_each = local.app_db

  length  = 32
  special = false # URL にそのまま入れるため英数字だけにする
}

resource "google_sql_user" "app" {
  for_each = local.app_db

  name     = each.value
  instance = google_sql_database_instance.main.name
  password = random_password.app_db[each.key].result
}

resource "google_secret_manager_secret" "app_database_url" {
  for_each = local.app_db

  # 昇格ジョブ (promote.rb) が参照する ID。名前を変えるときは promote.rb も合わせる
  secret_id = "prod-${each.key}-database-url"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_secret_manager_secret_version" "app_database_url" {
  for_each = local.app_db

  secret = google_secret_manager_secret.app_database_url[each.key].id
  secret_data = format(
    "postgresql://%s:%s@%s:5432/%s?sslmode=require",
    google_sql_user.app[each.key].name,
    random_password.app_db[each.key].result,
    google_sql_database_instance.main.private_ip_address,
    google_sql_database.app[each.key].name,
  )
}

# 1. Cloudflare 関連シークレット
# ==== Cloudflare ====
resource "google_secret_manager_secret" "cloudflare_api_token" {
  secret_id = "cloudflare-api-token"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "cloudflare_zone_id" {
  secret_id = "cloudflare-zone-id"
  replication {
    auto {}
  }
}

# Edge VMにSecret Managerアクセス権を付与
resource "google_secret_manager_secret_iam_member" "edge_sa_secret_access" {
  # NOTE: "Invalid for_each argument" エラーを回避するため、toset([google_resource.id]) を避け、
  # APIの完了前に確定する「静的な文字列」をキーとしたMap型を利用してリソースIDを割り当てる。
  for_each = {
    cloudflare_api_token = google_secret_manager_secret.cloudflare_api_token.id,
    cloudflare_zone_id   = google_secret_manager_secret.cloudflare_zone_id.id
  }
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.edge_sa.email}"
}

# 2. アプリケーション共通シークレット
# ==== Dashboard / Apps ====
resource "google_secret_manager_secret" "dashboard_csrf_key" {
  secret_id = "dashboard-csrf-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "eso_secret_accessor" {
  # NOTE: 動的IDをキーにできないため静的文字列ベースのMapを使用
  for_each = {
    cloudflare_api_token = google_secret_manager_secret.cloudflare_api_token.id,
    cloudflare_zone_id   = google_secret_manager_secret.cloudflare_zone_id.id,
    dashboard_csrf_key   = google_secret_manager_secret.dashboard_csrf_key.id
  }
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.project_id}.svc.id.goog[infra/external-secrets]"
}

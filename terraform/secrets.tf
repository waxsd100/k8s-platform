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
  for_each = toset([
    google_secret_manager_secret.cloudflare_api_token.id,
    google_secret_manager_secret.cloudflare_zone_id.id
  ])
  secret_id = each.key
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.edge_sa.email}"
}

# ==== Dashboard / Apps ====
resource "google_secret_manager_secret" "dashboard_csrf_key" {
  secret_id = "dashboard-csrf-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "eso_secret_accessor" {
  for_each = toset([
    google_secret_manager_secret.cloudflare_api_token.id,
    google_secret_manager_secret.cloudflare_zone_id.id,
    google_secret_manager_secret.dashboard_csrf_key.id
  ])
  secret_id = each.key
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.project_id}.svc.id.goog[infra/external-secrets]"
}

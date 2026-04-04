# ==== Cloudflare ====
resource "google_secret_manager_secret" "cloudflare_api_token" {
  secret_id = "cloudflare-api-token"
  replication {
    auto {}
  }
}

# Edge VMにSecret Managerアクセス権を付与
resource "google_secret_manager_secret_iam_member" "edge_sa_secret_access" {
  secret_id = google_secret_manager_secret.cloudflare_api_token.id
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

# ESO (External Secrets Operator) 用の Workload Identity 秘密参照権限
resource "google_project_iam_member" "eso_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${var.project_id}.svc.id.goog[infra/external-secrets]"
}

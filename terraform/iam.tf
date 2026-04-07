# 1. 共通プロジェクトデータ
# コンピュートエンジンのデフォルトサービスアカウント
data "google_project" "project" {
}

locals {
  compute_sa_email = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# 2. デフォルトコンピュートアカウントの権限
# GKEノードに必要なデフォルト権限
resource "google_project_iam_member" "compute_sa_node_role" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${local.compute_sa_email}"
}

# GKEノードにArtifact Registryの読み取り権限
resource "google_project_iam_member" "compute_sa_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${local.compute_sa_email}"
}

# 3. Blog アプリケーション用サービスアカウント (Workload Identity)
# Cloud SQL Proxy が GCP 認証するためのサービスアカウント
resource "google_service_account" "blog_sa" {
  account_id   = "wax100-blog-sa"
  display_name = "wax100-blog Application Service Account"
}

# Cloud SQL Client ロール（Cloud SQL Proxy に必要）
resource "google_project_iam_member" "blog_sa_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.blog_sa.email}"

  # 最小権限の原則 (Least Privilege)
  # ブログ用のDBインスタンス以外には接続できないように境界を設定
  condition {
    title       = "limit-to-blog-db"
    description = "Allow connection only to wax100-db"
    expression  = "resource.name == \"projects/${var.project_id}/instances/wax100-db\" && resource.type == \"sqladmin.googleapis.com/Instance\""
  }
}

# Production の Workload Identity バインディング
# K8s SA (prod-wax100-blog/prod-wax100-blog-sa) → GCP SA (wax100-blog-sa)
resource "google_service_account_iam_member" "blog_wi_prod" {
  service_account_id = google_service_account.blog_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[prod-wax100-blog/prod-wax100-blog-sa]"
}

# GCS FUSE 用のストレージアクセス権限
resource "google_project_iam_member" "blog_sa_gcs_access" {
  project = var.project_id
  role    = "roles/storage.objectUser"
  member  = "serviceAccount:${google_service_account.blog_sa.email}"
}

# 4. Edge VM サービスアカウントの権限
# Secret Manager のアクセス（TLS証明書・Cloudflare API Token取得用）
resource "google_project_iam_member" "edge_sa_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.edge_sa.email}"
}

# GKEノード一覧取得の権限（Caddyの動的設定更新用）
resource "google_project_iam_member" "edge_sa_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.edge_sa.email}"
}

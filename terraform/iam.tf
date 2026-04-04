# コンピュートエンジンのデフォルトサービスアカウント
data "google_project" "project" {
}

locals {
  compute_sa_email = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

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

# =============================================================================
# Google Cloud API の有効化
# =============================================================================
# disable_on_destroy = false: destroy やリストからの削除で API を止めない
# （止めると同じ API を使う手作業のリソースまで巻き込むため）。
locals {
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "developerconnect.googleapis.com",
    "gkehub.googleapis.com",                 # Config Syncのために必要
    "anthosconfigmanagement.googleapis.com", # Config Syncのために必要
    "sqladmin.googleapis.com",               # Cloud SQL / Cloud SQL Auth Proxy に必要
    "servicenetworking.googleapis.com",      # Cloud SQL の Private Services Access に必要
    "iam.googleapis.com",                    # ServiceAccount の作成・IAM バインディングに必要
    "cloudresourcemanager.googleapis.com",   # data.google_project / プロジェクト IAM に必要
    "storage.googleapis.com"                 # Terraform state バケットに必要
  ]
}

resource "google_project_service" "enabled_apis" {
  for_each                   = toset(local.services)
  project                    = var.project_id
  service                    = each.key
  disable_dependent_services = false
  disable_on_destroy         = false
}

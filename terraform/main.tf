# 必要な Google Cloud API の有効化
locals {
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "anthos.googleapis.com",
    "cloudbuild.googleapis.com",
    "developerconnect.googleapis.com",
    "gkehub.googleapis.com",  # Config Syncのために必要
    "anthosconfigmanagement.googleapis.com" # Config Syncのために必要
  ]
}

resource "google_project_service" "enabled_apis" {
  for_each                   = toset(local.services)
  project                    = var.project_id
  service                    = each.key
  disable_dependent_services = false
  disable_on_destroy         = false
}

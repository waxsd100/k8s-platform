# 1. Config Sync 同期用 Artifact Registry
resource "google_artifact_registry_repository" "config_sync_repo" {
  location      = var.region
  repository_id = "config-sync-repo"
  description   = "OCI repository for Config Sync manifests"
  format        = "DOCKER"
}

# 2. Cloud Build 用サービスアカウント
resource "google_service_account" "cloudbuild_sa" {
  account_id   = "cloudbuild-sa"
  display_name = "Cloud Build Manifest Sync"
}

resource "google_project_iam_member" "cb_ar_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

resource "google_project_iam_member" "cb_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

resource "google_project_iam_member" "cb_dc_accessor" {
  project = var.project_id
  role    = "roles/developerconnect.readTokenAccessor"
  member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

resource "google_project_iam_member" "cb_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

# Cloud Build トリガー (Developer Connect は手動接続が前提のため、環境変数でリポジトリID等を外部注入するか、プレースホルダとします)
# resource "google_cloudbuild_trigger" "manifest_sync" {
#   name     = "manifest-sync"
#   location = var.region
#   service_account = google_service_account.cloudbuild_sa.id
#   ...
# }

# 3. Config Sync 用サービスアカウント
resource "google_service_account" "config_sync_sa" {
  account_id   = "config-sync-sa"
  display_name = "Config Sync Service Account"
}

resource "google_project_iam_member" "cs_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.config_sync_sa.email}"
}

resource "google_project_iam_member" "cs_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.config_sync_sa.email}"
}

# Workload Identity for Root Reconciler
resource "google_service_account_iam_member" "cs_wi_root_reconciler" {
  service_account_id = google_service_account.config_sync_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[config-management-system/root-reconciler]"
}

# Workload Identity for Otel Collector
resource "google_service_account_iam_member" "cs_wi_otel_collector" {
  service_account_id = google_service_account.config_sync_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[config-management-monitoring/otel-collector]"
}

# 4. GKE Fleet (Hub) & Config Management Feature の有効化
resource "google_gke_hub_membership" "membership" {
  membership_id = var.cluster_name
  location      = var.region
  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${google_container_cluster.primary.id}"
    }
  }
  authority {
    issuer = "https://container.googleapis.com/v1/${google_container_cluster.primary.id}"
  }
}

resource "google_gke_hub_feature" "configmanagement" {
  name     = "configmanagement"
  location = "global"

  fleet_default_member_config {
    configmanagement {
      version = "1.23.2"
      config_sync {
        enabled = true
      }
    }
  }
}

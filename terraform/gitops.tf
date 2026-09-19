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

# Cloud Build トリガー (Developer Connect / GitHub App 連携)
resource "google_cloudbuild_trigger" "manifest_sync" {
  name            = "manifest-sync"
  location        = var.region
  service_account = google_service_account.cloudbuild_sa.id

  repository_event_config {
    repository = "projects/${var.project_id}/locations/${var.region}/connections/${var.github_account_name}/repositories/${var.github_repo_platform}"
    push {
      branch = "^main$"
    }
  }

  filename = "cloudbuild.yaml"
  included_files = [
    "clusters/**",
    "components/**",
    "addons/**",
    "cloudbuild.yaml"
  ]
  ignored_files = [
    "**/_result.json"
  ]
}

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

# Workload Identity for Root Reconciler (Platform)
resource "google_service_account_iam_member" "cs_wi_root_reconciler_platform" {
  service_account_id = google_service_account.config_sync_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[config-management-system/root-reconciler-root-sync-platform]"
}

# Workload Identity for Root Reconciler (Dev)
resource "google_service_account_iam_member" "cs_wi_root_reconciler_dev" {
  service_account_id = google_service_account.config_sync_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[config-management-system/root-reconciler-root-sync-dev]"
}

# Workload Identity for Root Reconciler (Staging)
resource "google_service_account_iam_member" "cs_wi_root_reconciler_stag" {
  service_account_id = google_service_account.config_sync_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[config-management-system/root-reconciler-root-sync-stag]"
}

# Workload Identity for Root Reconciler (Production)
resource "google_service_account_iam_member" "cs_wi_root_reconciler_prod" {
  service_account_id = google_service_account.config_sync_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[config-management-system/root-reconciler-root-sync-prod]"
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

  # NOTE: クラスタ操作中の非同期ロック（Error code 9）によるMembership登録失敗を防ぐため、
  # すべてのNode Poolの展開完了を待機し、クラスタのロックが解除されてから登録するよう順序制御。
  depends_on = [
    google_container_node_pool.system_pool,
    google_container_node_pool.platform_pool,
    google_container_node_pool.apps_pool
  ]
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

resource "google_gke_hub_feature_membership" "configmanagement_membership" {
  location   = "global"
  feature    = google_gke_hub_feature.configmanagement.name
  membership = google_gke_hub_membership.membership.membership_id

  # NOTE: リージョナルクラスタの場合、デフォルトの "global" が読み込まれて404エラーになるのを防ぐため、
  # Membership本体のリージョン属性を明示的に指定して渡す。
  membership_location = google_gke_hub_membership.membership.location

  configmanagement {
    version = "1.23.2"

    config_sync {
      # NOTE: GCP Providerの厳格化によるエラーを回避するため、明示的に有効化フラグを定義する。
      enabled       = true
      source_format = "unstructured"
    }
  }

  depends_on = [
    google_gke_hub_feature.configmanagement
  ]
}

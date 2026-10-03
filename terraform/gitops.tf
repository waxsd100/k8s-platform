# =============================================================================
# Config Sync が pull する OCI リポジトリ
# =============================================================================
resource "google_artifact_registry_repository" "config_sync_repo" {
  location      = var.region
  repository_id = "config-sync-repo"
  description   = "OCI repository for Config Sync manifests"
  format        = "DOCKER"

  depends_on = [google_project_service.enabled_apis]
}

# =============================================================================
# Cloud Build（main への push でハイドレートして OCI に push）
# =============================================================================
resource "google_service_account" "cloudbuild_sa" {
  account_id   = "cloudbuild-sa"
  display_name = "Cloud Build Manifest Sync"

  depends_on = [google_project_service.enabled_apis]
}

# ハイドレート済みマニフェストを push する先だけに書き込める。
# プロジェクト全体に付けると、Canine が push したアプリのイメージも上書きできてしまう。
resource "google_artifact_registry_repository_iam_member" "cb_ar_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.config_sync_repo.location
  repository = google_artifact_registry_repository.config_sync_repo.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

resource "google_project_iam_member" "cb_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

# トリガーの参照先は Cloud Build の第 2 世代リポジトリ
# (projects/.../connections/<接続>/repositories/<リポジトリ>)。
# そのトークンを読む権限 cloudbuild.repositories.accessReadToken は
# roles/cloudbuild.readTokenAccessor に含まれる（IAM のロール一覧で確認）。
# 以前付けていた roles/developerconnect.readTokenAccessor は Developer Connect の
# gitRepositoryLinks 用で、この参照先には効かない。
resource "google_project_iam_member" "cb_repo_token_reader" {
  project = var.project_id
  role    = "roles/cloudbuild.readTokenAccessor"
  member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

# NOTE: roles/cloudbuild.builds.builder は付けない。このロールは全リポジトリへの
#       Artifact Registry 書き込みなどを含み、上のリポジトリ単位の制限を無意味にする。
#       このビルドに必要なのは公開イメージ (alpine/helm, crane) の取得、
#       config-sync-repo への push、ログの書き込み (cloudbuild.yaml は CLOUD_LOGGING_ONLY) だけ。

# Cloud Build トリガー (Cloud Build 第 2 世代リポジトリ / GitHub App 連携)
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

  depends_on = [google_project_service.enabled_apis]
}

# =============================================================================
# Config Sync の Google SA（Workload Identity）
# =============================================================================
resource "google_service_account" "config_sync_sa" {
  account_id   = "config-sync-sa"
  display_name = "Config Sync Service Account"

  depends_on = [google_project_service.enabled_apis]
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

# Workload Identity for Otel Collector
resource "google_service_account_iam_member" "cs_wi_otel_collector" {
  service_account_id = google_service_account.config_sync_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[config-management-monitoring/otel-collector]"
}

# =============================================================================
# Fleet 登録と Config Sync の有効化
# =============================================================================
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

# NOTE: 以前は fleet_default_member_config でも同じ設定を書いていたが、
#       このクラスタは下の feature_membership で個別に設定しており、そちらが優先される。
#       2 か所に書くと片方だけ更新する事故が起きるため、1 か所にまとめた。
resource "google_gke_hub_feature" "configmanagement" {
  name     = "configmanagement"
  location = "global"

  depends_on = [google_project_service.enabled_apis]
}

resource "google_gke_hub_feature_membership" "configmanagement_membership" {
  location   = "global"
  feature    = google_gke_hub_feature.configmanagement.name
  membership = google_gke_hub_membership.membership.membership_id

  # NOTE: リージョナルクラスタの場合、デフォルトの "global" が読み込まれて404エラーになるのを防ぐため、
  # Membership本体のリージョン属性を明示的に指定して渡す。
  membership_location = google_gke_hub_membership.membership.location

  configmanagement {
    # 最新は 1.25.0 (2026-08-24)。リリースノート:
    # https://docs.cloud.google.com/kubernetes-engine/config-sync/docs/release-notes
    version = "1.25.0"

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

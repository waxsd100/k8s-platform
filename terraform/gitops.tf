# =============================================================================
# Config Sync が pull する OCI リポジトリ
# =============================================================================
resource "google_artifact_registry_repository" "config_sync_repo" {
  location      = var.region
  repository_id = "config-sync-repo"
  description   = "OCI repository for Config Sync manifests"
  format        = "DOCKER"

  # 古いハイドレート済み OCI マニフェストの無制限蓄積を防ぐ。
  # "platform" タグと直近 10 世代は残し、それ以外で 30 日経過したものを削除する。
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-platform-tag"
    action = "KEEP"
    condition {
      tag_state    = "TAGGED"
      tag_prefixes = ["platform"]
    }
  }

  cleanup_policies {
    id     = "keep-recent-versions"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-old-manifests"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "2592000s"
    }
  }

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
# プロジェクト全体に付けると、アプリ用リポジトリなど他の Artifact Registry も上書きできてしまう。
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
# NOTE: included_files / ignored_files は設定しない。cloudbuild.yaml は origin/main の
#       HEAD (MAIN_SHA) と COMMIT_SHA が一致するときだけ :platform タグを更新して
#       古いビルドによる先祖返りを防いでいる。パスフィルタでビルドを間引くと、マニフェスト
#       変更コミットの直後に docs/ 等だけのコミットが積まれた際に、前のビルドが
#       MAIN_SHA 不一致で終了し、後続コミットでもビルドが起動せず本番反映が黙って
#       スキップされる。全 main コミットでトリガーを走らせることでこの不整合を防ぐ。
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

# Config Sync が読むのは config-sync-repo だけでよい（アプリのイメージ用リポジトリは不要）。
resource "google_artifact_registry_repository_iam_member" "cs_ar_reader" {
  project    = var.project_id
  location   = google_artifact_registry_repository.config_sync_repo.location
  repository = google_artifact_registry_repository.config_sync_repo.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.config_sync_sa.email}"
}

# Workload Identity for Root Reconciler (Platform)
resource "google_service_account_iam_member" "cs_wi_root_reconciler_platform" {
  service_account_id = google_service_account.config_sync_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[config-management-system/root-reconciler-root-sync-platform]"
}

# Config Sync の otel-collector はメトリクス送信だけできればよい。
# config-sync-sa を共用させると Artifact Registry の読み取り権限まで持ってしまうため、
# Workload Identity Federation for GKE の直接プリンシパルで roles/monitoring.metricWriter だけを付与する。
resource "google_project_iam_member" "cs_otel_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.project.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/config-management-monitoring/sa/otel-collector",
  ])

  depends_on = [google_project_service.enabled_apis]
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
    google_container_node_pool.apps_pool,
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

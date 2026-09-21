# =============================================================================
# Canine のビルダー (BuildKit) 専用ノードプール
#
# Canine の Build Cloud は `docker buildx create --driver kubernetes` で
# BuildKit を常駐 Deployment として立てる。rootless を指定しないため
# buildkitd は **privileged** で動く (docker/buildx: manifest.go `privileged := true`)。
# privileged コンテナはノードの root と等価で、ホストのディスクを直接マウントできる。
#
# apps-pool に同居させると、ビルダーが破られたとき同じノードの本番アプリの
# Secret がディスクから読める。そのためビルダーだけを別ノードに隔離する。
#
#   - taint を 2 つ付け、ビルダー以外が載らないようにする
#       cloud.google.com/gke-spot=true:NoSchedule
#       workload-type=build:NoSchedule
#   - ビルダー Pod への nodeSelector / toleration の注入は Kyverno が行う
#     (addons/kyverno/base/clusterpolicy-build-scheduling.yaml)
#   - ノード SA は専用。Artifact Registry の読み取りは**リモートキャッシュの
#     リポジトリだけ**に限定し、アプリのイメージ (= ソースコード) や
#     Config Sync のマニフェストは読めないようにする
#
# NOTE: ビルダーは常駐 Deployment なので、Build Cloud を入れている間は
#       このプールは 0 台にならず、Spot 1 台が常時動く。
# =============================================================================

resource "google_service_account" "gke_build_node" {
  account_id   = "gke-build-node"
  display_name = "GKE build-pool nodes (privileged BuildKit, isolated)"

  depends_on = [google_project_service.enabled_apis]
}

# ノードの動作に必要な最低限 (GKE 推奨)。Artifact Registry の読み取りはプロジェクト
# 全体には付けず、下でリモートキャッシュのリポジトリ単位にだけ付ける。
resource "google_project_iam_member" "gke_build_node_roles" {
  for_each = toset([
    "roles/container.defaultNodeServiceAccount",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.gke_build_node.email}"
}

# kubelet が BuildKit のイメージをキャッシュから取るための、リポジトリ単位の読み取り権限
resource "google_artifact_registry_repository_iam_member" "gke_build_node_docker_hub_cache" {
  project    = var.project_id
  location   = google_artifact_registry_repository.docker_hub_cache.location
  repository = google_artifact_registry_repository.docker_hub_cache.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.gke_build_node.email}"
}

resource "google_artifact_registry_repository_iam_member" "gke_build_node_custom_caches" {
  for_each   = google_artifact_registry_repository.custom_caches
  project    = var.project_id
  location   = each.value.location
  repository = each.value.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.gke_build_node.email}"
}

resource "google_container_node_pool" "build_pool" {
  name     = "build-pool"
  cluster  = google_container_cluster.primary.name
  location = var.zone

  autoscaling {
    total_min_node_count = 0
    total_max_node_count = var.build_pool_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    service_account = google_service_account.gke_build_node.email
    oauth_scopes    = local.node_oauth_scopes

    machine_type = var.build_pool_machine_type
    spot         = true
    disk_size_gb = 50 # ビルドキャッシュとレイヤーの展開に使う
    labels = {
      workload-type = "build"
      node-pool     = "build-pool"
    }
    taint {
      key    = "cloud.google.com/gke-spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
    taint {
      key    = "workload-type"
      value  = "build"
      effect = "NO_SCHEDULE"
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

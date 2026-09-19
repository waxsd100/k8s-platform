# =============================================================================
# Artifact Registry リモートリポジトリ (パブリックレジストリのキャッシュ)
#
# addons/kyverno の ClusterPolicy (clusterpolicy-registry-mirror.yaml) が
# Pod のイメージ参照をここへ書き換える。リポジトリ名を変更する場合は
# ClusterPolicy 側も合わせて修正すること。
#
# 目的: Docker Hub 等のレート制限回避と、ノードでのイメージ取得の高速化。
# =============================================================================

resource "google_artifact_registry_repository" "docker_hub_cache" {
  repository_id = "docker-hub-cache"
  location      = var.region
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Remote cache for docker.io"

  remote_repository_config {
    description = "docker.io"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

locals {
  # カスタム上流を持つリモートリポジトリ
  custom_registry_caches = {
    "ghcr-cache" = "https://ghcr.io"
    "quay-cache" = "https://quay.io"
    "k8s-cache"  = "https://registry.k8s.io"
  }
}

resource "google_artifact_registry_repository" "custom_caches" {
  for_each = local.custom_registry_caches

  repository_id = each.key
  location      = var.region
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Remote cache for ${each.value}"

  remote_repository_config {
    description = each.value
    docker_repository {
      custom_repository {
        uri = each.value
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

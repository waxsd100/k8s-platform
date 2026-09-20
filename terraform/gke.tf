# 1. GKE クラスタ本体
resource "google_container_cluster" "primary" {
  name                = var.cluster_name
  location            = var.zone
  deletion_protection = true

  # VPCとサブネット
  network    = google_compute_network.vpc_network.id
  subnetwork = google_compute_subnetwork.subnet_main.id

  # デフォルトノードプールの削除
  remove_default_node_pool = true
  initial_node_count       = 1

  # プライベートクラスタ設定
  # enable_private_endpoint = true でコントロールプレーンの外部エンドポイントを無効化する。
  # kubectl は Cloudflare WARP -> cloudflared (Private Network ルート) 経由で
  # 内部エンドポイントに到達する。Pod / ノード / VPC 内部 IP は認可ネットワークの
  # 設定に関わらず常に内部エンドポイントへ到達できる。
  # 締め出された場合の復旧手順は docs/GKE_SETUP_GUIDE.md の「緊急時の復旧」を参照。
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = var.private_control_plane_only
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # IPエイリアス設定
  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "10.4.0.0/14"
    services_ipv4_cidr_block = "10.8.0.0/20"
  }

  # マスター承認ネットワーク
  # 既定では 1 件も許可しない（= 公開エンドポイント経由のアクセスを塞ぐ）。
  # 固定 IP から直接触りたい場合のみ master_authorized_cidrs に追加する。
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  release_channel {
    channel = "STABLE"
  }

  # Workload Identity 連携
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
    ]
  }

  # NOTE: GCS FUSE CSI ドライバは Ghost の画像バケットマウント用だった。
  #       現在マウント対象がないため無効化している。必要になったら true に戻す。
  addons_config {
    gcs_fuse_csi_driver_config {
      enabled = false
    }
  }

  # ロギングとモニタリング
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  # クラスタオートスケーリングプロファイル
  # OPTIMIZE_UTILIZATION: ノードの bin-packing を積極化し、アイドルノードを素早く削除
  #
  # NOTE: enabled = false で Node Auto-Provisioning (NAP) を無効にしている。
  #       NAP が有効だと、既存プールに収まらない Pod のために GKE が独自の
  #       ノードプール（Spot ではない通常 VM）を勝手に作りうるため。
  #       ノードプールは system / platform-* / apps の 3 系統に限定する。
  #       resource_limits はプール個別の上限とあわせた保険として残す。
  cluster_autoscaling {
    enabled             = false
    autoscaling_profile = "OPTIMIZE_UTILIZATION"

    resource_limits {
      resource_type = "cpu"
      minimum       = 1
      maximum       = 16
    }
    resource_limits {
      resource_type = "memory"
      minimum       = 2
      maximum       = 64
    }
  }
}

# 2. ノードプール群
# システム用ノードプール
resource "google_container_node_pool" "system_pool" {
  name       = "system-pool"
  cluster    = google_container_cluster.primary.name
  location   = var.zone
  node_count = 2

  autoscaling {
    total_min_node_count = 2
    total_max_node_count = 3
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 30
    labels = {
      workload-type = "system"
      node-pool     = "system-pool"
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# 3. プラットフォーム用ノードプール（Spot / 4ティア）
# Canine, cloudflared, Kyverno, External Secrets 等のプラットフォーム構成要素用。
# 負荷に応じて Cluster Autoscaler が適切なティアをスケールアップする。
# taint により、toleration を持たない一般のアプリ Pod は載らない。
locals {
  platform_pools = {
    "xs" = { machine_type = "e2-small", min = 0, max = 3, disk_size_gb = 20 }
    "sm" = { machine_type = "e2-medium", min = 1, max = 2, disk_size_gb = 30 }
    "md" = { machine_type = "e2-standard-2", min = 0, max = 2, disk_size_gb = 30 }
    "lg" = { machine_type = "e2-standard-4", min = 0, max = 1, disk_size_gb = 30 }
  }
}

resource "google_container_node_pool" "platform_pool" {
  for_each = local.platform_pools
  name     = "platform-${each.key}"
  cluster  = google_container_cluster.primary.name
  location = var.zone

  autoscaling {
    total_min_node_count = each.value.min
    total_max_node_count = each.value.max
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = each.value.machine_type
    spot         = true
    disk_size_gb = each.value.disk_size_gb
    labels = {
      workload-type = "platform"
      node-pool     = "platform-${each.key}"
    }
    taint {
      key    = "cloud.google.com/gke-spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}


# 4. アプリケーション用ノードプール（Spot / プリエンプティブル）
# Canine がデプロイするアプリケーションの実行先。
#
# Canine が生成する Pod は toleration も nodeSelector も持たないが、
# Kyverno の ClusterPolicy (clusterpolicy-app-scheduling.yaml) が
# アプリ用 Namespace の Pod に対して
#   nodeSelector: workload-type=app
#   toleration : cloud.google.com/gke-spot
# を注入する。これにより
#   - アプリは system-pool や platform-* に載らない
#   - Spot ノードを使うのでコストを抑えられる
# の両方を満たす。
resource "google_container_node_pool" "apps_pool" {
  name     = "apps-pool"
  cluster  = google_container_cluster.primary.name
  location = var.zone

  autoscaling {
    total_min_node_count = 0
    total_max_node_count = var.apps_pool_max_nodes
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.apps_pool_machine_type
    spot         = true
    disk_size_gb = 30
    labels = {
      workload-type = "app"
      node-pool     = "apps-pool"
    }
    taint {
      key    = "cloud.google.com/gke-spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

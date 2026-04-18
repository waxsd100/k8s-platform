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
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # IPエイリアス設定
  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "10.4.0.0/14"
    services_ipv4_cidr_block = "10.8.0.0/20"
  }

  # マスター承認ネットワーク
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "All"
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

  addons_config {
    gcs_fuse_csi_driver_config {
      enabled = true
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
  # クラスタ全体での課金暴走を防ぐため resource_limits に絶対上限値を設定
  cluster_autoscaling {
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
  node_count = 1

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = 2
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
# Nginx, Cloudflared, Kyverno, KEDA 等のインフラコンポーネント用
# 負荷に応じて Cluster Autoscaler が適切なティアをスケールアップ
locals {
  platform_pools = {
    "xs" = { machine_type = "e2-small", min = 0, max = 3, disk_size_gb = 20 }
    "sm" = { machine_type = "e2-medium", min = 1, max = 2, disk_size_gb = 30 }
    "md" = { machine_type = "e2-standard-2", min = 0, max = 2, disk_size_gb = 30 }
    "lg" = { machine_type = "e2-standard-4", min = 0, max = 1, disk_size_gb = 30 }
  }

  prod_pools = {
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

# 開発用(Dev) Spot ノードプール
resource "google_container_node_pool" "dev_pool" {
  name     = "dev-pool"
  cluster  = google_container_cluster.primary.name
  location = var.zone

  autoscaling {
    total_min_node_count = 0
    total_max_node_count = 1
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = "e2-small"
    spot         = true
    disk_size_gb = 20
    labels = {
      workload-type = "app"
      node-pool     = "dev-pool"
    }
    tags = [
      "gke-${var.cluster_name}-dev-pool",
      "use-custom-nat"
    ]
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

# ステージング用(Stag) Spot ノードプール
resource "google_container_node_pool" "stag_pool" {
  name     = "stag-pool"
  cluster  = google_container_cluster.primary.name
  location = var.zone

  autoscaling {
    total_min_node_count = 0
    total_max_node_count = 2
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = "e2-small"
    spot         = true
    disk_size_gb = 20
    labels = {
      workload-type = "app"
      node-pool     = "stag-pool"
    }
    tags = [
      "gke-${var.cluster_name}-stag-pool",
      "use-custom-nat"
    ]
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

# 本番用 Spot ノードプール（3ティア）
# 負荷に応じて Cluster Autoscaler が適切なティアをスケールアップ


resource "google_container_node_pool" "prod_pool" {
  for_each = local.prod_pools
  name     = "prod-${each.key}"
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
      workload-type = "app"
      node-pool     = "prod-${each.key}"
    }
    tags = [
      "lb-health-check"
    ]
    taint {
      key    = "dedicated"
      value  = "prod-app"
      effect = "NO_SCHEDULE"
    }
    taint {
      key    = "cloud.google.com/gke-spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
    # Prod poolはデフォルトでCloud NATへ通信する想定
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

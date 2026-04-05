# 1. GKE クラスタ本体
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone

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

  # ロギングとモニタリング
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
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
    min_node_count = 1
    max_node_count = 1
  }

  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 30
    labels = {
      workload-type = "system"
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# 開発用 Spot ノードプール
resource "google_container_node_pool" "app_pool" {
  name       = "app-pool"
  cluster    = google_container_cluster.primary.name
  location   = var.zone

  autoscaling {
    min_node_count = 0
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-small"
    spot         = true
    disk_size_gb = 20
    labels = {
      workload-type = "app"
    }
    tags = [
      "gke-${var.cluster_name}-app-pool",
      "use-custom-nat" # カスタムNATへルーティングさせる
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

# 本番用 Spot ノードプール
resource "google_container_node_pool" "prod_pool" {
  name       = "prod-pool"
  cluster    = google_container_cluster.primary.name
  location   = var.zone
  node_count = 1

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-small"
    spot         = true
    disk_size_gb = 30
    labels = {
      workload-type = "app"
    }
    # Prod poolはデフォルトでCloud NATへ通信する想定
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# =============================================================================
# GKE クラスタ本体（Standard / ゾーン / STABLE チャンネル）
# =============================================================================
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

  # 作成直後に消す default pool も専用 SA で作る（Compute Engine の既定 SA に
  # 権限を足さずに済むように）。default pool は消えるので、以降の差分は無視する。
  node_config {
    service_account = google_service_account.gke_node.email
    oauth_scopes    = local.node_oauth_scopes
  }

  # Dataplane V2。NetworkPolicy を実際に効かせるために必要
  # （components/infrastructure/canine/base/networkpolicy.yaml）。
  # 作成後は変更できない（変えるとクラスタの作り直し）。
  # NOTE: 各ノードに anetd (Cilium) の DaemonSet が載る。
  datapath_provider = "ADVANCED_DATAPATH"

  # コントロールプレーンへの到達経路
  # 管理者の kubectl は DNS ベースエンドポイントを使い、認可は IAM で行う
  # （container.clusters.connect）。クラスタ内の何にも依存しないため、
  # cloudflared やノードの状態に関係なく到達できる。
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = var.enable_dns_endpoint_external
    }
  }

  # プライベートクラスタ設定
  # enable_private_endpoint = true でコントロールプレーンの外部 IP エンドポイントを
  # 無効化する。IP 経由で触れるのは VPC 内部からだけになる。
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = var.private_control_plane_only
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # IPエイリアス設定
  ip_allocation_policy {
    cluster_ipv4_cidr_block  = var.pods_cidr
    services_ipv4_cidr_block = var.services_cidr
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

  # 垂直 Pod 自動スケーリング (VPA)。プラットフォームの requests を実測から見直すために、
  # 推奨値だけを出させる（updateMode: Off。components/infrastructure/vpa-recommendations）。
  # Pod を書き換えないので、有効にしても挙動は変わらない。
  vertical_pod_autoscaling {
    enabled = true
  }

  # Workload Identity 連携
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
      node_config,
    ]
  }

  # GCS FUSE CSI ドライバ: restic のリポジトリ（gs://wax100-platform/restic/）を
  # rest-server と restic-maintenance にマウントする（storage.tf / backup.tf）。
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
    # GKE 1.27 以降の Standard クラスタは Managed Service for Prometheus の
    # マネージド収集が既定で有効になり、collector DaemonSet が全ノード
    # （system-pool を含む）に載る。今は使わないので明示的に切る。
    # 必要になったら true にする。
    managed_prometheus {
      enabled = false
    }
  }

  # クラスタオートスケーリングプロファイル
  # OPTIMIZE_UTILIZATION: ノードの bin-packing を積極化し、アイドルノードを素早く削除
  #
  # NOTE: enabled = false で Node Auto-Provisioning (NAP) を無効にしている。
  #       NAP が有効だと、既存プールに収まらない Pod のために GKE が独自の
  #       ノードプール（Spot ではない通常 VM）を勝手に作りうるため。
  #       ノードプールは system / platform / apps / build の 4 つに限定する。
  #
  # NOTE: resource_limits は置かない。以前は cpu 16 / memory 64 を「保険」として
  #       書いていたが、この上限は **手動で作ったノードプールも含めた合計**に効く
  #       (GKE のドキュメント: "applies to the sum of CPU cores across all of the
  #       node pools in the cluster, including manually created node pools")。
  #       各プールの上限の合計は vCPU 20 (system 6 / platform 6 / apps 6 / build 2)
  #       なので、16 だと全プールを使い切る前に黙って頭打ちになっていた。
  #       上限は各プールの max_node_count で管理する。
  cluster_autoscaling {
    enabled             = false
    autoscaling_profile = "OPTIMIZE_UTILIZATION"
  }

  # default pool のノードが gke-node SA で動くので、その権限を先に付けておく
  depends_on = [
    google_project_service.enabled_apis,
    google_project_iam_member.gke_node_roles,
  ]
}

# =============================================================================
# ノードプール
#
# 4 プールとも共通:
#   - ノード SA は最小権限の専用 SA (iam.tf の gke-node、build-pool だけ gke-build-node)。
#     Compute Engine の既定 SA は Editor を持ちうるため使わない。apps-pool には
#     利用者が Canine 経由で投入した任意のコンテナが載る。
#   - management を明示する。書かないとプロバイダは設定を送らず GKE API の既定値任せになる。
#     NotReady になったノードを GKE が作り直す (auto_repair) ことを確実にするため。
#   - max_surge = 1 / max_unavailable = 0 で、アップグレード時は 1 台足してから入れ替える。
#   - node_count は autoscaling と併用しない。併用するとオートスケーラが増やした
#     ノードを次の plan が「余分」と判断し、apply で落としてしまう。
#   - Spot プールには cloud.google.com/gke-spot=true:NoSchedule の taint を付け、
#     toleration を持たない Pod を載せない（注入は Kyverno が行う）。
# =============================================================================

locals {
  node_oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
}

# システム用ノードプール（通常 VM）
# 停止を許容しないもの: kube-system、cloudflared、ingress-nginx。
resource "google_container_node_pool" "system_pool" {
  name     = "system-pool"
  cluster  = google_container_cluster.primary.name
  location = var.zone

  # 作成時の台数。書かないとプロバイダは 0 台で作る（expandNodePool の既定値）。
  # オートスケーラは最小台数まで自分からは増やさない（"Lower than the minimum you
  # specified: Cluster autoscaler scales up to provision pending pods"）ので、
  # 停止を許容しない system は最初から最小の 1 台で立てる。
  initial_node_count = 1

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = 3
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
    service_account = google_service_account.gke_node.email
    oauth_scopes    = local.node_oauth_scopes

    machine_type = var.system_pool_machine_type
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

# プラットフォーム用ノードプール（Spot / 単一プール）
# Canine, Config Sync, Kyverno, External Secrets, Reloader, 昇格・スナップショット用。
# （cloudflared と ingress-nginx は停止を許容しないため system-pool に置いている）
# taint により、toleration を持たない一般のアプリ Pod は載らない。
#
# NOTE: 以前は xs/sm/md/lg の 4 ティアに分けていたが、単一プールに戻した。
#       Cluster Autoscaler は「A プールを空けるために B プールを増やす」ことを
#       しない。縮退の判定は **今あるノード**に載せ替えられるかだけで行う。
#       そのため最小 0 のプールが並んでいると、いったん各プールに散った Pod を
#       寄せ直す経路が無く、Spot の回収でプールが入れ替わるたびにノードが
#       増える一方になり、全プールが上限に張り付いたまま戻らなくなる。
#       プールを 1 つにすれば同一プール内で自由に載せ替えられ、素直に縮退する。
#
#       常駐 Pod の要求合計は概ね cpu 750m / memory 1.7Gi。e2-standard-2
#       (cpu 2 / memory 8Gi) なら通常時 1 台に収まる。
resource "google_container_node_pool" "platform_pool" {
  name     = "platform-pool"
  cluster  = google_container_cluster.primary.name
  location = var.zone

  # 最小の 1 台で立てる（理由は system-pool と同じ）。apps / build は 0 台から始めてよい。
  initial_node_count = 1

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = var.platform_pool_max_nodes
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
    service_account = google_service_account.gke_node.email
    oauth_scopes    = local.node_oauth_scopes

    machine_type = var.platform_pool_machine_type
    spot         = true
    disk_size_gb = 30
    labels = {
      workload-type = "platform"
      node-pool     = "platform-pool"
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


# アプリケーション用ノードプール（Spot）
# Canine がデプロイするアプリケーションの実行先。
#
# Canine が生成する Pod は toleration も nodeSelector も持たないが、
# Kyverno の ClusterPolicy (clusterpolicy-app-scheduling.yaml) が
# アプリ用 Namespace の Pod に対して
#   nodeSelector: workload-type=app
#   toleration : cloud.google.com/gke-spot
# を注入する。これにより
#   - アプリは system-pool / platform-pool / build-pool に載らない
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

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    service_account = google_service_account.gke_node.email
    oauth_scopes    = local.node_oauth_scopes

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

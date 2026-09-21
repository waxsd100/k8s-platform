# 1. 共通プロジェクトデータ
# コンピュートエンジンのデフォルトサービスアカウント
data "google_project" "project" {
}

locals {
  compute_sa_email = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# 2. デフォルトコンピュートアカウントの権限
# GKEノードに必要なデフォルト権限
resource "google_project_iam_member" "compute_sa_node_role" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${local.compute_sa_email}"
}

# GKEノードにArtifact Registryの読み取り権限
resource "google_project_iam_member" "compute_sa_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${local.compute_sa_email}"
}

# =============================================================================
# GKE ノード専用のサービスアカウント
#
# 既定の Compute Engine SA はプロジェクト作成時に roles/editor を持つことが多く、
# apps-pool には利用者が Canine 経由で投入した任意のコンテナが載る。
# hostNetwork などでメタデータサーバに届いた場合の被害を最小化するため、
# ノードには必要最小限のロールだけを持つ SA を使う。
# =============================================================================
resource "google_service_account" "gke_node" {
  account_id   = "gke-node"
  display_name = "GKE node pools (least privilege)"

  depends_on = [google_project_service.enabled_apis]
}

# GKE はカスタムのノード SA に最低限 roles/container.defaultNodeServiceAccount を
# 付けるよう求めている ("At a minimum, these node service accounts must have ...")。
# ログ・メトリクス書き込みなど、ノードの動作に必要な権限はこのロールにまとまっている。
# 個別ロールを並べると、GKE 側で必要な権限が増えたときに追従できない。
resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset([
    "roles/container.defaultNodeServiceAccount",
    # アプリのイメージ (Canine が push したもの) とリモートキャッシュを pull する
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

# =============================================================================
# コントロールプレーンに kubectl で到達できる人 / SA
#
# DNS ベースエンドポイントの認可は IAM で行う (container.clusters.connect)。
# roles/container.developer にこの権限が含まれる。ここを空のままにすると、
# プロジェクトのオーナー権限を持っている人しか触れない状態になる。
# =============================================================================
resource "google_project_iam_member" "cluster_operators" {
  for_each = toset(var.cluster_operator_members)
  project  = var.project_id
  role     = "roles/container.developer"
  member   = each.key

  depends_on = [google_project_service.enabled_apis]
}

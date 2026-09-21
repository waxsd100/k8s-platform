# プロジェクト番号（Workload Identity のプリンシパルや IAM 条件で使う）
data "google_project" "project" {
}

# NOTE: 以前は Compute Engine の既定 SA に container.defaultNodeServiceAccount と
#       artifactregistry.reader を付けていた。クラスタ作成時に一瞬だけ作られる
#       default pool がその SA で動いていたため。今は gke.tf でその default pool も
#       gke-node SA で作るので、既定 SA に権限を足す必要は無くなった。

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

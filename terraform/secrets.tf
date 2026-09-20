# 1. Cloudflare 関連シークレット
# NOTE: cloudflared のトークンは Terraform が書き込む（cloudflare-tunnel.tf）。
#       cloudflare-api-token だけは鶏と卵のため手動登録が要る。
# ==== Cloudflare ====
resource "google_secret_manager_secret" "cloudflare_api_token" {
  secret_id = "cloudflare-api-token"
  replication {
    auto {}
  }
}

# NOTE: cloudflare-zone-id の Secret はここにあったが削除した。
#       Terraform はこの値を Secret Manager からは読まず、変数
#       var.cloudflare_zone_id だけを入力にしている。Secret に入れても
#       どこからも参照されず、「手順書どおりに入れたのに Cloudflare の
#       リソースが 1 つも作られない」という無言の失敗を招いていた。
#       Zone ID は機密ではないので変数で渡す。

# ESO (External Secrets Operator) にプロジェクト全体のシークレットアクセス権を付与
# (※gcloud等で手動作成したTLS証明書系のシークレットにもアクセスさせるため個別からプロジェクトレベルへ変更)
#
# Workload Identity Federation for GKE の「直接プリンシパル」方式で、
# Kubernetes ServiceAccount に直接ロールを付ける。GSA の作成も
# iam.gke.io/gcp-service-account アノテーションも不要。
#
# NOTE: かつて member を
#         serviceAccount:<project>.svc.id.goog[external-secrets/external-secrets]
#       と書いていたが、この形式は **GSA のポリシーに
#       roles/iam.workloadIdentityUser を付けるとき専用**で、
#       プロジェクトレベルのバインディングでは無効。この誤りがあると
#       ESO は Secret Manager を読めず、すべての ExternalSecret が
#       PERMISSION_DENIED になり、Canine も cloudflared も起動しない。
#       出典: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
resource "google_project_iam_member" "eso_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.project.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/external-secrets/sa/external-secrets",
  ])

  depends_on = [google_project_service.enabled_apis]
}

# cloudflared (Cloudflare Tunnel) のトークン
# cloudflare_manage_tunnel = true（既定）なら cloudflare-tunnel.tf が
# トンネルを作り、この Secret に版を自動で追加する。手でコピーする必要はない。
resource "google_secret_manager_secret" "cloudflared_tunnel_token" {
  secret_id = "cloudflared-tunnel-token"
  replication {
    auto {}
  }
}

# Canine のアプリ定義スナップショット用 GitHub トークン
# 値は Fine-grained PAT（スナップショット先リポジトリの Contents: Read and write）を
# 手動で登録する
resource "google_secret_manager_secret" "canine_snapshot_github_token" {
  secret_id = "canine-snapshot-github-token"
  replication {
    auto {}
  }
}

# 昇格 PR を立てるための GitHub トークン
# 値は Fine-grained PAT（k8s-platform の Contents / Pull requests: Read and write）を
# 手動で登録する
resource "google_secret_manager_secret" "canine_promote_github_token" {
  secret_id = "canine-promote-github-token"
  replication {
    auto {}
  }
}

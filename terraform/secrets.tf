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

resource "google_secret_manager_secret" "cloudflare_zone_id" {
  secret_id = "cloudflare-zone-id"
  replication {
    auto {}
  }
}

# ESO (External Secrets Operator) にプロジェクト全体のシークレットアクセス権を付与
# (※gcloud等で手動作成したTLS証明書系のシークレットにもアクセスさせるため個別からプロジェクトレベルへ変更)
resource "google_project_iam_member" "eso_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${var.project_id}.svc.id.goog[external-secrets/external-secrets]"
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

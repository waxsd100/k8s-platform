# 1. Cloudflare 関連シークレット
# NOTE: cloudflared (Cloudflare Tunnel) のトークンは
#       Secret Manager に手動登録し、ESO 経由でクラスタに渡す。
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

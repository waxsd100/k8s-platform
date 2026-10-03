# =============================================================================
# Terraform state の保管先
#
# 既定では state はこのディレクトリのローカルファイルに置かれる。そこには
# Cloudflare API トークン、トンネルトークン、Canine の DB パスワードと
# SECRET_KEY_BASE が**平文で**入る。ロックもバージョニングも無く、
# 端末が壊れれば復旧できない。
#
# そのため providers.tf の backend "gcs" でこのバケットに置く（暗号化・バージョニング・ロックが効く）。
#
# 鶏と卵になるため、新規構築では最初にバケットだけ gcloud で作り、terraform import で
# このリソースに取り込む（docs/GKE_SETUP_GUIDE.md の 2.1）。以降の設定は Terraform が管理する。
# =============================================================================
resource "google_storage_bucket" "tf_state" {
  name     = "${var.project_id}-tfstate"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # 誤って state を壊したときに戻せるようにする
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.enabled_apis]
}


# =============================================================================
# Terraform state の保管先
#
# 既定では state はこのディレクトリのローカルファイルに置かれる。そこには
# Cloudflare API トークン、トンネルトークン、Canine の DB パスワードと
# SECRET_KEY_BASE が**平文で**入る。ロックもバージョニングも無く、
# 端末が壊れれば復旧できない。
#
# このバケットを作ってから、下の backend ブロックを有効にして
#   terraform init -migrate-state
# を実行すると、state が GCS に移り、暗号化・バージョニング・ロックが効く。
#
# 鶏と卵になるため、バケット自体はローカル state で作る。移行後は
# バケットのリソース定義も GCS 上の state が管理する。
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

# 移行手順:
#   1. terraform apply でこのバケットを作る
#   2. providers.tf の backend ブロックのコメントを外す
#   3. terraform init -migrate-state
#   4. ローカルの terraform.tfstate / *.backup を削除する

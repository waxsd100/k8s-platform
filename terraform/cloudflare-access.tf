# =============================================================================
# Cloudflare Access (Zero Trust) — Canine UI の保護
#
# Canine の ClusterRole は全リソース・全 verb を許可する（実質 cluster-admin）。
# UI を奪われるとクラスタ全体を奪われるため、Access による認証は必須。
# ダッシュボードでの手作業に頼らず、ここで宣言的に定義する。
#
# 有効化の条件:
#   - var.cloudflare_account_id が設定されている
#   - var.canine_admin_emails が1件以上
#   - Secret Manager の cloudflare-api-token に版が登録済み
#     （必要な権限: Access: Apps and Policies Read/Write）
# いずれかが欠けている場合、このファイルのリソースは作られない。
# =============================================================================

locals {
  # Cloudflare プロバイダを使うかどうか。API トークンの読み込み条件でもある。
  cloudflare_enabled = var.cloudflare_account_id != ""

  cloudflare_access_enabled = local.cloudflare_enabled && length(var.canine_admin_emails) > 0
}

data "google_secret_manager_secret_version" "cloudflare_api_token" {
  count   = local.cloudflare_enabled ? 1 : 0
  secret  = google_secret_manager_secret.cloudflare_api_token.secret_id
  project = var.project_id
}

# アクセスを許可する管理者を列挙するポリシー
resource "cloudflare_zero_trust_access_policy" "canine_admins" {
  count = local.cloudflare_access_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "canine-admins"
  decision   = "allow"

  include = [
    for email in var.canine_admin_emails : {
      email = {
        email = email
      }
    }
  ]

  # NOTE: 端末条件（WARP 接続必須など）を足す場合は require ルールを追加する。
  #       デバイスポスチャの ID はダッシュボード側で作成したものを参照する必要があるため、
  #       ここでは入口をメールアドレスの許可リストに限定するところまでを定義する。
  session_duration = "24h"
}

resource "cloudflare_zero_trust_access_application" "canine" {
  count = local.cloudflare_access_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "Canine"
  type       = "self_hosted"

  destinations = [{
    type = "public"
    uri  = var.canine_hostname
  }]

  # ID プロバイダの選択画面を挟まずに直接認証へ飛ばす
  auto_redirect_to_identity = true
  session_duration          = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.canine_admins[0].id
    precedence = 1
  }]
}

# =============================================================================
# Cloudflare Access (Zero Trust) — Canine UI・Headlamp・Backrest の保護
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
  cloudflare_access_enabled = local.cloudflare_enabled && length(var.canine_admin_emails) > 0
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

  # IdP が 1 つに決まっているときだけ、選択画面を挟まずに直接認証へ飛ばす
  allowed_idps              = length(var.cloudflare_access_allowed_idps) > 0 ? var.cloudflare_access_allowed_idps : null
  auto_redirect_to_identity = length(var.cloudflare_access_allowed_idps) == 1
  session_duration          = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.canine_admins[0].id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_application" "dashboard" {
  count = local.cloudflare_access_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "Headlamp"
  type       = "self_hosted"

  destinations = [{
    type = "public"
    uri  = var.dashboard_hostname
  }]

  allowed_idps              = length(var.cloudflare_access_allowed_idps) > 0 ? var.cloudflare_access_allowed_idps : null
  auto_redirect_to_identity = length(var.cloudflare_access_allowed_idps) == 1
  session_duration          = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.canine_admins[0].id
    precedence = 1
  }]
}

# Backrest（backup.wax100.io）。スナップショットの中身（DB のダンプ）を読めるので、
# Canine と同じ管理者だけに絞る。Backrest 自身のログインも別にある。
resource "cloudflare_zero_trust_access_application" "backup" {
  count = local.cloudflare_access_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "Backrest"
  type       = "self_hosted"

  destinations = [{
    type = "public"
    uri  = var.backup_hostname
  }]

  allowed_idps              = length(var.cloudflare_access_allowed_idps) > 0 ? var.cloudflare_access_allowed_idps : null
  auto_redirect_to_identity = length(var.cloudflare_access_allowed_idps) == 1
  session_duration          = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.canine_admins[0].id
    precedence = 1
  }]
}

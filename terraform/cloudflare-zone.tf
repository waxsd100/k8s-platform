# =============================================================================
# Cloudflare ゾーンの TLS / HSTS 設定
#
# オリジンは Cloudflare Tunnel の内側で HTTP だけを話すので、HTTPS への転送や HSTS は
# Cloudflare のエッジでしか効かない。これまで手作業でダッシュボードに設定していたなら、
# この設定はどこにも残っていない。ここで宣言すると、その値が Terraform で管理されるようになる。
#
# 既定は無効（cloudflare_manage_zone_security = false）。API トークンに
# 「Zone Settings: Edit」が無いと apply が失敗するため、権限を足してから true にする。
#
# 設定する値:
#   - always_use_https: on（HTTP を HTTPS に転送）
#   - min_tls_version: 1.2（TLS 1.0 / 1.1 を拒否）
#   - security_header（HSTS）: max-age 180 日、nosniff 有効
#     include_subdomains と preload は意図して無効にしている。サブドメインの中に
#     HTTP しか話せないものがあると壊れる。preload は一度載ると取り下げに数か月かかる。
#     どちらもドメイン全体を確かめてから、手で決めること。
# =============================================================================

locals {
  cloudflare_zone_security_enabled = local.cloudflare_enabled && var.cloudflare_zone_id != "" && var.cloudflare_manage_zone_security
}

resource "cloudflare_zone_setting" "always_use_https" {
  count = local.cloudflare_zone_security_enabled ? 1 : 0

  zone_id    = var.cloudflare_zone_id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone_setting" "min_tls_version" {
  count = local.cloudflare_zone_security_enabled ? 1 : 0

  zone_id    = var.cloudflare_zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "security_header" {
  count = local.cloudflare_zone_security_enabled ? 1 : 0

  zone_id    = var.cloudflare_zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 15552000 # 180 日
      include_subdomains = false
      preload            = false
      nosniff            = true
    }
  }
}

# =============================================================================
# Cloudflare Tunnel のルーティングと DNS
#
# ここを宣言的にしておくことで、アプリの公開が完全に自動になる:
#   *.apps.<domain> はすべて ingress-nginx に流れるため、
#   アプリは Ingress リソースを 1 つ持つだけで公開される。
#   Cloudflare ダッシュボードでの hostname 追加も DNS レコードの作成も不要。
#
# トンネル本体はトークン方式（リモート管理）のまま。このリソースは
# そのトンネルの設定を API 経由で書き換える。
#
# 有効化の条件: cloudflare_account_id / cloudflare_tunnel_id / cloudflare_zone_id
#               がすべて設定されていること。未設定なら何も作られない。
# =============================================================================

locals {
  cloudflare_tunnel_enabled = (
    var.cloudflare_account_id != "" &&
    var.cloudflare_tunnel_id != "" &&
    var.cloudflare_zone_id != ""
  )

  # クラスタ内の転送先
  canine_service = "http://canine.canine.svc.cluster.local:3000"
  nginx_service  = "http://ingress-nginx-controller.infra.svc.cluster.local:80"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  count = local.cloudflare_tunnel_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id

  config = {
    ingress = [
      # 管理 UI（Cloudflare Access で保護される）
      {
        hostname = var.canine_hostname
        service  = local.canine_service
      },
      # アプリはすべて ingress-nginx へ。振り分けは Ingress リソースが行う。
      {
        hostname = "*.${var.apps_domain}"
        service  = local.nginx_service
        origin_request = {
          # Host ヘッダをそのまま渡さないと Ingress のホスト一致が効かない
          http_host_header = ""
        }
      },
      # catch-all（Cloudflare Tunnel の設定上、末尾に service だけのルールが必須）
      {
        service = "http_status:404"
      }
    ]
  }
}

# ワイルドカード DNS。これ 1 件でアプリのサブドメインがすべて解決する。
resource "cloudflare_dns_record" "apps_wildcard" {
  count = local.cloudflare_tunnel_enabled ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "*.${var.apps_domain}"
  type    = "CNAME"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # proxied のときは 1 (automatic) を指定する
  comment = "Managed by Terraform: all apps route through the tunnel to ingress-nginx"
}

resource "cloudflare_dns_record" "canine" {
  count = local.cloudflare_tunnel_enabled ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.canine_hostname
  type    = "CNAME"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform: Canine control plane UI"
}

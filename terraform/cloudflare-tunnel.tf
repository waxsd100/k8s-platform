# =============================================================================
# Cloudflare Tunnel 本体・ルーティング・DNS
#
# ここを宣言的にしておくことで、アプリの公開が完全に自動になる:
#   *.<domain> はすべて ingress-nginx に流れるため、
#   アプリは Ingress リソースを 1 つ持つだけで公開される。
#   Cloudflare ダッシュボードでの hostname 追加も DNS レコードの作成も不要。
#
# トンネル自体も Terraform で作る（cloudflare_manage_tunnel = true、既定）。
# トークンは Secret Manager に自動で書き込まれ、ESO 経由で cloudflared に渡る。
# ダッシュボードで作った既存のトンネルを使う場合は
# cloudflare_manage_tunnel = false にして cloudflare_tunnel_id を指定する。
#
# 有効化の条件: cloudflare_account_id と cloudflare_zone_id が設定されていること。
#               未設定なら何も作られない。
# =============================================================================

locals {
  cloudflare_tunnel_enabled = (
    local.cloudflare_enabled &&
    var.cloudflare_zone_id != "" &&
    (var.cloudflare_manage_tunnel || var.cloudflare_tunnel_id != "")
  )

  manage_tunnel = local.cloudflare_tunnel_enabled && var.cloudflare_manage_tunnel

  cloudflare_tunnel_id = (
    local.manage_tunnel
    ? try(cloudflare_zero_trust_tunnel_cloudflared.main[0].id, "")
    : var.cloudflare_tunnel_id
  )

  # クラスタ内の転送先
  canine_service   = "http://canine.canine.svc.cluster.local:3000"
  headlamp_service = "http://headlamp.headlamp.svc.cluster.local:80"
  nginx_service    = "http://ingress-nginx-controller.infra.svc.cluster.local:80"
}

# -----------------------------------------------------------------------------
# トンネル本体
# -----------------------------------------------------------------------------
resource "random_bytes" "tunnel_secret" {
  count  = local.manage_tunnel ? 1 : 0
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  count = local.manage_tunnel ? 1 : 0

  account_id    = var.cloudflare_account_id
  name          = var.cluster_name
  tunnel_secret = random_bytes.tunnel_secret[0].base64
  # 設定を API（= この Terraform）側で持つリモート管理トンネル
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "main" {
  count = local.manage_tunnel ? 1 : 0

  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main[0].id
}

# cloudflared が読むトークン。ESO がこのシークレットをクラスタに同期する。
# 手でダッシュボードからコピーしてくる必要はない。
resource "google_secret_manager_secret_version" "cloudflared_tunnel_token" {
  count = local.manage_tunnel ? 1 : 0

  secret      = google_secret_manager_secret.cloudflared_tunnel_token.id
  secret_data = data.cloudflare_zero_trust_tunnel_cloudflared_token.main[0].token
}

# -----------------------------------------------------------------------------
# ルーティング
# -----------------------------------------------------------------------------
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  count = local.cloudflare_tunnel_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  tunnel_id  = local.cloudflare_tunnel_id

  config = {
    ingress = [
      # 管理 UI（Cloudflare Access で保護される）
      {
        hostname = var.canine_hostname
        service  = local.canine_service
      },
      # Headlamp（Cloudflare Access で保護される）。ワイルドカードより前に置く
      {
        hostname = var.dashboard_hostname
        service  = local.headlamp_service
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

# -----------------------------------------------------------------------------
# DNS
# -----------------------------------------------------------------------------

# ワイルドカード DNS。これ 1 件でアプリのサブドメインがすべて解決する。
resource "cloudflare_dns_record" "apps_wildcard" {
  count = local.cloudflare_tunnel_enabled ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "*.${var.apps_domain}"
  type    = "CNAME"
  content = "${local.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # proxied のときは 1 (automatic) を指定する
  comment = "Managed by Terraform: all apps route through the tunnel to ingress-nginx"
}

resource "cloudflare_dns_record" "canine" {
  count = local.cloudflare_tunnel_enabled ? 1 : 0

  # Canine の UI は実質 cluster-admin。Access を付けずに公開ホスト名だけ
  # 生やすのは事故なので、apply の時点で止める。
  lifecycle {
    precondition {
      condition     = local.cloudflare_access_enabled
      error_message = "canine_admin_emails が空です。Cloudflare Access 無しで Canine UI を公開することはできません。許可するメールアドレスを設定してから apply してください。"
    }
  }

  zone_id = var.cloudflare_zone_id
  name    = var.canine_hostname
  type    = "CNAME"
  content = "${local.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform: Canine control plane UI"
}

resource "cloudflare_dns_record" "dashboard" {
  count = local.cloudflare_tunnel_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.cloudflare_access_enabled
      error_message = "canine_admin_emails が空です。Cloudflare Access 無しで Headlamp を公開することはできません。"
    }
  }

  zone_id = var.cloudflare_zone_id
  name    = var.dashboard_hostname
  type    = "CNAME"
  content = "${local.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform: Headlamp dashboard"
}

# =============================================================================
# WARP まわりを Terraform で完結させる
#
# ダッシュボードで手作業が残っていた 3 つをここで宣言する:
#   1. トンネルの Private Network ルート（コントロールプレーンの /28）
#   2. WARP の Split Tunnel 設定（既定の除外リストが RFC1918 を丸ごと除外しており、
#      そのままでは 172.16.0.0/28 に届かない）
#   3. デバイス登録の許可ポリシー（これが無いと WARP に登録できない）
#
# 出典:
#   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/private-net/cloudflared/connect-cidr/
#   https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/
#   https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/warp/deployment/device-enrollment/
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Private Network ルート
#    このルートがあると、WARP に接続した端末から 172.16.0.0/28 が
#    クラスタ内の cloudflared を抜けて到達できるようになる。
# -----------------------------------------------------------------------------
resource "cloudflare_zero_trust_tunnel_cloudflared_route" "control_plane" {
  count = local.cloudflare_tunnel_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  tunnel_id  = local.cloudflare_tunnel_id
  network    = var.master_ipv4_cidr_block
  comment    = "Managed by Terraform: GKE control plane (private endpoint)"
}

# -----------------------------------------------------------------------------
# 2. Split Tunnel（除外モード）
#
# WARP の既定の除外リストには 172.16.0.0/12 が含まれる。つまり
# **ルートを足しただけでは端末は WARP を使わず直接 172.16.0.0/28 に出ようとして失敗する**。
# Cloudflare のドキュメントはこう指示している:
#   「プライベートネットワークの IP/CIDR を含むルートを削除する」
#   「除外モードの場合は、周囲の CIDR ブロックを足し直して、
#     それ以外のプライベート空間は除外されたままにする」
#
# ここではその「足し直し」を手で並べるのではなく計算で出す。
# 172.16.0.0/28 は 172.16.0.0/12 の先頭ブロックなので、各階層の
# 「もう半分」を集めれば、/28 だけを残した補集合になる。
#   /13 の後半 172.24.0.0/13 ... /28 の後半 172.16.0.16/28  （計 16 ブロック）
#
# NOTE: exclude は宣言した内容で**全置換**される。Cloudflare 推奨の既定値を
#       すべて並べているのはそのため。1 つ消すとインターネットや
#       ローカルリソースへの接続が壊れうる。
# -----------------------------------------------------------------------------
locals {
  warp_split_tunnel_enabled = local.cloudflare_tunnel_enabled && var.warp_manage_split_tunnel

  # 除外から外したい親ブロックと、その中で WARP に通したい範囲
  warp_parent_bits = tonumber(split("/", var.warp_private_parent_cidr)[1])
  warp_master_bits = tonumber(split("/", var.master_ipv4_cidr_block)[1])

  # 親ブロックから master_ipv4_cidr_block だけを差し引いた補集合
  warp_parent_complement = [
    for bits in range(local.warp_parent_bits + 1, local.warp_master_bits + 1) :
    cidrsubnet(var.warp_private_parent_cidr, bits - local.warp_parent_bits, 1)
  ]

  # Cloudflare 推奨の既定除外リスト。var.warp_private_parent_cidr だけを
  # 補集合に差し替える。
  warp_default_excludes = [
    { address = "ff05::/16", description = "IPv6 Multicast" },
    { address = "ff04::/16", description = "IPv6 Multicast" },
    { address = "ff03::/16", description = "IPv6 Multicast" },
    { address = "ff02::/16", description = "IPv6 Multicast" },
    { address = "ff01::/16", description = "IPv6 Multicast" },
    { address = "fe80::/10", description = "IPv6 Link Local" },
    { address = "fd00::/8", description = "IPv6 Unique Local" },
    { address = "255.255.255.255/32", description = "DHCP Broadcast" },
    { address = "240.0.0.0/4", description = "Reserved" },
    { address = "224.0.0.0/24", description = "Multicast" },
    { address = "192.168.0.0/16", description = "RFC1918" },
    { address = "192.0.0.0/24", description = "IETF Protocol Assignments" },
    { address = "172.16.0.0/12", description = "RFC1918" },
    { address = "169.254.0.0/16", description = "DHCP Unspecified" },
    { address = "100.64.0.0/10", description = "CGNAT" },
    { address = "10.0.0.0/8", description = "RFC1918" },
  ]

  warp_exclude_list = concat(
    [for e in local.warp_default_excludes : e if e.address != var.warp_private_parent_cidr],
    [
      for cidr in local.warp_parent_complement :
      { address = cidr, description = "RFC1918 (${var.master_ipv4_cidr_block} のみ WARP を通す)" }
    ]
  )
}

resource "cloudflare_zero_trust_device_default_profile" "main" {
  count = local.warp_split_tunnel_enabled ? 1 : 0

  account_id = var.cloudflare_account_id

  exclude = local.warp_exclude_list

  lifecycle {
    precondition {
      condition     = cidrhost(var.warp_private_parent_cidr, 0) == cidrhost(var.master_ipv4_cidr_block, 0)
      error_message = "master_ipv4_cidr_block は warp_private_parent_cidr の先頭ブロックである必要があります（補集合の計算がこの前提に依存しています）。別の範囲を使う場合は warp_manage_split_tunnel = false にして、除外リストをダッシュボードで調整してください。"
    }
  }
}

# -----------------------------------------------------------------------------
# 3. デバイス登録の許可ポリシー
#    これが無いと WARP クライアントは組織に登録できない。
#    NOTE: 登録時点ではデバイスポスチャを条件にできない（Cloudflare の制約）。
# -----------------------------------------------------------------------------
resource "cloudflare_zero_trust_access_policy" "warp_enrollment" {
  count = local.cloudflare_access_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "warp-enrollment"
  decision   = "allow"

  include = [
    for email in var.canine_admin_emails : {
      email = {
        email = email
      }
    }
  ]

  session_duration = "24h"
}

resource "cloudflare_zero_trust_access_application" "warp_enrollment" {
  count = local.cloudflare_access_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "WARP enrollment"
  type       = "warp"

  auto_redirect_to_identity = true
  session_duration          = "24h"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.warp_enrollment[0].id
    precedence = 1
  }]
}

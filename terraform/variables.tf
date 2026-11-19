# =============================================================================
# プロジェクト
# =============================================================================

variable "project_id" {
  type        = string
  description = "The GCP project ID"
  default     = "wax100"
}

variable "region" {
  type        = string
  description = "The GCP region"
  default     = "asia-northeast1"
}

variable "zone" {
  type        = string
  description = "The GCP zone"
  default     = "asia-northeast1-a"
}

variable "cluster_name" {
  type        = string
  description = "Name of the GKE cluster"
  default     = "wax100-platform"
}

# =============================================================================
# ネットワーク
# =============================================================================

variable "vpc_name" {
  type        = string
  description = "Name of the VPC network."
  default     = "wax100-vpc"
}

variable "subnet_main_name" {
  type        = string
  description = "Name of the subnet the GKE nodes live in."
  default     = "wax100-subnet"
}

variable "subnet_main_cidr" {
  type        = string
  description = "Primary range of the node subnet. Must not overlap pods_cidr, services_cidr, private_services_address/20 or master_ipv4_cidr_block."
  default     = "10.0.0.0/22"
}

variable "pods_cidr" {
  # NOTE: ingress-nginx の proxy-real-ip-cidr（components/infrastructure/nginx-ingress/base/kustomization.yaml）
  #       にも同じ値を書いている。変えるときは両方直す（hack/check-backup-consistency.sh が照合する）。
  type        = string
  description = "Secondary range for Pods (GKE alias IPs)."
  default     = "10.4.0.0/14"
}

variable "services_cidr" {
  type        = string
  description = "Secondary range for Services (GKE alias IPs)."
  default     = "10.8.0.0/20"
}

variable "private_services_address" {
  type = string
  # Cloud SQL 用 Private Services Access の予約レンジの開始アドレス (/20)。
  # メインサブネット 10.0.0.0/22、Pod 10.4.0.0/14、Service 10.8.0.0/20、
  # コントロールプレーン 172.16.0.0/28 と重ならないこと。
  # NOTE: アプリの Pod からこのレンジへの外向き通信を Kyverno が遮断している
  #       （addons/kyverno/base/clusterpolicy-environment-isolation.yaml の except）。
  #       変えるときは両方直す（hack/check-backup-consistency.sh が照合する）。
  description = "Start address of the /20 range reserved for Private Services Access (Cloud SQL)."
  default     = "10.16.0.0"
}

# =============================================================================
# コントロールプレーンへの到達
# =============================================================================

variable "cluster_operator_members" {
  type        = list(string)
  description = "IAM members granted roles/container.developer (includes container.clusters.connect) so they can reach the control plane's DNS endpoint with kubectl. e.g. [\"user:me@example.com\", \"serviceAccount:ci@project.iam.gserviceaccount.com\"]"
  default     = []

  validation {
    condition     = alltrue([for m in var.cluster_operator_members : can(regex("^(user|serviceAccount|group|principal|principalSet):\\S+$", m))])
    error_message = "cluster_operator_members は user: / serviceAccount: / group: / principal: / principalSet: の後ろに空白を含まない識別子を付けた IAM メンバーだけを指定してください（allUsers / allAuthenticatedUsers は不可）。"
  }
}

variable "enable_dns_endpoint_external" {
  type        = bool
  description = "Allow user traffic to the control plane's DNS-based endpoint from outside Google Cloud. This is how admins reach kubectl; authorization is IAM (container.clusters.connect), not network."
  default     = true
}

variable "private_control_plane_only" {
  type        = bool
  description = "Disable the control plane's external IP endpoint. Admin access then goes through the DNS-based endpoint, authorized by IAM."
  default     = true
}

variable "master_ipv4_cidr_block" {
  type        = string
  description = "CIDR for the GKE control plane's private (IP) endpoint, reachable from inside the VPC."
  default     = "172.16.0.0/28"
}

variable "master_authorized_cidrs" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "CIDRs allowed to reach the control plane. Empty means no allowlisted source beyond GKE's own ranges (nodes, Pods, Services) and internal VPC addresses."
  default     = []
}

# =============================================================================
# ノードプール
# =============================================================================

# system-pool は通常 VM を常時 1 台動かす（cloudflared / ingress-nginx も 1 本ずつ同居）。
# e2-small は不可: 構築直後、GKE の部品だけで 3 台（上限）に増え、メモリ使用率は 68〜101%。
# Config Sync の部品が載れず Pending になり、それを platform-pool へ移す Kyverno も入らなかった。
variable "system_pool_machine_type" {
  type        = string
  description = "Machine type for the on-demand system pool (kube-system, cloudflared, ingress-nginx)."
  default     = "e2-medium"
}

variable "platform_pool_machine_type" {
  type        = string
  description = "Machine type for the pool that runs platform components (Canine, Kyverno, ESO, Reloader, promotion/backup jobs). cloudflared and ingress-nginx run on the system pool."
  default     = "e2-custom-2-4096"
}

variable "platform_pool_max_nodes" {
  type        = number
  description = "Maximum node count for the platform pool. Kept small on purpose: a single pool lets the autoscaler consolidate, which it cannot do across several pools."
  default     = 3
}

variable "apps_pool_machine_type" {
  type        = string
  description = "Machine type for the node pool that runs Canine-deployed applications"
  default     = "e2-medium"
}

variable "apps_pool_max_nodes" {
  type        = number
  description = "Maximum node count for the apps pool (scales down to 0 when idle)"
  default     = 3
}

variable "readonly_viewer_enabled" {
  type        = bool
  description = "Create the read-only service account (claude-readonly) used to inspect the cluster from Claude Code's cloud environment (opt-in via terraform.tfvars)"
  default     = false
}

variable "build_pool_machine_type" {
  type        = string
  description = "Machine type for the isolated pool that runs Canine's BuildKit builders (privileged)."
  default     = "e2-standard-2"
}

variable "build_pool_max_nodes" {
  type        = number
  description = "Maximum node count for the build pool. The builder is a long-running Deployment, so one node stays up while Build Cloud is installed."
  default     = 1
}

# =============================================================================
# データベース（Canine 用の Cloud SQL）
# =============================================================================

variable "db_instance_name" {
  type        = string
  description = "Name of the Cloud SQL for PostgreSQL instance used by Canine."
  default     = "wax100-db"
}

variable "db_tier" {
  type        = string
  description = "Cloud SQL tier for the Canine PostgreSQL instance."
  # 稼働中のインスタンスに合わせて最安の db-f1-micro (0.6 GiB)。
  # Canine の web + worker が不安定になったら db-g1-small 以上へ上げる（変更時は再起動が入る）。
  # NOTE: 共有コア (db-f1-micro / db-g1-small) は Cloud SQL の SLA 対象外で、
  #       Google は本番利用を推奨していない。可用性重視なら db-custom-1-3840 以上へ。
  default = "db-f1-micro"
}

variable "bucket_soft_delete_days" {
  type        = number
  description = "Days that deleted objects in the workload bucket (storage.tf) stay recoverable (GCS soft delete, integer 7-90)."
  default     = 30

  validation {
    condition     = var.bucket_soft_delete_days >= 7 && var.bucket_soft_delete_days <= 90 && floor(var.bucket_soft_delete_days) == var.bucket_soft_delete_days
    error_message = "GCS のソフト削除の保持期間は 7〜90 の整数日です。"
  }
}

# =============================================================================
# 通知（アラート）
# =============================================================================

variable "alert_email" {
  type        = string
  description = "Email address notified when a backup Job in the infra namespace fails (monitoring.tf). Empty creates no email channel; the alert policy still opens incidents in the Cloud Console."
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email は空にするか、メールアドレスの形（example@example.com）で指定してください。"
  }
}

# =============================================================================
# Canine
# =============================================================================

variable "canine_hostname" {
  type        = string
  description = "Public hostname served through Cloudflare Tunnel for the Canine UI."
  default     = "canine.wax100.io"
}

variable "dashboard_hostname" {
  type        = string
  description = "Public hostname served through Cloudflare Tunnel for the Headlamp dashboard."
  default     = "dashboard.wax100.io"
}

variable "backup_hostname" {
  type        = string
  description = "Public hostname served through Cloudflare Tunnel for the Backrest UI."
  default     = "backup.wax100.io"
}

variable "canine_admin_emails" {
  type        = list(string)
  description = "Email addresses allowed through Cloudflare Access to the Canine UI, Headlamp and Backrest. Set in terraform.tfvars (not committed). Empty is accepted, but once Cloudflare tunnel is enabled, apply stops at the precondition in cloudflare-tunnel.tf unless both canine_admin_emails and cloudflare_access_team_name are set."
  default     = []

  validation {
    condition     = alltrue([for e in var.canine_admin_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "canine_admin_emails には example@example.com の形のメールアドレスだけを指定してください。"
  }
}

# =============================================================================
# Cloudflare
# =============================================================================

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID (32 lowercase hex). Set in terraform.tfvars (not committed). Empty creates no Cloudflare resources at all, which is only for the first apply, before cloudflare-api-token has a version. A check block warns while it is empty."
  default     = ""

  validation {
    condition     = var.cloudflare_account_id == "" || can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id は空にするか、32 文字の小文字の 16 進数で指定してください。"
  }
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare Zone ID (32 lowercase hex) for the domain. Set in terraform.tfvars (not committed). Empty skips the tunnel, DNS records and zone settings. Access is still created if cloudflare_account_id, canine_admin_emails and cloudflare_access_team_name are set. A check block warns while it is empty."
  default     = ""

  validation {
    condition     = var.cloudflare_zone_id == "" || can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id は空にするか、32 文字の小文字の 16 進数で指定してください。"
  }
}

# Cloudflare の無料の証明書は 1 階層目 (*.wax100.io) までしか効かないため、
# apps.wax100.io のような 1 段深いドメインにはしない。
variable "apps_domain" {
  type        = string
  description = "Wildcard domain that routes to ingress-nginx. Apps are published at <app>.<apps_domain>."
  default     = "wax100.io"
}

variable "cloudflare_manage_tunnel" {
  type        = bool
  description = "Create the Cloudflare Tunnel with Terraform and write its token to Secret Manager. Set to false to use an existing tunnel via cloudflare_tunnel_id."
  default     = true
}

variable "cloudflare_tunnel_id" {
  type        = string
  description = "Existing Cloudflare Tunnel ID. Only used when cloudflare_manage_tunnel = false."
  default     = ""
}

# 既定は true。cloudflare-api-token には「Zone / Zone Settings: Edit」が必須で、
# 無いと apply が cloudflare_zone_setting で失敗する（false にすればこの 3 つを作らずに済む）。
# ゾーン全体に効くので、同じゾーンで HTTP だけの別サイトを動かしているなら false にする（cloudflare-zone.tf）。
variable "cloudflare_manage_zone_security" {
  type        = bool
  description = "Manage the zone's Always Use HTTPS, minimum TLS version (1.2) and HSTS with Terraform (cloudflare-zone.tf). On by default. The cloudflare-api-token must include 'Zone / Zone Settings: Edit', otherwise apply fails on these resources. These settings are zone-wide, so they also apply to hostnames this platform does not serve: set to false if the zone serves a plain-HTTP site."
  default     = true
}

variable "cloudflare_access_team_name" {
  type        = string
  description = "Cloudflare Zero Trust team name (<team>.cloudflareaccess.com). Set in terraform.tfvars (not committed). cloudflared validates the Access JWT against it."
  default     = ""

  validation {
    condition     = var.cloudflare_access_team_name == "" || can(regex("^[a-z0-9-]+$", var.cloudflare_access_team_name))
    error_message = "cloudflare_access_team_name は空にするか、小文字英数字とハイフンのみで指定してください。"
  }
}

variable "cloudflare_access_allowed_idps" {
  type = list(string)
  # Cloudflare Access の ID プロバイダ (IdP) の ID。空なら Zero Trust に登録済みの全 IdP を許可し、
  # ログイン画面で選ばせる。1 件だけ指定したときに限り、選択画面を飛ばしてその IdP へ直接送る
  # (Instant Auth / auto_redirect_to_identity)。Cloudflare はこれを IdP が 1 つの場合の設定としている。
  description = "Cloudflare Access identity provider IDs allowed for the Canine app. Exactly one enables instant auth."
  default     = []
}

# =============================================================================
# GitOps (Cloud Build / Config Sync)
# =============================================================================

variable "github_account_name" {
  type        = string
  description = "Name of the Cloud Build 2nd-gen GitHub connection (created in the console before apply)."
  default     = "waxsd100"
}

variable "github_repo_platform" {
  type        = string
  description = "Name of the repository linked under that connection (the k8s platform manifests)."
  default     = "waxsd100-k8s-platform"
}

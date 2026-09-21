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

# system-pool は通常 VM を常時 2 台動かすため、クラスタで最大の固定費になる。
# e2-small（2 GiB）は GKE の予約（25% + 退避用 100MiB）を引くと Pod に使えるのが約 1.4 GiB/台。
# kube-dns・konnectivity・metrics-server・GKE の DaemonSet は Spot プールの taint を
# 許容しないため、cloudflared / ingress-nginx と一緒にここに載る。
# 重い Config Sync は Kyverno で platform-pool へ移している（clusterpolicy-config-sync-placement.yaml）。
# CPU は継続 0.5 vCPU（バーストは約 60 秒）しか無いので、構築後に CPU も確認すること。
# Dataplane V2 の anetd も各ノードに載る（gke.tf の datapath_provider）。
# 足りなければオートスケーラが 3 台目を足す。3 台の e2-small でも 2 台の e2-medium より安いが、
# 上限（3 台）に張り付くと余裕が無くなり、ノード障害時に入口の Pod が載れなくなる。
# 常時 3 台になるなら "e2-medium" に戻す。変更は in-place（max_surge=1 で 1 台ずつ入れ替え）。
variable "system_pool_machine_type" {
  type        = string
  description = "Machine type for the on-demand system pool (kube-system, cloudflared, ingress-nginx)."
  default     = "e2-small"
}

variable "platform_pool_machine_type" {
  type        = string
  description = "Machine type for the pool that runs platform components (Canine, Kyverno, ESO, Reloader, promotion/snapshot jobs). cloudflared and ingress-nginx run on the system pool."
  default     = "e2-standard-2"
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
# Canine
# =============================================================================

variable "canine_db_tier" {
  type        = string
  description = "Cloud SQL tier for the Canine control plane database"
  # db-f1-micro は最安 (0.6 GiB)。Canine の web + worker を安定運用するなら
  # db-g1-small 以上を推奨。
  # NOTE: 共有コア (db-f1-micro / db-g1-small) は Cloud SQL の SLA 対象外で、
  #       Google は本番利用を推奨していない。可用性重視なら db-custom-1-3840 以上へ。
  default = "db-g1-small"
}

variable "canine_hostname" {
  type        = string
  description = "Public hostname served through Cloudflare Tunnel for the Canine UI."
  default     = "canine.wax100.io"
}

variable "canine_admin_emails" {
  type        = list(string)
  description = "Email addresses allowed through Cloudflare Access to the Canine UI."
  default     = []
}

# =============================================================================
# Cloudflare
# =============================================================================

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID. Leave empty to skip the Cloudflare Access configuration."
  default     = ""
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare Zone ID for the domain. Leave empty to skip DNS management."
  default     = ""
}

variable "apps_domain" {
  type        = string
  description = "Wildcard domain that routes to ingress-nginx. Apps are published at <app>.<apps_domain>."
  default     = "apps.wax100.io"
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

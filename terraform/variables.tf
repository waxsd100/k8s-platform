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

# Network related variables
variable "vpc_name" {
  type    = string
  default = "wax100-vpc"
}

variable "subnet_main_name" {
  type    = string
  default = "wax100-subnet"
}

variable "subnet_lb_name" {
  type    = string
  default = "wax100-subnet-lb"
}

variable "subnet_main_cidr" {
  type    = string
  default = "10.0.0.0/22"
}

variable "subnet_lb_cidr" {
  type    = string
  default = "10.2.0.0/24"
}

variable "private_control_plane_only" {
  type        = bool
  description = "Disable the control plane's external endpoint. Admin access then goes through Cloudflare WARP -> cloudflared private network routing."
  default     = true
}

variable "master_authorized_cidrs" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "CIDRs allowed to reach the control plane. Empty means no allowlisted source beyond GKE's own ranges (nodes, Pods, Services) and internal VPC addresses."
  default     = []
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

variable "canine_db_tier" {
  type        = string
  description = "Cloud SQL tier for the Canine control plane database"
  # db-f1-micro は最安 (0.6 GiB)。Canine の web + worker を安定運用するなら
  # db-g1-small 以上を推奨。
  # NOTE: 共有コア (db-f1-micro / db-g1-small) は Cloud SQL の SLA 対象外で、
  #       Google は本番利用を推奨していない。可用性重視なら db-custom-1-3840 以上へ。
  default = "db-g1-small"
}

variable "github_account_name" {
  type        = string
  description = "GitHub account or Developer Connect connection name"
  default     = "waxsd100"
}

variable "github_repo_platform" {
  type        = string
  description = "GitHub repository name for the k8s platform manifests"
  default     = "waxsd100-k8s-platform"
}

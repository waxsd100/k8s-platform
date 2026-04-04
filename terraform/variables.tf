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
  type        = string
  default     = "wax100-vpc"
}

variable "subnet_main_name" {
  type        = string
  default     = "wax100-subnet"
}

variable "subnet_lb_name" {
  type        = string
  default     = "wax100-subnet-lb"
}

variable "subnet_main_cidr" {
  type        = string
  default     = "10.0.0.0/22"
}

variable "subnet_lb_cidr" {
  type        = string
  default     = "10.2.0.0/24"
}

terraform {
  required_version = ">= 1.5.0"

  # state には Cloudflare API トークン、トンネルトークン、DB パスワード、
  # SECRET_KEY_BASE が平文で入る。ローカルファイルに置いたままにしない。
  # state-bucket.tf のバケットを apply したあと、ここのコメントを外して
  #   terraform init -migrate-state
  # を実行する。
  # backend "gcs" {
  #   bucket = "wax100-tfstate"
  #   prefix = "platform"
  # }

  required_providers {
    google = {
      source = "hashicorp/google"
      # 8.x。DNS ベースエンドポイント (control_plane_endpoints_config) は 6 系から。

      version = "~> 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Cloudflare 用。API トークンは Secret Manager から読む。
# var.cloudflare_account_id が未設定のときは Cloudflare のリソースが 1 つも
# 作られないため、トークンが無くても apply できる。
#
# 必要な権限: Account / Cloudflare Tunnel: Edit, Account / Zero Trust: Edit,
#             Account / Access: Apps and Policies: Edit, Zone / DNS: Edit
locals {
  # Cloudflare のリソースを作るかどうか。API トークンを読みに行く条件でもある。
  cloudflare_enabled = var.cloudflare_account_id != ""
}

data "google_secret_manager_secret_version" "cloudflare_api_token" {
  count   = local.cloudflare_enabled ? 1 : 0
  secret  = google_secret_manager_secret.cloudflare_api_token.secret_id
  project = var.project_id
}

provider "cloudflare" {
  api_token = local.cloudflare_enabled ? data.google_secret_manager_secret_version.cloudflare_api_token[0].secret_data : null
}

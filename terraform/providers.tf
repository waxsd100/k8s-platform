terraform {
  required_version = ">= 1.5.0"

  # state には Cloudflare API トークン、トンネルトークン、DB パスワード、
  # SECRET_KEY_BASE が平文で入る。ローカルファイルには置かず、GCS に置く。
  # バケットは state-bucket.tf（新規構築時の作り方は docs/GKE_SETUP_GUIDE.md の 2.1）。
  # NOTE: ここをコメントアウトに戻すと、Terraform は空のローカル state を見て
  #       すべてを作り直そうとする。
  backend "gcs" {
    bucket = "wax100-tfstate"
    prefix = "platform"
  }

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
# var.cloudflare_account_id を空にすると Cloudflare のリソースが 1 つも
# 作られないため、トークンが無くても apply できる（初回構築用）。
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

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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

# Cloudflare Access (Zero Trust) 用。API トークンは Secret Manager から読む。
# var.cloudflare_account_id が未設定のときは cloudflare-access.tf の
# リソースが作られないため、トークンが無くても apply できる。
provider "cloudflare" {
  api_token = local.cloudflare_access_enabled ? data.google_secret_manager_secret_version.cloudflare_api_token[0].secret_data : null
}

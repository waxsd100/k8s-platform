# =============================================================================
# Google Cloud API の有効化
# =============================================================================
# disable_on_destroy = false: destroy やリストからの削除で API を止めない
# （止めると同じ API を使う手作業のリソースまで巻き込むため）。
locals {
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "gkehub.googleapis.com",                 # Config Syncのために必要
    "anthosconfigmanagement.googleapis.com", # Config Syncのために必要
    "iam.googleapis.com",                    # ServiceAccount の作成・IAM バインディングに必要
    "iamcredentials.googleapis.com",         # Workload Identity の SA 借用・トークン発行に必要
    "sts.googleapis.com",                    # Workload Identity Federation のトークン交換に必要
    "cloudresourcemanager.googleapis.com",   # data.google_project / プロジェクト IAM に必要
    "storage.googleapis.com",                # Terraform state バケットに必要
    "dns.googleapis.com",                    # Cloud DNS for GKE（クラスタ内の名前解決）に必要
    "logging.googleapis.com",                # バックアップ Job 失敗の通知（monitoring.tf）に必要
    "monitoring.googleapis.com"              # 同上（alert policy と通知チャネル）
  ]
}

resource "google_project_service" "enabled_apis" {
  for_each                   = toset(local.services)
  project                    = var.project_id
  service                    = each.key
  disable_dependent_services = false
  disable_on_destroy         = false
}

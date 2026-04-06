# ==== Google Cloud Storage (GCS) ====
# Production環境の画像アセット用（ステートレス・ダウンタイム回避のため）

resource "google_storage_bucket" "blog_images_prod" {
  name          = "${var.project_id}-blog"
  location      = var.region
  storage_class = "STANDARD"

  # ダウンタイムやインシデント時の再構築を考慮し、誤削除保護は付けつつ強制破棄可能にする
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }
}

# Workload Identity を利用する Blog 用 Service Account に、バケットの読み書き権限を付与
resource "google_storage_bucket_iam_member" "blog_sa_storage_admin" {
  bucket = google_storage_bucket.blog_images_prod.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.blog_sa.email}"
}

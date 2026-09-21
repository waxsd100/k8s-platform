# =============================================================================
# クラスタ内 DB のバックアップ先（GCS）
#
# アプリの DB は dev も本番もクラスタ内（公式イメージの postgres / mysql の StatefulSet）に置く。
# CronJob db-backup（components/infrastructure/db-backup）が毎日 pg_dumpall / mysqldump を取り、
# このバケットに <Namespace>/<Pod>/<UTC 日時>.sql.gz で置く。
#
# 書き込み専用: CronJob の ServiceAccount には objectCreator だけを付ける。
# 読み出し・上書き・削除はできないので、クラスタが乗っ取られてもバックアップは消せない。
# 古いものはライフサイクルで消える（var.db_backup_retention_days）。
# =============================================================================

resource "google_storage_bucket" "db_backups" {
  name     = "${var.project_id}-db-backups"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = var.db_backup_retention_days
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

# Workload Identity Federation for GKE の直接プリンシパル（secrets.tf の ESO と同じ方式）。
# GSA もアノテーションも要らない。
resource "google_storage_bucket_iam_member" "db_backup_writer" {
  bucket = google_storage_bucket.db_backups.name
  role   = "roles/storage.objectCreator"
  member = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.project.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/infra/sa/db-backup",
  ])
}

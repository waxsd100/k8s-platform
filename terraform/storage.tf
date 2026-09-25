# =============================================================================
# GKE のワークロードが使う GCS バケット（gs://wax100-platform の 1 つだけ。クラスタ名と同じ）
#
# restic のリポジトリ専用（backup.tf）。バケットの直下がそのままリポジトリになる。
# 権限はバケット単位で付けるので、別の用途ができたら同じバケットに相乗りさせず、
# バケットを分ける（相乗りさせると restic の ServiceAccount がそのデータも読み書き・削除できる）。
#
# NOTE: Terraform の state 置き場（state-bucket.tf の <project>-tfstate）は
#       Terraform 自身のもので、クラスタからは使わないので別に置く。
#
# 年齢で消すライフサイクルは付けない（restic のパックは古いものも参照され続ける）。
# 誤って消したときのために、ソフト削除で var.bucket_soft_delete_days 日は戻せる
# （短縮・無効化には storage.buckets.update が要り、クラスタには渡していない）。
# =============================================================================

resource "google_storage_bucket" "main" {
  name     = "${var.project_id}-platform"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  soft_delete_policy {
    retention_duration_seconds = var.bucket_soft_delete_days * 86400
  }

  # 中身があるうちは terraform destroy で消さない（バックアップごと消す事故を防ぐ）
  force_destroy = false

  depends_on = [google_project_service.enabled_apis]
}

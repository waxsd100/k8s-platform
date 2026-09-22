# =============================================================================
# 共有の Cloud SQL for PostgreSQL インスタンス
#
# Canine だけでなく、今後のアプリも同じインスタンスに DB を作って使う前提で、
# インスタンスは用途名ではなくプロジェクト名で持つ（wax100-db）。
# 各アプリは自分の DB とユーザーを持つ（Canine は canine.tf の canine_production / canine）。
#
# NOTE: 1 つのインスタンスを共有するので、メンテナンス・再起動・ディスク・接続数の上限は
#       全アプリで共通になる。重いアプリが増えたら tier を上げるか、インスタンスを分ける。
#
# ネットワークは private-services.tf の Private Services Access（VPC ピアリング）を使う。
# =============================================================================

resource "google_sql_database_instance" "main" {
  name             = var.db_instance_name
  database_version = "POSTGRES_16"
  region           = var.region

  # NOTE: 誤削除防止。削除時は先に両方 false にして apply する
  #   deletion_protection         : terraform destroy を止める
  #   deletion_protection_enabled : コンソールや gcloud からの削除を止める
  deletion_protection = true

  settings {
    deletion_protection_enabled = true

    tier                  = var.db_tier
    edition               = "ENTERPRISE"
    availability_type     = "ZONAL" # シングルゾーン（コスト最適化）
    disk_type             = "PD_SSD"
    disk_size             = 10
    disk_autoresize       = true
    disk_autoresize_limit = 50

    # プライベート IP のみ（パブリック IP 無効）
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc_network.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true    # PostgreSQL は WAL ベースの PITR
      start_time                     = "03:00" # UTC 03:00 (JST 12:00)
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
      }
    }

    maintenance_window {
      day          = 7  # 日曜日
      hour         = 20 # UTC 20:00 = JST 05:00
      update_track = "stable"
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

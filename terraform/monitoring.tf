# =============================================================================
# バックアップ Job の失敗通知
#
# GKE が出す Kubernetes イベント（Job の BackoffLimitExceeded など）を Cloud Logging の
# events ログから拾い、失敗したバックアップ Job があれば知らせる。
#   - alert_email を指定していれば、そのアドレスにメールが届く
#   - Cloud Console の「インシデント」には alert_email の有無にかかわらず出る
#
# 対象: components/infrastructure/backup/base の CronJob（db-backup / manifest-backup /
#       pvc-backup / restic-maintenance）。Job 名は CronJob 名に時刻が付いたもの。
#       pvc-backup が PVC ごとに作る Job（pvcb-...）は名前が一致しないが、
#       その失敗で親の pvc-backup Job も失敗するので、そちらで検知できる。
#
# 限界: 失敗した実行だけを検知する。実行そのものが始まらなかった場合は検知できない
#       （CronJob の suspend、クラスタの停止、CronJob の削除など）。
#       それを拾うには「一定時間内に成功した Job が無い」を見る別の仕組みが要る。
#
# 手順は docs/BACKUP.md。
# =============================================================================

resource "google_monitoring_notification_channel" "backup_alert_email" {
  count = var.alert_email != "" ? 1 : 0

  display_name = "backup-job-failure-email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_monitoring_alert_policy" "backup_job_failed" {
  display_name = "Backup Job failed (infra)"
  combiner     = "OR"
  severity     = "ERROR"

  notification_channels = var.alert_email != "" ? [google_monitoring_notification_channel.backup_alert_email[0].name] : []

  conditions {
    display_name = "Backup Job reported a failure event"

    # ログの形（logName / jsonPayload の項目名）は GKE のイベントログの想定。
    # 実ログでは未確認なので、最初の失敗が届くかは一度確かめること。
    condition_matched_log {
      filter = <<-EOT
        logName:"logs/events"
        jsonPayload.involvedObject.kind="Job"
        jsonPayload.involvedObject.namespace="infra"
        jsonPayload.involvedObject.name=~"^(db-backup|manifest-backup|pvc-backup|restic-maintenance)-"
        jsonPayload.reason=("BackoffLimitExceeded" OR "DeadlineExceeded" OR "Failed")
      EOT
    }
  }

  alert_strategy {
    # 同じ失敗が続いても 1 時間に 1 回までにする
    notification_rate_limit {
      period = "3600s"
    }
    # 1 日ログが来なければインシデントを閉じる
    auto_close = "86400s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      infra namespace のバックアップ Job が失敗しました（db-backup / manifest-backup / pvc-backup / restic-maintenance）。

      確認すること:

      1. 失敗した Job と Pod を見る: `kubectl get jobs -n infra` と `kubectl logs -n infra job/<job名>`
      2. 理由の意味: `BackoffLimitExceeded` は再試行の上限に達した、`DeadlineExceeded` は制限時間を超えた、という意味です。
      3. 手順、復旧の方法、リポジトリの確かめ方は docs/BACKUP.md を見てください。
    EOT
  }

  depends_on = [google_project_service.enabled_apis]
}

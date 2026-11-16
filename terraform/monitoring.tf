# =============================================================================
# バックアップ Job の失敗通知
#
# GKE が出す Kubernetes イベント（Job の BackoffLimitExceeded など）を Cloud Logging の
# events ログから拾い、失敗したバックアップ Job があれば知らせる。
#   - alert_email を指定していれば、そのアドレスにメールが届く
#   - Cloud Console の「インシデント」には alert_email の有無にかかわらず出る
#
# 対象: components/infrastructure/backup/base の CronJob（db-backup / manifest-backup /
#       pvc-backup / restic-maintenance）と、その監視の backup-watchdog。Job 名は CronJob 名に時刻が付いたもの。
#       pvc-backup が PVC ごとに作る Job（pvcb-...）は名前が一致しないが、
#       その失敗で親の pvc-backup Job も失敗するので、そちらで検知できる。
#
# backup-watchdog（watchdog.yaml）は 6 時間ごとに 4 つの CronJob を見て、一時停止中・作られていない・
# 長く成功していない、のどれかがあれば自分の Job を失敗させる。「実行されなかった」も、
# このアラートでは「backup-watchdog の Job が失敗した」として届く。
#
# 限界（残るもの）:
#   - watchdog 自身が動かないと何も届かない（CronJob を削除・一時停止、Namespace やクラスタの停止）。
#     watchdog の一時停止は Headlamp からはできない（watchdog.yaml）が、Git か kubectl では止められる。
#   - 上の 4 つ以外（dev の PVC など）は見ていない。
#   - 「成功した」は CronJob の status.lastSuccessfulTime で判断する（Kubernetes 1.21 以降の機能）。
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
        jsonPayload.involvedObject.name=~"^(db-backup|manifest-backup|pvc-backup|restic-maintenance|backup-watchdog)-"
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
      infra namespace のバックアップ Job が失敗しました（db-backup / manifest-backup / pvc-backup / restic-maintenance / backup-watchdog）。

      Job 名が `backup-watchdog-` で始まる場合は、バックアップが取られていない状態です。
      監視（6 時間ごと）が、次のどれかを見つけました: CronJob が一時停止中（spec.suspend）、CronJob が無い、
      最後の成功が上限より古い（一度も成功していなければ作成からの時間）。

      確認すること:

      1. 失敗した Job と Pod を見る: `kubectl get jobs -n infra` と `kubectl logs -n infra job/<job名>`
         （backup-watchdog の場合は、ログの `NG` の行に止まっている CronJob の名前と理由が出ます）
      2. 理由の意味: `BackoffLimitExceeded` は再試行の上限に達した、`DeadlineExceeded` は制限時間を超えた、という意味です。
      3. 一時停止中なら再開します（Headlamp の Resume。backup-watchdog 以外の 4 つ）。Git の定義と食い違っていれば Git 側を直します。
      4. 手順、復旧の方法、リポジトリの確かめ方は docs/BACKUP.md を見てください。
    EOT
  }

  depends_on = [google_project_service.enabled_apis]
}

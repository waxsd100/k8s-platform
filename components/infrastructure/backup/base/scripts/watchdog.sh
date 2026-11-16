#!/bin/bash
# バックアップの CronJob が「取られていない」状態を見つける（6 時間ごと）。
#   - CronJob が無い
#   - spec.suspend が true（一時停止中。Headlamp の Suspend も含む）
#   - 最後の成功（status.lastSuccessfulTime）が上限より古い
#     （一度も成功していなければ creationTimestamp から数える。作ってすぐの CronJob は見ない）
# どれか 1 つでも当たると終了コードが 1 になり、Job が失敗する。その失敗を
# terraform/monitoring.tf の Job 失敗アラートが拾う（Job 名は backup-watchdog-<時刻>）。
# 見るのは kubectl logs -n infra job/<Job 名> の NG の行。判定の中身は watchdog.rb。
#
# ----------------------------------------------------------------------------
# しきい値の表（下の watched）。CronJob のスケジュールや activeDeadlineSeconds を変えたら必ず見直すこと。
# 上限 = 間隔 + 最長の実行時間（activeDeadlineSeconds）+ 余裕 1 時間 を、時間で切り上げたもの
# （restic-maintenance だけは日単位にして 8 日）。
# 正常なら、連続する 2 回の成功の間隔は「間隔 + 最長の実行時間」を超えない。それより長く成功が無ければ止まっている。
#
#   CronJob               スケジュール（UTC / JST）              最長の実行時間            上限
#   db-backup             毎日 18:30 UTC / 03:30 JST              50 分（3000）             26 時間
#   manifest-backup       毎日 18:30 UTC / 03:30 JST              30 分（1800）             26 時間
#   pvc-backup            毎日 19:30 UTC / 04:30 JST              4 時間（14400）           29 時間
#   restic-maintenance    毎週日 03:00 UTC / 12:00 JST            6 時間（21600）           8 日（192 時間）
#
# 上限の計算: db-backup = 24 + 0.8 + 1 → 26、manifest-backup = 24 + 0.5 + 1 → 26、
#             pvc-backup = 24 + 4 + 1 → 29、restic-maintenance = 168 + 6 + 1 → 175 → 余裕を見て 8 日。
# ----------------------------------------------------------------------------
set -uo pipefail
scripts_dir=${SCRIPTS_DIR:-/scripts}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh disable=SC1091
. "${scripts_dir}/lib.sh"

# 名前=上限（時間）。上の表と揃えること
watched=(
  db-backup=26
  manifest-backup=26
  pvc-backup=29
  restic-maintenance=192
)

# テスト用。設定されているときだけ、現在時刻の代わりに使う（RFC3339。通常は未設定）
now=${WATCHDOG_NOW:-}

cronjobs=$(kubectl get cronjobs -n infra -o json) || {
  error "infra の CronJob の一覧を取れませんでした（kubectl が失敗。上の行と権限を見る）"
  finish
}

printf '%s\n' "${cronjobs}" | ruby "${scripts_dir}/watchdog.rb" "${now}" "${watched[@]}"
rc=$?
case "${rc}" in
  0) done_count=${#watched[@]} ;;
  1) error "止まっているバックアップがあります（上の NG の行を見る）" ;;
  *) error "判定できませんでした（終了コード ${rc}。上のメッセージを見る）" ;;
esac
finish

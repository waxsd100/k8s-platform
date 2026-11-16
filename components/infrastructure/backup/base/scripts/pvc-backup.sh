#!/bin/bash
# 本番の PVC のファイルを restic で送る。PVC ごとに 1 スナップショット: パス /pvc/<ns>/<pvc>、タグ pvc,<ns>
#
# PVC ごとの流れ（アプリの Pod には触らない）:
#   1. アプリの Namespace で VolumeSnapshot を取る
#   2. 同じスナップショットを infra に取り込み、一時ディスクを作る
#   3. 一時ディスクを読み取り専用でマウントした Job（pvc-backup-mover）が restic で送る
#   4. Job・一時ディスク・スナップショットを消す
# 作るリソースの中身は pvc-objects.rb、対象の決め方は targets.rb。
set -uo pipefail
scripts_dir=${SCRIPTS_DIR:-/scripts}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh disable=SC1091
. "${scripts_dir}/lib.sh"

work=${WORK_DIR:-/work}
mkdir -p "${work}"
ts=$(date -u +%Y%m%d%H%M)
label='wax100.io/pvc-backup=true'

current_ns=""
current_name=""
wait_pid=""
shutting_down=0

# フォアグラウンド実行中は Bash が SIGTERM/SIGINT の trap 実行をコマンド終了まで遅らせるため、
# 長時間待つ処理（kubectl wait・sleep）はバックグラウンド + wait で即座に割り込めるようにする。
# wait 中の trap 出力が消えないよう、標準出力のリダイレクトは子プロセス側にだけ付ける。
run_interruptible_quiet() {
  "$@" < /dev/null > /dev/null &
  wait_pid=$!
  local rc=0
  wait "${wait_pid}" || rc=$?
  wait_pid=""
  return "${rc}"
}

create() {
  ruby "${scripts_dir}/pvc-objects.rb" "$@" | kubectl create -f - > /dev/null
}

wait_snapshot() {
  run_interruptible_quiet kubectl wait -n "$1" "volumesnapshot/$2" \
    --for=jsonpath='{.status.readyToUse}'=true --timeout=30m
}

# 消せなかったものは課金が続くので、黙って捨てずに警告する（次の実行の最初にも掃除する）。
# シグナル中断時（Spot 回収や期限切れ）は猶予が短いので --wait=false で削除要求だけ即座に通し、
# Finalizer の順序制御は Kubernetes 側のコントローラに任せる。
delete() {
  local out extra_args=(--timeout=5m) arg
  if [ "${shutting_down}" = "1" ]; then
    extra_args=(--wait=false)
    for arg in "$@"; do
      if [ "${arg}" = "--wait=false" ]; then
        extra_args=()
        break
      fi
    done
  fi
  out=$(kubectl delete --ignore-not-found "${extra_args[@]}" "$@" 2>&1) \
    || echo "WARN: 消せませんでした（次回の実行で消します）: kubectl delete $* : ${out}"
}

# 前回が途中で止まったときの残り物を消す
cleanup_leftovers() {
  local ns name
  delete job -n infra -l "${label}"
  delete pvc -n infra -l "${label}" --wait=false
  delete volumesnapshot -n infra -l "${label}"
  delete volumesnapshotcontent -l "${label}"
  kubectl get volumesnapshot -A -l "${label}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
    | while read -r ns name; do
      if [ -n "${ns}" ]; then
        delete volumesnapshot -n "${ns}" "${name}"
      fi
    done
}

# 1 つの PVC の後片付け（成功・失敗どちらでも呼ぶ）。消す順番に意味がある
cleanup_one() {
  local ns=$1 name=$2
  delete job -n infra "${name}"
  delete pvc -n infra "${name}" --wait=false
  delete volumesnapshot -n infra "${name}"
  # Retain なので、これを消しても元のスナップショットは消えない
  delete volumesnapshotcontent "${name}"
  # ここで GCE のスナップショットが消える（VolumeSnapshotClass が Delete）
  delete volumesnapshot -n "${ns}" "${name}"
}

# Spot 回収（SIGTERM）や activeDeadlineSeconds 超過で途中終了したときに、
# 処理中の一時ディスク・スナップショット・Job をその場で片付ける（二重実行しないよう先に空にする）。
# shellcheck disable=SC2317
cleanup_current() {
  local ns=${current_ns} name=${current_name}
  current_ns=""
  current_name=""
  if [ -n "${ns}" ] && [ -n "${name}" ]; then
    echo "中断されたため一時リソースを片付けます: ${ns}/${name}"
    cleanup_one "${ns}" "${name}" < /dev/null
  fi
}

# shellcheck disable=SC2317
on_signal() {
  local code=$1 child children=()
  shutting_down=1
  trap '' INT TERM
  if [ -n "${wait_pid}" ]; then
    if [ -r "/proc/${wait_pid}/task/${wait_pid}/children" ]; then
      read -r -a children < "/proc/${wait_pid}/task/${wait_pid}/children" 2> /dev/null || true
      for child in "${children[@]}"; do
        kill -TERM "${child}" 2> /dev/null || true
      done
    fi
    kill -TERM "${wait_pid}" 2> /dev/null || true
    wait "${wait_pid}" 2> /dev/null || true
    wait_pid=""
  fi
  cleanup_current
  exit "${code}"
}

trap cleanup_current EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# Job が完了か失敗になるまで待つ（Job 側の期限は 3 時間）
wait_job() {
  local name=$1 state
  while :; do
    state=$(kubectl get job -n infra "${name}" -o jsonpath='{.status.conditions[?(@.status=="True")].type}') || return 1
    case " ${state} " in
      *" Complete "*)
        kubectl logs -n infra "job/${name}" --tail=6
        return 0
        ;;
      *" Failed "*)
        kubectl logs -n infra "job/${name}" --tail=20
        return 1
        ;;
    esac
    run_interruptible_quiet sleep "${POLL_INTERVAL:-15}" || return 1
  done
}

backup_one() {
  local ns=$1 pvc=$2 sc=$3 name=$4 content size handle

  create source-snapshot "${name}" "${ns}" "${pvc}" || return 1
  wait_snapshot "${ns}" "${name}" || {
    echo "ERROR: スナップショットが用意できません"
    return 1
  }
  content=$(kubectl get volumesnapshot -n "${ns}" "${name}" -o jsonpath='{.status.boundVolumeSnapshotContentName}') || content=""
  size=$(kubectl get volumesnapshot -n "${ns}" "${name}" -o jsonpath='{.status.restoreSize}') || size=""
  if [ -z "${content}" ] || [ -z "${size}" ]; then
    echo "ERROR: スナップショットの情報を読めません"
    return 1
  fi
  handle=$(kubectl get volumesnapshotcontent "${content}" -o jsonpath='{.status.snapshotHandle}') || handle=""
  if [ -z "${handle}" ]; then
    echo "ERROR: スナップショットのハンドルを読めません"
    return 1
  fi

  create import "${name}" "${handle}" || return 1
  wait_snapshot infra "${name}" || {
    echo "ERROR: infra へのスナップショットの取り込みに失敗しました"
    return 1
  }
  create disk "${name}" "${size}" "${sc}" || return 1
  create mover "${name}" "${ns}" "${pvc}" || return 1
  wait_job "${name}"
}

cleanup_leftovers

if ! { kubectl get pvc -A -o json > "${work}/pvcs.json" \
  && kubectl get pods -A -o json > "${work}/pods.json" \
  && kubectl get pv -o json > "${work}/pvs.json"; }; then
  error "PVC / Pod / PV の一覧を取れませんでした"
  finish
fi
targets=$(ruby "${scripts_dir}/targets.rb" pvc "${work}/pvcs.json" "${work}/pods.json" "${work}/pvs.json") || {
  rm -f "${work}/pvcs.json" "${work}/pods.json" "${work}/pvs.json"
  error "対象を決められませんでした"
  finish
}
rm -f "${work}/pvcs.json" "${work}/pods.json" "${work}/pvs.json"

while read -r state ns pvc sc; do
  [ -n "${ns}" ] || continue
  echo "== ${ns}/${pvc}"
  case "${state}" in
    UNBOUND)
      echo "skip: まだディスクが割り当てられていません"
      continue
      ;;
    NOCSI)
      error "Persistent Disk（CSI）ではないのでスナップショットを取れません"
      continue
      ;;
  esac

  # 名前は 63 文字以内に収める（Job 名とラベルの上限）
  name="pvcb-$(printf '%s/%s' "${ns}" "${pvc}" | sha1sum | cut -c1-10)-${ts}"
  current_ns=${ns}
  current_name=${name}
  if backup_one "${ns}" "${pvc}" "${sc}" "${name}" < /dev/null; then
    echo "ok: /pvc/${ns}/${pvc}"
    done_count=$((done_count + 1))
  else
    error "${ns}/${pvc} を送れませんでした"
  fi
  cleanup_one "${ns}" "${name}" < /dev/null
  current_ns=""
  current_name=""
done <<< "${targets}"

finish

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
# shellcheck source=lib.sh
. /scripts/lib.sh

work=/work
ts=$(date -u +%Y%m%d%H%M)
label='wax100.io/pvc-backup=true'

create() {
  ruby /scripts/pvc-objects.rb "$@" | kubectl create -f - > /dev/null
}

wait_snapshot() {
  kubectl wait -n "$1" "volumesnapshot/$2" \
    --for=jsonpath='{.status.readyToUse}'=true --timeout=30m > /dev/null
}

# 消せなかったものは課金が続くので、黙って捨てずに警告する（次の実行の最初にも掃除する）
delete() {
  local out
  out=$(kubectl delete --ignore-not-found --timeout=5m "$@" 2>&1) \
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
      [ -n "${ns}" ] && delete volumesnapshot -n "${ns}" "${name}"
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
    sleep 15
  done
}

backup_one() {
  local ns=$1 pvc=$2 sc=$3 name=$4 content size handle

  create source-snapshot "${name}" "${ns}" "${pvc}" || return 1
  wait_snapshot "${ns}" "${name}" || {
    echo "ERROR: スナップショットが用意できません"
    return 1
  }
  content=$(kubectl get volumesnapshot -n "${ns}" "${name}" -o jsonpath='{.status.boundVolumeSnapshotContentName}')
  size=$(kubectl get volumesnapshot -n "${ns}" "${name}" -o jsonpath='{.status.restoreSize}')
  handle=$(kubectl get volumesnapshotcontent "${content}" -o jsonpath='{.status.snapshotHandle}')
  [ -n "${handle}" ] && [ -n "${size}" ] || {
    echo "ERROR: スナップショットの情報を読めません"
    return 1
  }

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
targets=$(ruby /scripts/targets.rb pvc "${work}/pvcs.json" "${work}/pods.json" "${work}/pvs.json") || {
  error "対象を決められませんでした"
  finish
}

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
  if backup_one "${ns}" "${pvc}" "${sc}" "${name}" < /dev/null; then
    echo "ok: /pvc/${ns}/${pvc}"
    done_count=$((done_count + 1))
  else
    error "${ns}/${pvc} を送れませんでした"
  fi
  cleanup_one "${ns}" "${name}" < /dev/null
done <<< "${targets}"

finish

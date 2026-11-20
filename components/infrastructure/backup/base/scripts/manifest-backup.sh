#!/bin/bash
# KubeVela / VelaUX の dev アプリ定義および VelaUX データストア（velaux-store）を
# 書き出し、restic で送る（dev マニフェストには Secret を含まない）。
#   1. dev マニフェスト : パス /work/manifests/<ns>.yaml、タグ manifests
#   2. velaux-store     : パス /work/velaux-store/configmaps.yaml、タグ velaux-store（暗号化保管）
#
# Config Sync 管理下（昇格済み = Git が正）と EXCLUDED_NAMESPACES は dev 対象外。
set -uo pipefail
scripts_dir=${SCRIPTS_DIR:-/scripts}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh disable=SC1091
. "${scripts_dir}/lib.sh"

work_base=${WORK_DIR:-/work}
work=${work_base}/manifests
velaux_store_ns=${VELAUX_STORE_NAMESPACE:-velaux-store}
velaux_work=${work_base}/velaux-store
excluded_namespaces=${EXCLUDED_NAMESPACES:-}
kinds=${KINDS:-applications.core.oam.dev,deployment,statefulset,daemonset,cronjob,service,ingress,configmap,pvc,hpa,serviceaccount,networkpolicy}
mkdir -p "${work}"

wait_pid=""

# shellcheck disable=SC2317
cleanup_velaux() {
  rm -rf "${velaux_work}"
}

# フォアグラウンド実行中は Bash が SIGTERM/SIGINT の trap 実行をコマンド終了まで遅らせるため、
# 長時間かかる restic 送信や velaux-store 取得はバックグラウンド + wait で実行し、
# Kubelet からの PID 1 宛て SIGTERM で即座に子プロセスを止めて一時ファイルを削除する。
# shellcheck disable=SC2317
on_signal() {
  local code=$1 child children=()
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
  cleanup_velaux
  exit "${code}"
}

snapshot_interruptible() {
  local host=$1 rc=0
  shift
  "${RESTIC}" backup --host "${host}" "$@" < /dev/null &
  wait_pid=$!
  wait "${wait_pid}" || rc=$?
  wait_pid=""
  return "${rc}"
}

trap cleanup_velaux EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

restic_ready

# 1. dev Namespace のアプリ定義（KubeVela Application と補助リソース）
if namespaces=$(kubectl get ns -l 'app.kubernetes.io/managed-by!=configmanagement.gke.io' \
  -o jsonpath='{.items[*].metadata.name}'); then
  for ns in ${namespaces}; do
    case " ${excluded_namespaces} " in *" ${ns} "*) continue ;; esac
    case "${ns}" in
      "${velaux_store_ns}" | velaux-store | vela-system | prod | prod-* | gke-* | gmp-* | kube-* | config-management-*) continue ;;
    esac

    out="${work}/${ns}.yaml"
    kubectl get "${kinds}" -n "${ns}" -o json --show-managed-fields=false \
      | ruby "${scripts_dir}/clean-manifests.rb" > "${out}"
    rcs=("${PIPESTATUS[@]}")

    # clean-manifests.rb の終了コード 3 = 定義が 1 つも無い（正常）。ただし kubectl が成功した場合だけ。
    # kubectl が失敗して空の List が出ても、下の error に回す。
    if [ "${rcs[0]}" = "0" ] && [ "${rcs[1]}" = "3" ]; then
      rm -f "${out}"
    elif [ "${rcs[0]}" != "0" ] || [ "${rcs[1]}" != "0" ]; then
      rm -f "${out}"
      error "${ns} の定義を取り出せませんでした"
    else
      echo "ok: ${out}"
    fi
  done

  # 小さいのでまとめて 1 スナップショットにする
  if compgen -G "${work}/*.yaml" > /dev/null; then
    if snapshot_interruptible manifest-backup --tag manifests "${work}"; then
      done_count=$((done_count + 1))
    else
      error "アプリ定義を restic に送れませんでした"
    fi
  fi
else
  error "Namespace の一覧を取れませんでした"
fi

# 2. VelaUX データストア（velaux-store の ConfigMap 群。JWT 署名鍵・bcrypt ハッシュ等を含むため
#    umask 077 の一時ディレクトリで処理し、中身をログに出さず送信後に即削除する）
old_umask=$(umask)
umask 077
rm -rf "${velaux_work}"
mkdir -p "${velaux_work}"
velaux_out="${velaux_work}/configmaps.yaml"
velaux_rc_file="${velaux_work}/.rcs"
(
  kubectl get configmaps -n "${velaux_store_ns}" -o json --show-managed-fields=false \
    | REDACT_PARSE_ERRORS=true ruby "${scripts_dir}/clean-manifests.rb" > "${velaux_out}"
  printf '%s %s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" > "${velaux_rc_file}"
) &
wait_pid=$!
wait "${wait_pid}" || true
wait_pid=""
umask "${old_umask}"

velaux_kubectl_rc=1
velaux_ruby_rc=1
if [ -r "${velaux_rc_file}" ]; then
  read -r velaux_kubectl_rc velaux_ruby_rc < "${velaux_rc_file}" || true
fi
rm -f "${velaux_rc_file}"

if [ "${velaux_kubectl_rc}" = "0" ] && [ "${velaux_ruby_rc}" = "3" ]; then
  cleanup_velaux
  echo "skip: ${velaux_store_ns} にバックアップ対象の ConfigMap がありません"
elif [ "${velaux_kubectl_rc}" != "0" ] || [ "${velaux_ruby_rc}" != "0" ]; then
  cleanup_velaux
  error "${velaux_store_ns} の ConfigMap を取り出せませんでした"
else
  if snapshot_interruptible manifest-backup --tag velaux-store "${velaux_work}"; then
    echo "ok: ${velaux_out}"
    done_count=$((done_count + 1))
  else
    error "${velaux_store_ns} の ConfigMap を restic に送れませんでした"
  fi
  cleanup_velaux
fi

finish

#!/bin/bash
# Canine が管理する dev のアプリ定義を書き出し、restic で送る（Secret は含まない）。
# 全 Namespace で 1 スナップショット: パス /work/manifests/<ns>.yaml、タグ manifests
#
# Config Sync 管理下（昇格済み = Git が正）と EXCLUDED_NAMESPACES は対象外。
set -uo pipefail
scripts_dir=${SCRIPTS_DIR:-/scripts}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh disable=SC1091
. "${scripts_dir}/lib.sh"

work=${WORK_DIR:-/work}/manifests
excluded_namespaces=${EXCLUDED_NAMESPACES:-}
kinds=${KINDS:-deployment,statefulset,daemonset,cronjob,service,ingress,configmap,pvc,hpa,serviceaccount,networkpolicy}
mkdir -p "${work}"

restic_ready

namespaces=$(kubectl get ns -l 'app.kubernetes.io/managed-by!=configmanagement.gke.io' \
  -o jsonpath='{.items[*].metadata.name}') || {
  error "Namespace の一覧を取れませんでした"
  finish
}

for ns in ${namespaces}; do
  case " ${excluded_namespaces} " in *" ${ns} "*) continue ;; esac
  case "${ns}" in prod-* | gke-* | gmp-* | kube-*) continue ;; esac

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
  if snapshot manifest-backup --tag manifests "${work}"; then
    done_count=$((done_count + 1))
  else
    error "アプリ定義を restic に送れませんでした"
  fi
fi

finish

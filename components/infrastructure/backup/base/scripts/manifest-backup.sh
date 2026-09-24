#!/bin/bash
# Canine が管理する dev のアプリ定義を書き出し、restic で送る（Secret は含まない）。
# 全 Namespace で 1 スナップショット: パス /work/manifests/<ns>.yaml、タグ manifests
#
# Config Sync 管理下（昇格済み = Git が正）と EXCLUDED_NAMESPACES は対象外。
set -uo pipefail
# shellcheck source=lib.sh
. /scripts/lib.sh

work=/work/manifests
mkdir -p "${work}"

restic_ready

namespaces=$(kubectl get ns -l 'app.kubernetes.io/managed-by!=configmanagement.gke.io' \
  -o jsonpath='{.items[*].metadata.name}') || {
  error "Namespace の一覧を取れませんでした"
  finish
}

for ns in ${namespaces}; do
  case " ${EXCLUDED_NAMESPACES} " in *" ${ns} "*) continue ;; esac
  case "${ns}" in gke-managed-* | gmp-*) continue ;; esac

  out="${work}/${ns}.yaml"
  kubectl get "${KINDS}" -n "${ns}" -o json --show-managed-fields=false \
    | ruby /scripts/clean-manifests.rb > "${out}"
  rcs=("${PIPESTATUS[@]}")

  # clean-manifests.rb の終了コード 3 = 定義が 1 つも無い（正常）
  if [ "${rcs[1]}" = "3" ]; then
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

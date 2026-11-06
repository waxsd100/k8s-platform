#!/bin/bash
# バックアップの設定のうち、仕組み上 2 か所に書くしかないものが揃っているかを確かめる。
# cargo make validate（CI）から呼ばれる。
#
#   1. DB と見なすポート: scripts/targets.rb の DB_PORTS と、
#      Kyverno の db-backup-exec-scope（exec 先の制限）の jmesPath
#      → ずれると、取ろうとした DB への exec が拒否される / 取らない DB に exec できる
#   2. restic の版の固定: backup/base/kustomization.yaml の images の 1 か所だけにあること
#   3. クラスタ全体の CRD（VolumeSnapshotClass など）に namespace が付いていないこと
#      → kustomize の namespace: は CRD のスコープを知らずに付けてしまい、
#        Config Sync が KNV1052 で同期全体を止める（kubeconform はスキーマが無く素通しする）
set -euo pipefail
cd "$(dirname "$0")/.."

base=components/infrastructure/backup/base
policy=addons/kyverno/base/clusterpolicy-db-backup-exec.yaml
failed=0

# targets.rb の DB_PORTS のキーと、Kyverno の jmesPath の containerPort==`<番号>` を比べる
rb=$(grep -oP '^\s+\K[0-9]+(?= =>)' "${base}/scripts/targets.rb" | sort -n | paste -sd' ')
kyverno=$(grep -oP 'containerPort==`\K[0-9]+' "${policy}" | sort -n | paste -sd' ')
if [ -z "${rb}" ] || [ "${rb}" != "${kyverno}" ]; then
  echo "NG: DB のポートが揃っていません: targets.rb DB_PORTS=[${rb}] ${policy}=[${kyverno}]"
  failed=1
else
  echo "ok: DB のポート (${rb})"
fi

# 版（タグや digest）付きの restic/restic は kustomization の images 以外に書かない
pinned=$(grep -rnE 'restic/restic:[0-9]' components addons clusters \
  --include='*.yaml' --include='*.rb' --include='*.sh' | grep -v "${base}/kustomization.yaml" || true)
if [ -n "${pinned}" ]; then
  echo "NG: restic/restic の版が kustomization.yaml の images 以外にあります:"
  echo "${pinned}"
  failed=1
else
  echo "ok: restic/restic の版は ${base}/kustomization.yaml だけ"
fi

cluster_scoped_kinds='VolumeSnapshotClass|VolumeSnapshotContent|ClusterSecretStore|ClusterPolicy'
for dir in "${base}" components/infrastructure/backup/cluster-resources; do
  # kustomize の出力は 1 文書ずつ "---" で区切られ、metadata.namespace は 2 字下げの "namespace:" になる
  bad=$(kustomize build "${dir}" | awk -v kinds="${cluster_scoped_kinds}" '
    function check() { if (kind ~ "^(" kinds ")$" && ns != "") print kind, name, "namespace=" ns }
    /^---/ { check(); kind = name = ns = ""; next }
    /^kind: / { kind = $2 }
    /^  name: / && name == "" { name = $2 }
    /^  namespace: / { ns = $2 }
    END { check() }')
  if [ -n "${bad}" ]; then
    echo "NG: ${dir} のクラスタ全体のリソースに namespace が付いています（cluster-resources に置く）:"
    echo "${bad}"
    failed=1
  fi
done
[ "${failed}" = "0" ] && echo "ok: クラスタ全体の CRD に namespace が付いていない"

exit "${failed}"

#!/bin/bash
# バックアップの設定のうち、仕組み上 2 か所に書くしかないものが揃っているかを確かめる。
# cargo make validate（CI）から呼ばれる。
#
#   1. DB と見なすイメージ: scripts/targets.rb の DB_ENGINES・BITNAMI_DB_ENGINES と、
#      Kyverno の db-backup-exec-scope（exec 先の制限）の正規表現
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

# targets.rb の一覧（定数名）と、Kyverno の正規表現の中の対応する選択肢（直前の文字列）を比べる
check_engines() {
  local const=$1 prefix=$2 rb kyverno
  rb=$(grep -oP "^${const} = %w\[\K[^\]]+" "${base}/scripts/targets.rb" | tr ' ' '\n' | sort | paste -sd'|')
  kyverno=$(grep -oP "regex_match\('.*\Q${prefix}\E\(\K[a-z|]+(?=\))" "${policy}" | tr '|' '\n' | sort | paste -sd'|')
  if [ -z "${rb}" ] || [ "${rb}" != "${kyverno}" ]; then
    echo "NG: DB のイメージが揃っていません: targets.rb ${const}=[${rb}] ${policy}=[${kyverno}]"
    failed=1
  else
    echo "ok: DB のイメージ ${const} (${rb})"
  fi
}
check_engines DB_ENGINES '(library/)?'
check_engines BITNAMI_DB_ENGINES 'bitnami(legacy)?/'

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

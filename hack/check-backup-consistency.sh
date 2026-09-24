#!/bin/bash
# バックアップの設定のうち、仕組み上 2 か所に書くしかないものが揃っているかを確かめる。
# cargo make validate（CI）から呼ばれる。
#
#   1. DB と見なすイメージ: scripts/targets.rb の DB_ENGINES と、
#      Kyverno の db-backup-exec-scope（exec 先の制限）の正規表現
#      → ずれると、取ろうとした DB への exec が拒否される / 取らない DB に exec できる
#   2. restic の版の固定: backup/base/kustomization.yaml の images の 1 か所だけにあること
set -euo pipefail
cd "$(dirname "$0")/.."

base=components/infrastructure/backup/base
policy=addons/kyverno/base/clusterpolicy-db-backup-exec.yaml
failed=0

engines_rb=$(grep -oP 'DB_ENGINES = %w\[\K[^\]]+' "${base}/scripts/targets.rb" | tr ' ' '\n' | sort | paste -sd'|')
engines_kyverno=$(grep -oP "regex_match\('\(\^\|/\)\(library/\)\?\(\K[a-z|]+(?=\))" "${policy}" | tr '|' '\n' | sort | paste -sd'|')
if [ -z "${engines_rb}" ] || [ "${engines_rb}" != "${engines_kyverno}" ]; then
  echo "NG: DB のイメージが揃っていません: targets.rb=[${engines_rb}] ${policy}=[${engines_kyverno}]"
  failed=1
else
  echo "ok: DB のイメージ (${engines_rb})"
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

exit "${failed}"

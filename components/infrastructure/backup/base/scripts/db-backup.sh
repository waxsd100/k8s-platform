#!/bin/bash
# クラスタ内の DB（公式の postgres / mysql / mariadb）の論理ダンプを取り、restic で送る。
# DB サーバー（コンテナ）ごとに 1 スナップショット: パス /work/db/<ns>/<pod>.sql、タグ db,<ns>
set -uo pipefail
# shellcheck source=lib.sh
. /scripts/lib.sh

work=/work

# 変数は DB コンテナの中で展開させる（パスワードはコンテナの環境変数をその場で使うだけ）。
# 公式の mariadb は MARIADB_* と、互換の MYSQL_* のどちらでも root パスワードを受け取る。
# shellcheck disable=SC2016
declare -A dump_command=(
  [postgres]='PGPASSWORD="${POSTGRES_PASSWORD:-}" pg_dumpall --clean --if-exists -U "${POSTGRES_USER:-postgres}"'
  [mysql]='mysqldump -uroot -p"${MYSQL_ROOT_PASSWORD}" --all-databases --single-transaction --routines --events --triggers'
  [mariadb]='dump=$(command -v mariadb-dump || command -v mysqldump)
             "${dump}" -uroot -p"${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}" --all-databases --single-transaction --routines --events --triggers'
)
# 最後まで書き切ったダンプの末尾にだけ出る印。途中で切れたダンプは送らない
declare -A trailer=(
  [postgres]='-- PostgreSQL database cluster dump complete'
  [mysql]='-- Dump completed'
  [mariadb]='-- Dump completed'
)

restic_ready

kubectl get pods -A -o json > "${work}/pods.json" || {
  error "Pod の一覧を取れませんでした"
  finish
}
targets=$(ruby /scripts/targets.rb db "${work}/pods.json") || {
  error "対象を決められませんでした"
  finish
}

while read -r ns pod container engine; do
  [ -n "${ns}" ] || continue
  echo "== ${ns}/${pod} (${engine})"
  mkdir -p "${work}/db/${ns}"
  out="${work}/db/${ns}/${pod}.sql"

  # stdin は while read の入力を食わないよう塞ぐ
  kubectl exec -n "${ns}" "${pod}" -c "${container}" -- sh -c "${dump_command[${engine}]}" \
    < /dev/null > "${out}"
  rc=$?

  if [ "${rc}" != "0" ] || ! tail -n 5 "${out}" | grep -q -- "${trailer[${engine}]}"; then
    error "${ns}/${pod} のダンプに失敗しました"
  elif snapshot db-backup --tag db --tag "${ns}" "${out}"; then
    echo "ok: ${out} ($(stat -c %s "${out}") bytes)"
    done_count=$((done_count + 1))
  else
    error "${ns}/${pod} を restic に送れませんでした"
  fi
  # DB は 1 つずつ置いては消す（作業領域はいちばん大きいダンプが入れば足りる）
  rm -f "${out}"
done <<< "${targets}"

finish

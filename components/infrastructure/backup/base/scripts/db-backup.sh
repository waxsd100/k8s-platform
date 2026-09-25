#!/bin/bash
# クラスタ内の DB（公式の postgres / mysql / mariadb、Bitnami の postgresql / mysql / mariadb）の
# 論理ダンプを取り、restic で送る。どの DB を取るかは targets.rb。
# DB サーバー（コンテナ）ごとに 1 スナップショット: パス /work/db/<ns>/<pod>.sql、タグ db,<ns>
set -uo pipefail
# shellcheck source=lib.sh
. /scripts/lib.sh

work=/work

# 以下は DB コンテナの中の sh で動かす（パスワードはコンテナの環境変数をその場で使うだけ）。
# secret NAME...: 最初に値のある NAME か、NAME_FILE が指すファイルの中身を出す
# （公式イメージの Docker secrets 方式と、Bitnami のチャートの既定 usePasswordFiles の両方）
# shellcheck disable=SC2016
secret_fn='secret() {
  for n in "$@"; do
    eval "v=\${${n}:-}; f=\${${n}_FILE:-}"
    if [ -n "${v}" ]; then printf %s "${v}"; return; fi
    if [ -n "${f}" ] && [ -r "${f}" ]; then cat "${f}"; return; fi
  done
}'
# どれもサーバーの全 DB を取る。mariadb は MARIADB_* と互換の MYSQL_* のどちらでも受け取る。
# Bitnami の postgresql はソケットでもパスワードを求め、スーパーユーザー postgres の
# パスワードは、別のユーザーを作ったときだけ POSTGRES_POSTGRES_PASSWORD に分かれる
# （古い版の変数名は POSTGRESQL_*）。
# shellcheck disable=SC2016
declare -A dump_command=(
  [postgres]='PGPASSWORD="$(secret POSTGRES_PASSWORD)" pg_dumpall --clean --if-exists -U "${POSTGRES_USER:-postgres}"'
  [mysql]='mysqldump -uroot -p"$(secret MYSQL_ROOT_PASSWORD)" --all-databases --single-transaction --routines --events --triggers'
  [mariadb]='dump=$(command -v mariadb-dump || command -v mysqldump)
             "${dump}" -uroot -p"$(secret MARIADB_ROOT_PASSWORD MYSQL_ROOT_PASSWORD)" --all-databases --single-transaction --routines --events --triggers'
  [bitnami-postgresql]='user=${POSTGRES_USER:-${POSTGRESQL_USERNAME:-postgres}}
             pass=$(secret POSTGRES_POSTGRES_PASSWORD POSTGRESQL_POSTGRES_PASSWORD)
             if [ -z "${pass}" ] && [ "${user}" = postgres ]; then pass=$(secret POSTGRES_PASSWORD POSTGRESQL_PASSWORD); fi
             PGPASSWORD="${pass}" pg_dumpall --clean --if-exists -w -U postgres'
  [bitnami-mysql]='mysqldump -u"${MYSQL_ROOT_USER:-root}" -p"$(secret MYSQL_ROOT_PASSWORD)" --all-databases --single-transaction --routines --events --triggers'
  [bitnami-mariadb]='dump=$(command -v mariadb-dump || command -v mysqldump)
             "${dump}" -u"${MARIADB_ROOT_USER:-root}" -p"$(secret MARIADB_ROOT_PASSWORD)" --all-databases --single-transaction --routines --events --triggers'
)
# 最後まで書き切ったダンプの末尾にだけ出る印。途中で切れたダンプは送らない
declare -A trailer=(
  [postgres]='-- PostgreSQL database cluster dump complete'
  [mysql]='-- Dump completed'
  [mariadb]='-- Dump completed'
  [bitnami-postgresql]='-- PostgreSQL database cluster dump complete'
  [bitnami-mysql]='-- Dump completed'
  [bitnami-mariadb]='-- Dump completed'
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
  kubectl exec -n "${ns}" "${pod}" -c "${container}" -- sh -c "${secret_fn}
${dump_command[${engine}]}" \
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

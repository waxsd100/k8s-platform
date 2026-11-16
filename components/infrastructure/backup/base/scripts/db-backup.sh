#!/bin/bash
# クラスタ内の DB（containerPort 5432 の PostgreSQL、3306 の MySQL / MariaDB）の
# 論理ダンプを取り、restic で送る。どの DB を取るかは targets.rb。
# DB ごとに 1 スナップショット: パス /work/db/<ns>/<ダンプ名>.sql、タグ db,<ns>
# ダンプ名は targets.rb が決める（StatefulSet は Pod 名、Deployment は Deployment 名。Pod 名は rollout で変わるため）
set -uo pipefail
scripts_dir=${SCRIPTS_DIR:-/scripts}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh disable=SC1091
. "${scripts_dir}/lib.sh"

work=${WORK_DIR:-/work}
mkdir -p "${work}"

# dev（prod-* 以外）の 1 コンテナあたりのダンプ上限（既定 1 GiB）。
# 信頼できない dev コンテナが containerPort 5432 / 3306 を宣言して巨大データを流し、
# /work（DiskPressure）や追記専用リポジトリを肥大化させるのを防ぐ。本番（prod-*）は制限しない。
DEV_MAX_DUMP_BYTES=${DEV_MAX_DUMP_BYTES-1073741824}
case "${DEV_MAX_DUMP_BYTES}" in
  "" | *[!0123456789]* | 0*)
    error "DEV_MAX_DUMP_BYTES が正の整数ではありません: ${DEV_MAX_DUMP_BYTES}"
    finish
    ;;
esac
if [ "${#DEV_MAX_DUMP_BYTES}" -gt 15 ]; then
  error "DEV_MAX_DUMP_BYTES が大きすぎます: ${DEV_MAX_DUMP_BYTES}"
  finish
fi

# 以下は DB コンテナの中の sh で動かす（パスワードはコンテナの環境変数をその場で使うだけ）。
# secret NAME...: 最初に値のある NAME か、NAME_FILE が指すファイルの中身を出す
# （公式イメージの Docker secrets 方式と、Bitnami のチャートの既定 usePasswordFiles の両方）
# shellcheck disable=SC2016
secret_fn='secret() {
  for n in "$@"; do
    eval "v=\${${n}:-}; f=\${${n}_FILE:-}"
    if [ -n "${v}" ]; then printf "%s" "${v}"; return; fi
    if [ -n "${f}" ] && [ -r "${f}" ]; then cat "${f}"; return; fi
  done
}'
# どれもサーバーの全 DB を取る。イメージの違いはコンテナの中で見分ける:
#   postgres: Bitnami（ENV BITNAMI_APP_NAME がある）はソケットでもパスワードを求め、スーパーユーザーは
#             常に postgres。そのパスワードは、別のユーザーを作ったときだけ POSTGRES_POSTGRES_PASSWORD に
#             分かれる（古い版の変数名は POSTGRESQL_*）。公式とその派生（pgvector など）は
#             POSTGRES_USER がスーパーユーザー。いずれも -w で対話プロンプト待ちを防ぐ
#   mysql   : mariadb-dump が無ければ mysqldump（公式 mysql）。mariadb は MARIADB_* と互換の MYSQL_* の
#             どちらでも受け取る。Bitnami は root のユーザー名を変えられる。
#             -p は空パスワード時に対話待ちになり、値があると /proc/<pid>/cmdline に出るため使わず、
#             パスワードがあるときだけ MYSQL_PWD で渡す
# shellcheck disable=SC2016
declare -A dump_command=(
  [postgres]='if [ -n "${BITNAMI_APP_NAME:-}" ]; then
               user=${POSTGRES_USER:-${POSTGRESQL_USERNAME:-postgres}}
               pass=$(secret POSTGRES_POSTGRES_PASSWORD POSTGRESQL_POSTGRES_PASSWORD)
               if [ -z "${pass}" ] && [ "${user}" = postgres ]; then pass=$(secret POSTGRES_PASSWORD POSTGRESQL_PASSWORD); fi
               if [ -n "${pass}" ]; then
                 PGPASSWORD="${pass}" pg_dumpall --clean --if-exists -w -U postgres
               else
                 unset PGPASSWORD
                 pg_dumpall --clean --if-exists -w -U postgres
               fi
             else
               pass=$(secret POSTGRES_PASSWORD)
               if [ -n "${pass}" ]; then
                 PGPASSWORD="${pass}" pg_dumpall --clean --if-exists -w -U "${POSTGRES_USER:-postgres}"
               else
                 unset PGPASSWORD
                 pg_dumpall --clean --if-exists -w -U "${POSTGRES_USER:-postgres}"
               fi
             fi'
  [mysql]='dump=$(command -v mariadb-dump || command -v mysqldump) || exit 127
           user=${MARIADB_ROOT_USER:-${MYSQL_ROOT_USER:-root}}
           pass=$(secret MARIADB_ROOT_PASSWORD MYSQL_ROOT_PASSWORD)
           if [ -n "${pass}" ]; then
             MYSQL_PWD="${pass}" "${dump}" -u"${user}" --all-databases --single-transaction --routines --events --triggers
           else
             unset MYSQL_PWD
             "${dump}" -u"${user}" --all-databases --single-transaction --routines --events --triggers
           fi'
)
# 最後まで書き切ったダンプの末尾にだけ出る印。途中で切れたダンプは送らない
declare -A trailer=(
  [postgres]='-- PostgreSQL database cluster dump complete'
  [mysql]='-- Dump completed'
)

restic_ready

kubectl get pods -A -o json > "${work}/pods.json" || {
  error "Pod の一覧を取れませんでした"
  finish
}
targets=$(ruby "${scripts_dir}/targets.rb" db "${work}/pods.json") || {
  rm -f "${work}/pods.json"
  error "対象を決められませんでした"
  finish
}
rm -f "${work}/pods.json"

while read -r state ns pod container engine dump_name; do
  [ -n "${state}" ] || continue
  echo "== ${ns}/${pod} (${engine})"
  if [ "${state}" = "UNREADY" ]; then
    error "${ns}/${pod} (${container}) が Ready ではないためダンプできません"
    continue
  fi
  # ダンプ名はパスの一部になるので、DNS のラベルとして安全な形だけ通す（kubectl exec は実 Pod に対して行う）
  case "${dump_name}" in
    "" | -* | .* | *. | *..* | *[!a-z0-9.-]*)
      error "${ns}/${pod} のダンプ名が不正です: ${dump_name}"
      continue
      ;;
  esac

  mkdir -p "${work}/db/${ns}"
  out="${work}/db/${ns}/${dump_name}.sql"
  overflow=0

  # stdin は while read の入力を食わないよう塞ぐ
  if [[ "${ns}" == prod-* ]]; then
    kubectl exec -n "${ns}" "${pod}" -c "${container}" -- sh -c "${secret_fn}
${dump_command[${engine}]}" \
      < /dev/null > "${out}"
    rc=$?
  else
    kubectl exec -n "${ns}" "${pod}" -c "${container}" -- sh -c "${secret_fn}
${dump_command[${engine}]}" \
      < /dev/null | head -c "$((DEV_MAX_DUMP_BYTES + 1))" > "${out}"
    pipe_rcs=("${PIPESTATUS[@]}")
    rc=${pipe_rcs[0]}
    if [ "${pipe_rcs[1]}" != "0" ]; then
      rc=${pipe_rcs[1]}
    fi
    if [ -f "${out}" ] && [ "$(stat -c %s "${out}")" -gt "${DEV_MAX_DUMP_BYTES}" ]; then
      overflow=1
    fi
  fi

  if [ "${overflow}" = "1" ]; then
    error "${ns}/${pod} のダンプが dev の上限（${DEV_MAX_DUMP_BYTES} bytes）を超えたため破棄しました"
  elif [ "${rc}" != "0" ] || ! tail -n 5 "${out}" | grep -qF -- "${trailer[${engine}]}"; then
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

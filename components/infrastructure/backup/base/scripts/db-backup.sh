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
# 1 DB あたりのダンプタイムアウト（秒）。ハングした 1 つの DB で後続の全 DB が道連れになるのを防ぐ。
PROD_DUMP_TIMEOUT=${PROD_DUMP_TIMEOUT:-1200}
DEV_DUMP_TIMEOUT=${DEV_DUMP_TIMEOUT:-600}
# dev コンテナの標準エラー出力の上限（バイト）。infra の Cloud Logging 無料枠の枯渇を防ぐ。
DEV_MAX_STDERR_BYTES=${DEV_MAX_STDERR_BYTES:-4096}

validate_pos_int() {
  local name=$1 val=$2 max_digits=$3
  case "${val}" in
    "" | *[!0123456789]* | 0*)
      error "${name} が正の整数ではありません: ${val}"
      finish
      ;;
  esac
  if [ "${#val}" -gt "${max_digits}" ]; then
    error "${name} が大きすぎます: ${val}"
    finish
  fi
}

validate_pos_int DEV_MAX_DUMP_BYTES "${DEV_MAX_DUMP_BYTES}" 15
validate_pos_int PROD_DUMP_TIMEOUT "${PROD_DUMP_TIMEOUT}" 9
validate_pos_int DEV_DUMP_TIMEOUT "${DEV_DUMP_TIMEOUT}" 9
validate_pos_int DEV_MAX_STDERR_BYTES "${DEV_MAX_STDERR_BYTES}" 9

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
#             POSTGRES_USER（または POSTGRES_USER_FILE）がスーパーユーザー。いずれも -w で対話プロンプト待ちを防ぐ
#   mysql   : mariadb-dump が無ければ mysqldump（公式 mysql）。mariadb は MARIADB_* と互換の MYSQL_* の
#             どちらでも受け取る。Bitnami は root のユーザー名を変えられる。
#             -p は空パスワード時に対話待ちになり、値があると /proc/<pid>/cmdline に出るため使わず、
#             パスワードがあるときだけ MYSQL_PWD で渡す
# shellcheck disable=SC2016
declare -A dump_command=(
  [postgres]='if [ -n "${BITNAMI_APP_NAME:-}" ]; then
               user=$(secret POSTGRES_USER POSTGRESQL_USERNAME)
               user=${user:-postgres}
               pass=$(secret POSTGRES_POSTGRES_PASSWORD POSTGRESQL_POSTGRES_PASSWORD)
               if [ -z "${pass}" ] && [ "${user}" = postgres ]; then pass=$(secret POSTGRES_PASSWORD POSTGRESQL_PASSWORD); fi
               if [ -n "${pass}" ]; then
                 PGPASSWORD="${pass}" pg_dumpall --clean --if-exists -w -U postgres
               else
                 unset PGPASSWORD
                 pg_dumpall --clean --if-exists -w -U postgres
               fi
             else
               user=$(secret POSTGRES_USER)
               user=${user:-postgres}
               pass=$(secret POSTGRES_PASSWORD)
               if [ -n "${pass}" ]; then
                 PGPASSWORD="${pass}" pg_dumpall --clean --if-exists -w -U "${user}"
               else
                 unset PGPASSWORD
                 pg_dumpall --clean --if-exists -w -U "${user}"
               fi
             fi'
  [mysql]='dump=$(command -v mariadb-dump || command -v mysqldump) || exit 127
           user=$(secret MARIADB_ROOT_USER MYSQL_ROOT_USER)
           user=${user:-root}
           pass=$(secret MARIADB_ROOT_PASSWORD MYSQL_ROOT_PASSWORD)
           if [ -n "${pass}" ]; then
             MYSQL_PWD="${pass}" "${dump}" -u"${user}" --all-databases --single-transaction --routines --events --triggers
           else
             unset MYSQL_PWD
             "${dump}" -u"${user}" --all-databases --single-transaction --routines --events --triggers
           fi'
)
dump_command[mariadb]=${dump_command[mysql]}
# 最後まで書き切ったダンプの末尾にだけ出る印。途中で切れたダンプは送らない
declare -A trailer=(
  [postgres]='-- PostgreSQL database cluster dump complete'
  [mysql]='-- Dump completed'
)
trailer[mariadb]=${trailer[mysql]}

print_dev_stderr() {
  local err_file=$1
  if [ -n "${err_file}" ] && [ -s "${err_file}" ]; then
    head -c "${DEV_MAX_STDERR_BYTES}" "${err_file}" >&2
    printf '\n' >&2
  fi
}

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
  case "${state}" in
    OK) ;;
    UNREADY)
      error "${ns}/${pod} (${container}) が Ready ではないためダンプできません"
      continue
      ;;
    *)
      error "targets.rb が不明な状態を返しました: ${state}（${ns}/${pod}）"
      continue
      ;;
  esac
  if [ -z "${ns}" ] || [ -z "${pod}" ] || [ -z "${container}" ]; then
    error "targets.rb の出力が不足しています: ${state} ${ns} ${pod} ${container}"
    continue
  fi
  case "${engine}" in
    postgres | mysql | mariadb) ;;
    *)
      error "${ns}/${pod} (${container}) の DB エンジンが不明です: ${engine}"
      continue
      ;;
  esac
  # ダンプ名はパスの一部になるので、DNS のラベルとして安全な形だけ通す（kubectl exec は実 Pod に対して行う）
  case "${dump_name}" in
    "" | -* | .* | *. | *..* | *[!a-z0-9.-]*)
      error "${ns}/${pod} のダンプ名が不正です: ${dump_name}"
      continue
      ;;
  esac

  mkdir -p "${work}/db/${ns}"
  out="${work}/db/${ns}/${dump_name}.sql"
  err_file=""
  rc_file=""
  overflow=0

  # stdin は while read の入力を食わないよう塞ぐ
  if [[ "${ns}" == prod-* ]]; then
    dump_timeout=${PROD_DUMP_TIMEOUT}
    timeout -k 30 "${dump_timeout}" kubectl exec -n "${ns}" "${pod}" -c "${container}" -- sh -c "${secret_fn}
${dump_command[${engine}]}" \
      < /dev/null > "${out}"
    rc=$?
  else
    dump_timeout=${DEV_DUMP_TIMEOUT}
    err_file="${work}/db.stderr"
    rc_file="${work}/db.rc"
    : > "${err_file}"
    rm -f "${rc_file}"
    # 標準エラーはパイプ上で上限バイトまで切り詰めて残りを破棄し、/work 枯渇とログ氾濫の両方を防ぐ
    {
      timeout -k 30 "${dump_timeout}" kubectl exec -n "${ns}" "${pod}" -c "${container}" -- sh -c "${secret_fn}
${dump_command[${engine}]}" \
        < /dev/null | head -c "$((DEV_MAX_DUMP_BYTES + 1))" > "${out}"
      printf '%s %s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" > "${rc_file}"
    } 2>&1 | {
      head -c "${DEV_MAX_STDERR_BYTES}" > "${err_file}"
      cat > /dev/null
    }
    read -r rc head_rc < "${rc_file}" 2> /dev/null || {
      rc=1
      head_rc=0
    }
    rm -f "${rc_file}"
    if [ "${head_rc}" != "0" ]; then
      rc=${head_rc}
    fi
    if [ -f "${out}" ] && [ "$(stat -c %s "${out}")" -gt "${DEV_MAX_DUMP_BYTES}" ]; then
      overflow=1
    fi
  fi

  if [ "${overflow}" = "1" ]; then
    print_dev_stderr "${err_file}"
    error "${ns}/${pod} (${container}) のダンプが dev の上限（${DEV_MAX_DUMP_BYTES} bytes）を超えたため破棄しました"
  elif [ "${rc}" = "124" ] || [ "${rc}" = "137" ]; then
    print_dev_stderr "${err_file}"
    error "${ns}/${pod} (${container}) のダンプがタイムアウトしました（上限 ${dump_timeout} 秒、終了コード ${rc}）"
  elif [ "${rc}" != "0" ] || ! tail -n 5 "${out}" | grep -F -- "${trailer[${engine}]}" > /dev/null; then
    print_dev_stderr "${err_file}"
    error "${ns}/${pod} (${container}) のダンプに失敗しました"
  elif snapshot db-backup --tag db --tag "${ns}" "${out}"; then
    echo "ok: ${out} ($(stat -c %s "${out}") bytes)"
    done_count=$((done_count + 1))
  else
    error "${ns}/${pod} (${container}) を restic に送れませんでした"
  fi
  # DB は 1 つずつ置いては消す（作業領域はいちばん大きいダンプが入れば足りる）
  rm -f "${out}" "${err_file}" "${rc_file}"
done <<< "${targets}"

finish

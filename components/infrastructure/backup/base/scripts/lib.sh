#!/bin/bash
# バックアップの Job が共通で使う関数。各スクリプトの先頭で source する。
#
# 前提の環境変数（ConfigMap restic-config と Secret restic-client から入る）:
#   RESTIC_REPOSITORY / RESTIC_REST_USERNAME / RESTIC_REST_PASSWORD / RESTIC_PASSWORD

# initContainer が Canine のイメージに持ち込んだ restic
RESTIC=${RESTIC:-/tools/restic}

failed=0
done_count=0

error() {
  echo "ERROR: $*"
  failed=1
}

# リポジトリが無ければ作る（初回だけ）。restic は「リポジトリが無い」を終了コード 10 で返す。
# それ以外の失敗（rest-server に届かない、鍵が違う = 12）で init に進むと、
# 届かない相手をもう一度長く待つだけなので、ここで止める。
restic_ready() {
  local rc
  "${RESTIC}" cat config > /dev/null
  rc=$?
  if [ "${rc}" = "10" ]; then
    "${RESTIC}" init || {
      echo "ERROR: restic のリポジトリを作れませんでした"
      exit 1
    }
  elif [ "${rc}" != "0" ]; then
    echo "ERROR: restic のリポジトリを開けません（終了コード ${rc}）"
    exit 1
  fi
}

# スナップショットのホスト名を Job ごとに固定し、パスごとに前回を親にさせる
# （親があると変わっていない部分を読み飛ばせる）。
snapshot() {
  local host=$1
  shift
  "${RESTIC}" backup --host "${host}" "$@" < /dev/null
}

finish() {
  echo "完了: ${done_count} 件"
  exit "${failed}"
}

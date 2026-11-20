#!/bin/bash
# kubectl のコンテキストを 3 つ作る（Cloud Shell などで 1 回。作り直しても同じ結果になる）。
#
#   wax100-admin  いつもの管理者（gcloud の認証そのまま）。Terraform の後始末や障害対応に
#   wax100-dev    dev（VelaUX が作った Namespace）だけ編集できる。ほかは閲覧だけ（Secret と velaux-store の ConfigMap は見えない）
#   wax100-prod   閲覧だけ（Secret と velaux-store の ConfigMap は見えない）。本番の変更は Git（components/apps/）の PR で
#
# dev / prod は、管理者の認証のままユーザー wax100-dev / wax100-prod になりすます
# （kubeconfig の users[].as）。権限は addons/kyverno/base/clusterpolicy-environment-access.yaml。
# 取り違えを防ぐためのもので、権限の境界ではない（wax100-admin に切り替えれば何でもできる）。
#
# 使い方:
#   bash hack/kubectl-contexts.sh
#   kubectl config use-context wax100-dev      # 以降の kubectl は dev の権限で動く
#   kubectl --context wax100-prod get pods -A  # 1 回だけ本番を見る
set -euo pipefail

if [ $# -gt 0 ]; then
  script_path="${BASH_SOURCE[0]:-$0}"
  case "${script_path}" in
    -*) script_path="./${script_path}" ;;
  esac
  sed -n '2,/^set -euo/p' "${script_path}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 1
fi

for cmd in gcloud kubectl jq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "エラー: 必要なコマンドが見つかりません: ${cmd}" >&2
    exit 1
  fi
done

project=${PROJECT-wax100}
cluster=${CLUSTER-wax100-platform}
location=${LOCATION-asia-northeast1-a}

for var_name in project cluster location; do
  val=${!var_name}
  case "${val}" in
    "" | -* | *[[:space:][:cntrl:]]*)
      upper_name=$(printf '%s' "${var_name}" | tr '[:lower:]' '[:upper:]')
      echo "エラー: ${upper_name} が不正です: ${val}" >&2
      exit 1
      ;;
  esac
done

if [ -z "${KUBECONFIG+x}" ]; then
  if [ -z "${HOME-}" ] || [[ "${HOME}" == *:* ]] || [[ "${HOME}" == *[[:cntrl:]]* ]]; then
    echo "エラー: HOME が不正または未設定です" >&2
    exit 1
  fi
  kubeconfig="${HOME}/.kube/config"
else
  kubeconfig=${KUBECONFIG%%:*}
fi

if [ -z "${kubeconfig}" ] || [[ "${kubeconfig}" == */ ]] || [[ "${kubeconfig}" == *[[:cntrl:]]* ]]; then
  echo "エラー: KUBECONFIG の出力先ファイルパスが不正です: ${KUBECONFIG-}" >&2
  exit 1
fi
case "${kubeconfig}" in
  -*) kubeconfig="./${kubeconfig}" ;;
esac
if [ -L "${kubeconfig}" ]; then
  echo "エラー: KUBECONFIG の出力先がシンボリックリンクのため中断します（mv によるリンク破壊を防ぐため）: ${kubeconfig}" >&2
  exit 1
fi
if [ -e "${kubeconfig}" ] && [ ! -f "${kubeconfig}" ]; then
  echo "エラー: KUBECONFIG の出力先が通常ファイルではありません: ${kubeconfig}" >&2
  exit 1
fi
kubeconfig_dir=$(dirname -- "${kubeconfig}")
if [ -e "${kubeconfig_dir}" ] && [ ! -d "${kubeconfig_dir}" ]; then
  echo "エラー: KUBECONFIG の親パスがディレクトリではありません: ${kubeconfig_dir}" >&2
  exit 1
fi
if [ ! -d "${kubeconfig_dir}" ]; then
  (umask 077 && mkdir -p -- "${kubeconfig_dir}")
fi

# gcloud get-credentials は current-context をフル管理者の gke_... へ無条件に上書きする。
# 再実行で wax100-dev 等から管理者権限へ意図せず昇格しないよう、実行前のコンテキストを退避する
prev_context=""
if [ -f "${kubeconfig}" ]; then
  prev_context=$(KUBECONFIG="${kubeconfig}" kubectl config current-context 2>/dev/null || true)
fi

# gcloud が作るコンテキスト（クラスタと、gke-gcloud-auth-plugin のユーザー）を元にする
KUBECONFIG="${kubeconfig}" gcloud container clusters get-credentials "${cluster}" --location "${location}" --project "${project}" --dns-endpoint
source_context="gke_${project}_${location}_${cluster}"
cfg_json=$(KUBECONFIG="${kubeconfig}" kubectl config view --raw -o json)
kube_cluster=$(printf '%s\n' "${cfg_json}" | jq -r --arg ctx "${source_context}" 'if type == "object" then [(.contexts | if type == "array" then .[] else empty end) | select(type == "object" and .name == $ctx) | .context? | select(type == "object") | .cluster | select(type == "string" and length > 0)][0] // empty else empty end')
kube_user=$(printf '%s\n' "${cfg_json}" | jq -r --arg ctx "${source_context}" 'if type == "object" then [(.contexts | if type == "array" then .[] else empty end) | select(type == "object" and .name == $ctx) | .context? | select(type == "object") | .user | select(type == "string" and length > 0)][0] // empty else empty end')
if [ -z "${kube_cluster}" ] || [ -z "${kube_user}" ]; then
  echo "コンテキスト ${source_context}（cluster / user）が見つかりません" >&2
  exit 1
fi

KUBECONFIG="${kubeconfig}" kubectl config set-context wax100-admin --cluster="${kube_cluster}" --user="${kube_user}" >/dev/null

# gcloud が生成した user の exec 定義をそのまま引き継ぎ、無ければ既定の gke-gcloud-auth-plugin を使う
user_exec_json=$(printf '%s\n' "${cfg_json}" | jq -c --arg usr "${kube_user}" '
  if type == "object" then
    [(.users | if type == "array" then .[] else empty end)
      | select(type == "object" and .name == $usr)
      | .user? | select(type == "object")
      | .exec? | select(type == "object" and (.command | type == "string" and length > 0))
    ][0] // empty
  else empty end
')
if [ -z "${user_exec_json}" ]; then
  user_exec_json='{"apiVersion":"client.authentication.k8s.io/v1beta1","command":"gke-gcloud-auth-plugin","interactiveMode":"IfAvailable","provideClusterInfo":true}'
fi

# dev / prod のユーザー（管理者と同じ認証プラグインで、wax100-<env> になりすます）とコンテキスト。
# kubectl config set では users[].as を書けないので、小さな kubeconfig を作って統合する
extra=""
merged=""
cleanup_tmp() {
  if [ -n "${extra}" ]; then
    rm -f -- "${extra}"
  fi
  if [ -n "${merged}" ]; then
    rm -f -- "${merged}"
  fi
  return 0
}
trap cleanup_tmp EXIT
trap 'cleanup_tmp; exit 130' INT
trap 'cleanup_tmp; exit 143' TERM
extra=$(mktemp)
merged=$(mktemp "${kubeconfig_dir}/.kubeconfig.XXXXXX")
chmod 600 -- "${extra}" "${merged}"
jq -n \
  --arg cluster "${kube_cluster}" \
  --argjson exec_cfg "${user_exec_json}" \
  '{
    apiVersion: "v1",
    kind: "Config",
    users: [
      { name: "wax100-dev", user: { as: "wax100-dev", exec: $exec_cfg } },
      { name: "wax100-prod", user: { as: "wax100-prod", exec: $exec_cfg } }
    ],
    contexts: [
      { name: "wax100-dev", context: { cluster: $cluster, user: "wax100-dev" } },
      { name: "wax100-prod", context: { cluster: $cluster, user: "wax100-prod" } }
    ]
  }' > "${extra}"
# 先に書いた方が勝つので、作り直しのときは新しい定義（extra）を先にする。
# --flatten は他クラスタの外部証明書ファイルまで非可逆展開してしまうため --raw を使う。
# 認証情報が緩い権限で一瞬でも露出しないよう、0600 を設定してから同一ディレクトリ内で原子的に mv する
KUBECONFIG="${extra}:${kubeconfig}" kubectl config view --raw > "${merged}"
if [ ! -s "${merged}" ]; then
  echo "エラー: kubeconfig の統合結果が空です" >&2
  exit 1
fi
chmod 600 -- "${merged}"
mv -- "${merged}" "${kubeconfig}"

# 実行前のコンテキストを復元する（初回・未設定時は閲覧専用の wax100-prod にしてフル管理者昇格を避ける）
target_context="${prev_context:-wax100-prod}"
if ! KUBECONFIG="${kubeconfig}" kubectl config use-context "${target_context}" >/dev/null 2>&1; then
  KUBECONFIG="${kubeconfig}" kubectl config use-context wax100-prod >/dev/null
fi

current_ctx=$(KUBECONFIG="${kubeconfig}" kubectl config current-context 2>/dev/null || echo "未設定")
echo "作成しました: wax100-admin / wax100-dev / wax100-prod（今のコンテキスト: ${current_ctx}）"
echo "確かめる:"
echo "  kubectl --context wax100-dev auth can-i create deployments -n <dev の Namespace>  # yes"
echo "  kubectl --context wax100-dev auth can-i create deployments -n prod-<app>          # no"
echo "  kubectl --context wax100-prod auth can-i delete pods -n prod-<app>                 # no"

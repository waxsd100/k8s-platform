#!/bin/bash
# kubectl のコンテキストを 3 つ作る（Cloud Shell などで 1 回。作り直しても同じ結果になる）。
#
#   wax100-admin  いつもの管理者（gcloud の認証そのまま）。Terraform の後始末や障害対応に
#   wax100-dev    dev-* だけ編集できる。ほかは閲覧だけ（Secret は見えない）
#   wax100-prod   閲覧だけ（Secret は見えない）。本番の変更は Git（components/apps/）の PR で
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

project=${PROJECT:-wax100}
cluster=${CLUSTER:-wax100-platform}
location=${LOCATION:-asia-northeast1-a}

# gcloud が作るコンテキスト（クラスタと、gke-gcloud-auth-plugin のユーザー）を元にする
gcloud container clusters get-credentials "${cluster}" --location "${location}" --project "${project}" --dns-endpoint
source_context="gke_${project}_${location}_${cluster}"
kube_cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${source_context}')].context.cluster}")
if [ -z "${kube_cluster}" ]; then
  echo "コンテキスト ${source_context} が見つかりません" >&2
  exit 1
fi

kubectl config set-context wax100-admin --cluster="${kube_cluster}" --user="${source_context}" >/dev/null

# dev / prod のユーザー（管理者と同じ認証プラグインで、wax100-<env> になりすます）とコンテキスト。
# kubectl config set では users[].as を書けないので、小さな kubeconfig を作って統合する
kubeconfig=${KUBECONFIG:-${HOME}/.kube/config}
kubeconfig=${kubeconfig%%:*}
extra=$(mktemp)
merged=$(mktemp)
trap 'rm -f "${extra}" "${merged}"' EXIT
{
  echo "apiVersion: v1"
  echo "kind: Config"
  echo "users:"
  for env in dev prod; do
    cat <<USER
  - name: wax100-${env}
    user:
      as: wax100-${env}
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: gke-gcloud-auth-plugin
        provideClusterInfo: true
        interactiveMode: IfAvailable
USER
  done
  echo "contexts:"
  for env in dev prod; do
    cat <<CONTEXT
  - name: wax100-${env}
    context:
      cluster: ${kube_cluster}
      user: wax100-${env}
CONTEXT
  done
} > "${extra}"
# 先に書いた方が勝つので、作り直しのときは新しい定義（extra）を先にする
KUBECONFIG="${extra}:${kubeconfig}" kubectl config view --flatten > "${merged}"
cp "${merged}" "${kubeconfig}"
chmod 600 "${kubeconfig}"

echo "作成しました: wax100-admin / wax100-dev / wax100-prod（今のコンテキスト: $(kubectl config current-context)）"
echo "確かめる:"
echo "  kubectl --context wax100-dev auth can-i create deployments -n dev-<app>   # yes"
echo "  kubectl --context wax100-dev auth can-i create deployments -n prod-<app>  # no"
echo "  kubectl --context wax100-prod auth can-i delete pods -n prod-<app>        # no"

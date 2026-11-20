#!/bin/bash
# dev のアプリ（gVisor で動く）に kubectl port-forward する。
#
# GKE Sandbox（gVisor）の Pod には port-forward できない。そこで dev の外の Namespace dev-access に
# gVisor 無しの中継 Pod（socat）を一時的に作り、その Pod に port-forward する。中継 Pod は Ctrl-C で消える。
#   手元:<LOCAL_PORT> → dev-access の中継 Pod:10000 → <NAMESPACE> の <TARGET>:<PORT>
# dev の Namespace は dev-access の中継 Pod からの通信を受ける（clusterpolicy-environment-isolation.yaml）。
# 本番（prod-*）には繋がらない。仕組みは components/infrastructure/dev-access/base。
#
# 使い方:
#   bash hack/dev-port-forward.sh <NAMESPACE> <TARGET> <PORT> [LOCAL_PORT]
#     NAMESPACE  繋ぎたい Service がある dev の Namespace（VelaUX が作成した usage.oam.dev/runtime=target の Namespace）
#     TARGET     <NAMESPACE> の Service 名
#   例: bash hack/dev-port-forward.sh dev-myapp postgres 5432
#       psql -h 127.0.0.1 -p 5432 -U postgres
# 使うコンテキストは今のもの（wax100-dev など）。KUBECTL_CONTEXT で変えられる。
set -euo pipefail

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
  script_path="${BASH_SOURCE[0]:-$0}"
  case "${script_path}" in
    -*) script_path="./${script_path}" ;;
  esac
  sed -n '2,/^set -euo/p' "${script_path}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 1
fi
namespace=$1
target=$2
port=$3
local_port=${4-$3}

case "${namespace}" in
  prod | prod-* | default | kube-* | gke-* | gmp-* | config-management-* | resource-group-system | \
    vela-system | velaux-store | infra | external-secrets | kyverno | reloader | headlamp | dev-access)
    echo "エラー: Namespace '${namespace}' には dev-port-forward.sh で接続できません（dev 対象外・NetworkPolicy で遮断されています）" >&2
    exit 1
    ;;
esac

is_dns_label() {
  local val=$1
  local LC_ALL=C
  [ "${#val}" -le 63 ] && [[ "${val}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

is_valid_port() {
  local val=$1
  local LC_ALL=C
  [[ "${val}" =~ ^[1-9][0-9]{0,4}$ ]] && [ "${val}" -ge 1 ] && [ "${val}" -le 65535 ]
}

if ! is_dns_label "${namespace}"; then
  echo "エラー: NAMESPACE が不正です（DNS-1123 ラベル形式で指定してください）: ${namespace}" >&2
  exit 1
fi

if ! is_dns_label "${target}"; then
  echo "エラー: TARGET が不正です（DNS-1123 ラベル形式で指定してください）: ${target}" >&2
  exit 1
fi

if ! is_valid_port "${port}"; then
  echo "エラー: PORT が不正です（1〜65535 の整数で指定してください）: ${port}" >&2
  exit 1
fi

if ! is_valid_port "${local_port}"; then
  echo "エラー: LOCAL_PORT が不正です（1〜65535 の整数で指定してください）: ${local_port}" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "エラー: kubectl が見つかりません" >&2
  exit 1
fi

kubectl=(kubectl)
if [ -n "${KUBECTL_CONTEXT+x}" ]; then
  case "${KUBECTL_CONTEXT}" in
    "" | -* | *[[:space:][:cntrl:]]*)
      echo "エラー: KUBECTL_CONTEXT が不正です: ${KUBECTL_CONTEXT}" >&2
      exit 1
      ;;
  esac
  kubectl+=("--context=${KUBECTL_CONTEXT}")
fi
relay_namespace=dev-access

# Spot の apps-pool を起動して中継 Pod を作る前に、宛先 Namespace・ラベル・Service の存在を確認する
if ! ns_label=$("${kubectl[@]}" get namespace "${namespace}" -o jsonpath='{.metadata.labels.usage\.oam\.dev/runtime}'); then
  echo "エラー: Namespace '${namespace}' の取得に失敗しました（存在しないかアクセス権限がありません）" >&2
  exit 1
fi
if ! managed_by=$("${kubectl[@]}" get namespace "${namespace}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}'); then
  echo "エラー: Namespace '${namespace}' の管理ラベル取得に失敗しました" >&2
  exit 1
fi
if [ "${managed_by}" = "configmanagement.gke.io" ]; then
  echo "エラー: Namespace '${namespace}' は Config Sync 管理下のため接続できません（dev-access/egress-restrict で遮断されます）" >&2
  exit 1
fi
if [ "${ns_label}" != "target" ]; then
  echo "エラー: Namespace '${namespace}' にラベル usage.oam.dev/runtime=target が無いため接続できません（dev-access/egress-restrict で遮断されます）" >&2
  exit 1
fi
if ! "${kubectl[@]}" get service -n "${namespace}" "${target}" >/dev/null; then
  echo "エラー: Service '${namespace}/${target}' が見つかりません" >&2
  exit 1
fi

if [ -r /dev/urandom ]; then
  pod_suffix=$(od -An -N8 -tu8 /dev/urandom | tr -d ' \n')
else
  pod_suffix="${RANDOM}${RANDOM}${RANDOM}"
fi
pod="port-forward-relay-${pod_suffix}"

pod_created=0
cleaned=0
cleanup() {
  if [ "${cleaned}" = 1 ] || [ "${pod_created}" != 1 ]; then
    return 0
  fi
  cleaned=1
  if ! "${kubectl[@]}" delete pod -n "${relay_namespace}" "${pod}" --ignore-not-found --wait=false >/dev/null; then
    echo "警告: 中継 Pod '${relay_namespace}/${pod}' の削除に失敗しました。Spot ノード（apps-pool）が最大 8 時間起動したままになるため、手動で削除してください:" >&2
    echo "  ${kubectl[*]} delete pod -n ${relay_namespace} ${pod}" >&2
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# 消し忘れても 8 時間で止まる（activeDeadlineSeconds）。
# Role port-forward-relay（dev-access/base/rbac.yaml）には patch/update が無い（pods は get/list/watch/create/delete のみ）ので create を使う
pod_created=1
"${kubectl[@]}" create -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${relay_namespace}
  labels:
    app.kubernetes.io/name: port-forward-relay
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 28800
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: socat
      image: alpine/socat:1.8.1.3@sha256:71131702f671a88b3808a70b7330f9679cd9b9933adcafadc191508edfe55bba
      args: ["TCP-LISTEN:10000,fork,reuseaddr", "TCP:${target}.${namespace}.svc.cluster.local:${port},connect-timeout=10"]
      ports:
        - containerPort: 10000
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF

runtime=$("${kubectl[@]}" get pod -n "${relay_namespace}" "${pod}" -o jsonpath='{.spec.runtimeClassName}')
if [ -n "${runtime}" ]; then
  echo "中継 Pod が ${runtime} で作られました（port-forward できません）。${relay_namespace} にラベル usage.oam.dev/runtime が付いていないか確認してください" >&2
  exit 1
fi

"${kubectl[@]}" wait --for=condition=Ready -n "${relay_namespace}" "pod/${pod}" --timeout=180s >/dev/null
echo "127.0.0.1:${local_port} → ${namespace}/${target}:${port}（Ctrl-C で終了し、中継 Pod を消します）"
"${kubectl[@]}" port-forward --address 127.0.0.1 -n "${relay_namespace}" "pod/${pod}" "${local_port}:10000"

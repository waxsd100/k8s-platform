#!/bin/bash
# dev のアプリ（gVisor で動く）に kubectl port-forward する。
#
# GKE Sandbox（gVisor）の Pod には port-forward できない。そこで同じ Namespace に gVisor の外で動く
# 中継 Pod（socat）を一時的に作り、その Pod に port-forward する。中継 Pod は Ctrl-C で消える。
#   手元:<LOCAL_PORT> → 中継 Pod:10000 → <TARGET>:<PORT>
# 中継 Pod は同じ Namespace に居るので、NetworkPolicy（environment-isolation）にも止められない。
#
# 中継 Pod を gVisor の外に出すのは、人が直接作ったラベル wax100.io/port-forward-relay=true の Pod だけ
# （addons/kyverno/base/clusterpolicy-app-scheduling.yaml の run-dev-in-gvisor）。
#
# 使い方:
#   bash hack/dev-port-forward.sh <NAMESPACE> <TARGET> <PORT> [LOCAL_PORT]
#     TARGET  Service 名（または Pod の IP などのホスト名）
#   例: bash hack/dev-port-forward.sh robopolice robopolice-postgresql 5432
#       psql -h 127.0.0.1 -p 5432 -U postgres
# 使うコンテキストは今のもの（wax100-dev など）。KUBECTL_CONTEXT で変えられる。
set -euo pipefail

if [ $# -lt 3 ]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 1
fi
namespace=$1
target=$2
port=$3
local_port=${4:-$3}

kubectl=(kubectl)
if [ -n "${KUBECTL_CONTEXT:-}" ]; then
  kubectl+=(--context "${KUBECTL_CONTEXT}")
fi

pod="port-forward-relay-${RANDOM}${RANDOM}"
trap '"${kubectl[@]}" delete pod -n "${namespace}" "${pod}" --wait=false >/dev/null 2>&1 || true' EXIT

# 消し忘れても 8 時間で止まる（activeDeadlineSeconds）
"${kubectl[@]}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${namespace}
  labels:
    wax100.io/port-forward-relay: "true"
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
      image: alpine/socat:1.8.1.3
      args: ["TCP-LISTEN:10000,fork,reuseaddr", "TCP:${target}:${port}"]
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

runtime=$("${kubectl[@]}" get pod -n "${namespace}" "${pod}" -o jsonpath='{.spec.runtimeClassName}')
if [ -n "${runtime}" ]; then
  echo "中継 Pod が ${runtime} で作られました（port-forward できません）。Kyverno のポリシーと、今のユーザーを確認してください" >&2
  exit 1
fi

"${kubectl[@]}" wait --for=condition=Ready -n "${namespace}" "pod/${pod}" --timeout=180s >/dev/null
echo "127.0.0.1:${local_port} → ${namespace}/${target}:${port}（Ctrl-C で終了し、中継 Pod を消します）"
"${kubectl[@]}" port-forward -n "${namespace}" "pod/${pod}" "${local_port}:10000"

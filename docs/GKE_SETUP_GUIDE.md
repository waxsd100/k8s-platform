# GKEクラスタ構築手順書

本ドキュメントは、GCPプロジェクト `wax100` の現在のインフラ状態に基づき、本GitOpsリポジトリと連携するGKEクラスタの構築手順をステップバイステップで解説します。

## 0. 現在のGCPインフラ状態（確認済み）

以下のリソースが既にプロビジョニングされていることを確認済みです。

| リソース | 値 |
|---|---|
| **プロジェクトID** | `wax100` |
| **リージョン / ゾーン** | `asia-northeast1` / `asia-northeast1-a` |
| **VPC** | `wax100-vpc` (カスタムモード) |
| **サブネット (メイン)** | `wax100-subnet` / `10.0.0.0/22` / Private Google Access: **有効** |
| **サブネット (LB用)** | `wax100-subnet-lb` / `10.2.0.0/24` |
| **有効化済みAPI** | Compute Engine, Kubernetes Engine, Artifact Registry, Secret Manager |
| **ファイアウォール** | HTTP(80), HTTPS(443), IAP, Health Check のルールが設定済み |

> [!IMPORTANT]
> 上記リソースが削除・変更されている場合は、先に再作成してから本手順を実行してください。

---

## 1. GKEクラスタの作成

コスト最適化アーキテクチャに基づき、**Zonalクラスタ（管理費無料）**として作成します。

```powershell
gcloud container clusters create k8s-platform `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --network=wax100-vpc `
  --subnetwork=wax100-subnet `
  --enable-private-nodes `
  --master-ipv4-cidr=172.16.0.0/28 `
  --enable-ip-alias `
  --enable-master-authorized-networks `
  --master-authorized-networks=0.0.0.0/0 `
  --num-nodes=0 `
  --release-channel=stable `
  --workload-pool=wax100.svc.id.goog `
  --disk-size=30 `
  --no-enable-basic-auth `
  --metadata disable-legacy-endpoints=true `
  --logging=NONE `
  --monitoring=NONE
```

### パラメータの解説

| パラメータ | 値 | 理由 |
|---|---|---|
| `--zone` | `asia-northeast1-a` | シングルゾーン = クラスタ管理費**無料**（Regionalだと月$73発生） |
| `--network / --subnetwork` | `wax100-vpc` / `wax100-subnet` | 既存のカスタムVPC上に構築 |
| `--enable-private-nodes` | - | ノードに外部IPを付与しない（Cloud NAT代替のe2-microで対応） |
| `--master-ipv4-cidr` | `172.16.0.0/28` | Controlplane用の専用CIDR（既存サブネットと重複しないレンジ） |
| `--enable-ip-alias` | - | VPCネイティブクラスタ（Pod/Service IPの効率的なルーティング） |
| `--num-nodes=0` | - | デフォルトノードプールにノードを作らない（Spotプールを別途作成するため） |
| `--workload-pool` | `wax100.svc.id.goog` | Workload Identity連携（ESO等がGCPサービスへ安全にアクセスするために必須） |
| `--logging=NONE` | - | Cloud Loggingの課金を防止 |
| `--monitoring=NONE` | - | Cloud Monitoringの課金を防止 |

---

## 2. Spotノードプールの追加

コスト最適化の核となるSpot VMノードプールを作成します。

```powershell
gcloud container node-pools create spot-pool `
  --project=wax100 `
  --cluster=k8s-platform `
  --zone=asia-northeast1-a `
  --machine-type=e2-small `
  --spot `
  --num-nodes=2 `
  --disk-size=20 `
  --enable-autoscaling `
  --min-nodes=1 `
  --max-nodes=4 `
  --node-taints=cloud.google.com/gke-spot=true:NoSchedule
```

| パラメータ | 値 | 理由 |
|---|---|---|
| `--machine-type` | `e2-small` | メモリ2GBの最小構成（月額約$4.5/台のSpot価格） |
| `--spot` | - | Spot VM（通常価格の60〜91%OFF） |
| `--num-nodes` | `2` | 最低2台で起動（`topologySpreadConstraints` による分散配置の前提） |
| `--enable-autoscaling` | `1〜4` | 負荷に応じて自動スケール |
| `--node-taints` | `gke-spot=true:NoSchedule` | Spot耐性のないワークロードが誤配置されることを防止 |

> [!NOTE]
> Spotインスタンスのtaintに対応するため、各Deploymentには `tolerations` の追加が必要です。
> 本リポジトリの `spot-patch.yaml` に定義済みの `topologySpreadConstraints` と併用してください。

---

## 3. デフォルトノードプールの削除（コスト削減）

Spotプールが稼働したら、クラスタ作成時に自動生成された空のデフォルトプールを削除します。

```powershell
gcloud container node-pools delete default-pool `
  --project=wax100 `
  --cluster=k8s-platform `
  --zone=asia-northeast1-a `
  --quiet
```

---

## 4. kubectlの認証設定

ローカルの `kubectl` がクラスタに接続できるよう、認証情報を取得します。

```powershell
gcloud container clusters get-credentials k8s-platform `
  --project=wax100 `
  --zone=asia-northeast1-a
```

正常に接続できることを確認します。

```powershell
kubectl get nodes
# => spot-pool-xxxxx   Ready    <none>   ...   v1.xx
```

---

## 5. ArgoCD のブートストラップ

ArgoCDをクラスタにインストールし、本GitOpsリポジトリを同期起点として登録します。

```powershell
# ArgoCD Namespaceの作成
kubectl create namespace argocd

# ArgoCD本体のインストール（Kustomize経由）
kubectl apply -k components/infrastructure/argocd/overlays/development

# ArgoCD管理者パスワードの取得
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
```

---

## 6. App of Apps の適用

ArgoCDが動いたら、各環境のルートアプリケーションを適用して全リソースの同期を開始します。

```powershell
# 開発環境のApp of Apps起点を適用
kubectl apply -f clusters/development-cluster/

# 検証環境のApp of Apps起点を適用
kubectl apply -f clusters/staging-cluster/

# 本番環境のApp of Apps起点を適用
kubectl apply -f clusters/production-cluster/
```

ArgoCDが各ディレクトリ内のマニフェストを検知し、Sync Waveの順序（Kyverno → Addons → Infra → Apps）に従って全リソースを自動展開します。

---

## 7. エッジVM（NAT兼LBゲートウェイ）の構築

プライベートクラスタの外部通信とIngress用のトラフィック転送を担う `e2-micro` VMを構築します。

### 7.1. VMインスタンスの作成

```powershell
gcloud compute instances create edge-gateway `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --machine-type=e2-micro `
  --network=wax100-vpc `
  --subnet=wax100-subnet `
  --can-ip-forward `
  --tags=http-server,https-server `
  --image-family=debian-12 `
  --image-project=debian-cloud `
  --boot-disk-size=10GB
```

> [!IMPORTANT]
> `--can-ip-forward` はNAT(IPマスカレード)を動作させるために必須です。

### 7.2 VM内でのセットアップ

VMにSSH接続して、CaddyとiptablesのNAT設定を行います。

```bash
# SSHで接続
gcloud compute ssh edge-gateway --zone=asia-northeast1-a

# --- 以下はVM内で実行 ---

# Caddyのインストール（リバースプロキシ）
sudo apt-get update && sudo apt-get install -y caddy

# Caddyの設定（GKEノードのNodePortへ転送）
# <GKE_NODE_IP> は kubectl get nodes -o wide で取得した INTERNAL-IP に置換
sudo tee /etc/caddy/Caddyfile <<EOF
:80 {
    reverse_proxy <GKE_NODE_IP>:30080
}
:443 {
    reverse_proxy <GKE_NODE_IP>:30443
}
EOF

sudo systemctl reload caddy

# IPマスカレード（NAT）の有効化
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo iptables -t nat -A POSTROUTING -o ens4 -j MASQUERADE
```

### 7.3. GKEノードのデフォルトルート変更

GKEのプライベートノードがこのVM経由で外部通信できるよう、カスタムルートを作成します。

```powershell
gcloud compute routes create nat-route `
  --project=wax100 `
  --network=wax100-vpc `
  --destination-range=0.0.0.0/0 `
  --next-hop-instance=edge-gateway `
  --next-hop-instance-zone=asia-northeast1-a `
  --tags=gke-k8s-platform-spot-pool `
  --priority=800
```

---

## 8. 構築完了後の確認

すべてのセットアップが完了したら、以下のコマンドで正常性を確認します。

```powershell
# ノードの状態確認
kubectl get nodes -o wide

# ArgoCD管理画面へのポートフォワード（http://localhost:8080 でアクセス可能）
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 全Podの稼働状態確認
kubectl get pods --all-namespaces

# Ingressの動作確認（NodePort経由）
curl http://<EDGE_GATEWAY_EXTERNAL_IP>/
```

---

## 補足: 概算月額コスト

| リソース | 概算月額 |
|---|---|
| GKEクラスタ管理費 (Zonal, 1クラスタ) | **$0** (無料枠) |
| e2-small Spot VM × 2台 | **約 $9** |
| e2-micro エッジVM (Free Tier) | **$0** (永久無料枠) |
| Cloud Logging / Monitoring | **$0** (無効化済み) |
| Cloud Load Balancing | **$0** (NodePort利用) |
| Cloud NAT | **$0** (iptables NAT利用) |
| **合計** | **約 $9 / 月** |

---

## 9. 環境の完全削除（Teardown）

検証終了後やコスト課金の即時停止のため、作成したリソースを逆順で削除します。

> [!CAUTION]
> 以下のコマンドを実行すると、クラスタ上の全データ（Pod, PV, Secret等）が完全に消去され復元できません。

### 9.1. GKEクラスタの削除

クラスタを削除すると、所属する全ノードプールとワークロードも同時に破棄されます。

```powershell
gcloud container clusters delete k8s-platform `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --quiet
```

### 9.2. エッジVM（NAT兼LBゲートウェイ）の削除

```powershell
gcloud compute instances delete edge-gateway `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --quiet
```

### 9.3. カスタムルートの削除

```powershell
gcloud compute routes delete nat-route `
  --project=wax100 `
  --quiet
```

### 9.4. 削除確認

全リソースが正常に除去されたことを確認します。

```powershell
# クラスタが存在しないことを確認
gcloud container clusters list --project=wax100

# エッジVMが存在しないことを確認
gcloud compute instances list --project=wax100

# カスタムルートが存在しないことを確認
gcloud compute routes list --project=wax100 --filter="name=nat-route"
```

> [!NOTE]
> VPC (`wax100-vpc`)、サブネット、ファイアウォールルール、有効化済みAPIはインフラ基盤として残置しています。
> これらは課金対象ではないため、削除しなくてもコストは発生しません。
> 完全にゼロからやり直す場合は、VPCごと削除してください:
> ```powershell
> gcloud compute networks delete wax100-vpc --project=wax100 --quiet
> ```


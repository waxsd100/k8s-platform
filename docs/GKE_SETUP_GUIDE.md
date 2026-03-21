# GKEクラスタ構築手順書

本ドキュメントは、GCPプロジェクト `wax100` の現在のインフラ状態に基づき、本GitOpsリポジトリと連携するGKEクラスタの構築手順をステップバイステップで解説します。

## 0. 現在のGCPインフラ状態（確認済み）

以下のリソースが既にプロビジョニングされていることを確認済みです。

| リソース                | 値                                                                   |
| ----------------------- | -------------------------------------------------------------------- |
| **プロジェクトID**      | `wax100`                                                             |
| **リージョン / ゾーン** | `asia-northeast1` / `asia-northeast1-a`                              |
| **VPC**                 | `wax100-vpc` (カスタムモード)                                        |
| **サブネット (メイン)** | `wax100-subnet` / `10.0.0.0/22` / Private Google Access: **有効**    |
| **サブネット (LB用)**   | `wax100-subnet-lb` / `10.2.0.0/24`                                   |
| **有効化済みAPI**       | Compute Engine, Kubernetes Engine, Artifact Registry, Secret Manager |
| **ファイアウォール**    | HTTP(80), HTTPS(443), IAP, Health Check のルールが設定済み           |

> [!IMPORTANT]
> 上記リソースが削除・変更されている場合は、先に再作成してから本手順を実行してください。

---

## 1. GKEクラスタの作成

コスト最適化アーキテクチャに基づき、**Zonalクラスタ（管理費無料）**として作成します。

```powershell
gcloud container clusters create wax100-platform `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --network=wax100-vpc `
  --subnetwork=wax100-subnet `
  --enable-private-nodes `
  --master-ipv4-cidr=172.16.0.0/28 `
  --enable-ip-alias `
  --cluster-ipv4-cidr=10.4.0.0/14 `
  --services-ipv4-cidr=10.8.0.0/20 `
  --enable-master-authorized-networks `
  --master-authorized-networks=0.0.0.0/0 `
  --num-nodes=1 `
  --release-channel=stable `
  --workload-pool=wax100.svc.id.goog `
  --disk-size=30 `
  --metadata disable-legacy-endpoints=true `
  --logging=NONE `
  --monitoring=NONE
```

### パラメータの解説

| パラメータ                 | 値                             | 理由                                                                                        |
| -------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------- |
| `--zone`                   | `asia-northeast1-a`            | シングルゾーン = クラスタ管理費**無料**（Regionalだと月$73発生）                            |
| `--network / --subnetwork` | `wax100-vpc` / `wax100-subnet` | 既存のカスタムVPC上に構築                                                                   |
| `--enable-private-nodes`   | -                              | ノードに外部IPを付与しない（Cloud NAT代替のe2-microで対応）                                 |
| `--master-ipv4-cidr`       | `172.16.0.0/28`                | Controlplane用の専用CIDR（既存サブネットと重複しないレンジ）                                |
| `--enable-ip-alias`        | -                              | VPCネイティブクラスタ（Pod/Service IPの効率的なルーティング）                               |
| `--cluster-ipv4-cidr`      | `10.4.0.0/14`                  | Pod用のセカンダリCIDR（既存サブネット `10.0.0.0/22`, `10.2.0.0/24` と重複しない上位レンジ） |
| `--services-ipv4-cidr`     | `10.8.0.0/20`                  | Kubernetes Service ClusterIP用のセカンダリCIDR（Pod CIDRと重複しない独立レンジ）            |
| `--num-nodes=1`            | -                              | GKEの制約上、最初はノード指定が必要です。後続の手順で削除します。                           |
| `--workload-pool`          | `wax100.svc.id.goog`           | Workload Identity連携（ESO等がGCPサービスへ安全にアクセスするために必須）                   |
| `--logging=NONE`           | -                              | Cloud Loggingの課金を防止                                                                   |
| `--monitoring=NONE`        | -                              | Cloud Monitoringの課金を防止                                                                |

---

## 2. システムノードプール（system-pool）の追加

GKEのコアシステム（通信・メトリクス等）やArgoCDを安定稼働させるため、Spotではない通常VMのノードプールを作成します。

```powershell
gcloud container node-pools create system-pool `
  --project=wax100 `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --machine-type=e2-small `
  --num-nodes=1 `
  --disk-size=30 `
  --enable-autoscaling `
  --min-nodes=1 `
  --max-nodes=2 `
  --node-labels=workload-type=system
```

## 3. アプリケーション用ノードプールの追加

全環境（Dev/Stag/Prod）のアプリ稼働を受け入れるための専用ノードを作成します。
すべてに `--node-labels=workload-type=app` を付与することで、FEなどのデプロイメントが正確にここへスケジュールされます。

### 3.1 開発・検証用ノードプール（spot-pool）

コスト最適化の核となる、アプリ稼働用のSpot VMノードプールを作成します。

```powershell
gcloud container node-pools create spot-pool `
  --project=wax100 `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --machine-type=e2-small `
  --spot `
  --num-nodes=2 `
  --disk-size=20 `
  --enable-autoscaling `
  --min-nodes=1 `
  --max-nodes=4 `
  --node-labels=workload-type=app `
  --node-taints=cloud.google.com/gke-spot=true:NoSchedule `
  --tags=gke-wax100-platform-spot-pool
```

> [!NOTE]
> `--node-taints` を付与することで、Spot耐性を持たない本番環境（Prod等）のPodが誤って強制終了リスクのあるSpot VMに配置されるのを防ぎます。
> 逆にDev/Stag環境のPodは、Toleration（通行手形）を使ってこのプールに好んで進入します。

### 3.2 本番用ノードプール（prod-pool）

本番（Prod）環境のPodはSpotのTolerationを持たないため、絶対に突然停止しない安定した標準VM（Non-Spot）のプールを別途用意します。

```powershell
gcloud container node-pools create prod-pool `
  --project=wax100 `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --machine-type=e2-small `
  --num-nodes=2 `
  --disk-size=30 `
  --enable-autoscaling `
  --min-nodes=2 `
  --max-nodes=5 `
  --node-labels=workload-type=app
```

> [!TIP]
> Prod用のノードプールにも全く同じ `workload-type=app` のラベルが付いています。
> これにより、ProdのPodはSpotのTaint（通行禁止）を避けつつ、「同じアプリ用ノード」という条件を満たすこのプールに自動的に吸い込まれます。

---

## 4. デフォルトノードプールの削除（手動）

専用の `system-pool` と `spot-pool` を整備したため、クラスタ作成時に自動生成された初期プール（古いやつ）は削除します。

```powershell
gcloud container node-pools delete default-pool `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --quiet
```

---

## 5. kubectlの認証設定

ローカルの `kubectl` がクラスタに接続できるよう、GKE認証プラグインのインストールと認証情報の取得を行います。

```powershell
# 初回のみ必須: kubectl用のGKE認証プラグインをインストール
gcloud components install gke-gcloud-auth-plugin --quiet

# 認証情報を取得して kubectl にセット
gcloud container clusters get-credentials wax100-platform `
  --project=wax100 `
  --zone=asia-northeast1-a
```

正常に接続できることを確認します。

```powershell
kubectl get nodes
# => spot-pool-xxxxx   Ready    <none>   ...   v1.xx
```

---

## 6. Config Sync のブートストラップ

コスト最適化と運用自動化のため、GCP純正マネージドGitOpsである「Config Sync」を有効化します。

### 6.1. Config Sync API の有効化とインストール
```powershell
# APIの有効化
gcloud services enable anthos.googleapis.com

# Fleet Config Managementの有効化（Config Syncエージェントの自動展開）
gcloud beta container fleet config-management apply --config=config-sync.yaml
```
> [!NOTE]
> `config-sync.yaml` は本リポジトリ直下に配置する設定ファイルです。

### 6.2. GitHubアクセストークン（PAT）の登録
Config Syncが非公開のGitHubリポジトリを読み取れるように、認証情報を事前に登録します。

```powershell
kubectl create namespace config-management-system
kubectl create secret generic git-creds -n config-management-system `
  --from-literal=username=YOUR_GITHUB_ID `
  --from-literal=token=YOUR_GITHUB_PAT
```

---

## 7. Config Sync の適用 (GitOps開始)

各環境ごとの同期定義（RootSync）を適用し、Gitからの自動展開を開始します。

```powershell
# 各環境の同期起点（RootSync）を適用
kubectl apply -f clusters/development-cluster/root-sync.yaml
kubectl apply -f clusters/staging-cluster/root-sync.yaml
kubectl apply -f clusters/production-cluster/root-sync.yaml
```

これにより、Config Syncが各クラスタディレクトリ内の `kustomization.yaml` を自動検知し、Kubernetes DashboardやKyvernoなどのインフラ基盤から、実際のアプリまで全自動で展開を開始します！

---

## 8. エッジVM（NAT兼LBゲートウェイ）の構築

プライベートクラスタの外部通信とIngress用のトラフィック転送を担う `e2-micro` VMを構築します。

### 8.1. VMインスタンスの作成

```powershell
gcloud compute instances create edge-gateway `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --machine-type=e2-micro `
  --network=wax100-vpc `
  --subnet=wax100-subnet `
  --can-ip-forward `
  --tags="http-server,https-server" `
  --scopes=cloud-platform `
  --image-family=debian-12 `
  --image-project=debian-cloud `
  --boot-disk-size=10GB
```

> [!IMPORTANT]
> `--can-ip-forward` はNAT(IPマスカレード)を動作させるために必須です。

### 8.2. VM内での自動追従リバースプロキシ設定（NAT + Caddy）

Spot VMの再起動やオートスケールによってGKEのノードIPは頻繁に変動するため、**1分間に1回GCPから最新のノードIPを取得し自動でCaddyの設定を書き換える**（完全無料の自動追従）スクリプトを仕込みます。

```bash
# SSHで接続
gcloud compute ssh edge-gateway --zone=asia-northeast1-a

# --- 以下はVM内で実行 ---

# 1. Caddyのインストール
sudo apt-get update && sudo apt-get install -y caddy

# 2. IP自動更新・追従スクリプトの作成
sudo tee /usr/local/bin/sync-gke-nodes.sh <<'EOF'
#!/bin/bash
# GKEノードの最新IPをすべて取得
IPS=$(gcloud compute instances list --filter="name~'^gke-wax100-platform-'" --format="value(networkInterfaces[0].networkIP)")

# 新しいCaddyfileを生成
CADDYFILE_NEW=":80 {\n$(for ip in $IPS; do echo "    reverse_proxy $ip:30080"; done)\n}\n:443 {\n$(for ip in $IPS; do echo "    reverse_proxy $ip:30443"; done)\n}"

# 設定が変更されていれば上書きしてCaddyを再起動
if [ "$CADDYFILE_NEW" != "$(cat /etc/caddy/Caddyfile)" ]; then
    echo -e "$CADDYFILE_NEW" > /etc/caddy/Caddyfile
    systemctl reload caddy
fi
EOF

sudo chmod +x /usr/local/bin/sync-gke-nodes.sh

# 3. 初回実行
sudo /usr/local/bin/sync-gke-nodes.sh

# 4. 1分ごとに自動実行するためのCron設定 (root権限で実行)
echo "* * * * * root /usr/local/bin/sync-gke-nodes.sh" | sudo tee /etc/cron.d/sync-gke-nodes

# 5. IPマスカレード（NAT）の有効化
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo iptables -t nat -A POSTROUTING -o ens4 -j MASQUERADE
```

### 8.3. GKEノードのデフォルトルート変更

GKE側のすべてのノード（system-poolとspot-poolの両方）がインターネットに出るためのトラフィックを、すべてこの `edge-gateway` に向けるためのルーティング設定を行います。

```powershell
# 1. GKEが自動生成したクラスター全体の共通ネットワークタグを動的に取得
$GKE_TAG = (gcloud compute instances list --filter="name~'^gke-wax100-platform-'" --format="value(tags.items[0])" | Select-Object -First 1).Trim()

# 2. 取得した共通タグを持つ全ノードに対して、デフォルトルートを edge-gateway に強制
gcloud compute routes create nat-route `
  --project=wax100 `
  --network=wax100-vpc `
  --destination-range=0.0.0.0/0 `
  --next-hop-instance=edge-gateway `
  --next-hop-instance-zone=asia-northeast1-a `
  --tags="$GKE_TAG" `
  --priority=800
```

---

## 9. 構築完了後の確認

すべてのセットアップが完了したら、以下のコマンドで正常性を確認します。

```powershell
# ノードの状態確認
kubectl get nodes -o wide

# Config Sync の同期ステータス確認
kubectl get rootsync -n config-management-system

# Kubernetes Dashboard へのアクセス準備（UI監視）
kubectl port-forward svc/kubernetes-dashboard-kong-proxy -n infra 8443:443

# (別のターミナルで実行) ログイン用Adminトークンの取得
kubectl create token dashboard-admin -n infra
# ブラウザで https://localhost:8443 にアクセスし、上記のトークンをペーストしてログインします。

# 全Podの稼働状態確認
kubectl get pods --all-namespaces

# Ingressの動作確認（NodePort経由）
curl http://<EDGE_GATEWAY_EXTERNAL_IP>/
```

---

## 補足: 概算月額コスト

| リソース                             | 概算月額                  |
| ------------------------------------ | ------------------------- |
| GKEクラスタ管理費 (Zonal, 1クラスタ) | **$0** (無料枠)           |
| e2-small Spot VM × 2台               | **約 $9**                 |
| e2-micro エッジVM (Free Tier)        | **$0** (永久無料枠)       |
| Cloud Logging / Monitoring           | **$0** (無効化済み)       |
| Cloud Load Balancing                 | **$0** (NodePort利用)     |
| Cloud NAT                            | **$0** (iptables NAT利用) |
| **合計**                             | **約 $9 / 月**            |

---

## 10. 環境の完全削除（Teardown）

検証終了後やコスト課金の即時停止のため、作成したリソースを逆順で削除します。

> [!CAUTION]
> 以下のコマンドを実行すると、クラスタ上の全データ（Pod, PV, Secret等）が完全に消去され復元できません。

### 10.1. GKEクラスタの削除

クラスタを削除すると、所属する全ノードプールとワークロードも同時に破棄されます。

```powershell
gcloud container clusters delete wax100-platform `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --quiet
```

### 10.2. エッジVM（NAT兼LBゲートウェイ）の削除

```powershell
gcloud compute instances delete edge-gateway `
  --project=wax100 `
  --zone=asia-northeast1-a `
  --quiet
```

### 10.3. カスタムルートの削除

```powershell
gcloud compute routes delete nat-route `
  --project=wax100 `
  --quiet
```

### 10.4. 削除確認

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
>
> ```powershell
> gcloud compute networks delete wax100-vpc --project=wax100 --quiet
> ```

---

## 11. 補足: 環境別 taint の運用

本リポジトリではワークロードの環境分離のため、ノードプールに `environment=<env>:NoSchedule` の taint を付与し、各オーバーレイ側で `toleration-patch.yaml` を通じて該当環境の Pod のみを許容する構成を採用しています。

例: 開発用 node-pool に taint を付与するコマンド例:

```powershell
gcloud container node-pools update <DEV_POOL> `
  --cluster=<CLUSTER_NAME> `
  --zone=<ZONE> `
  --node-taints=environment=development:NoSchedule
```

既存の Spot ノードプールには従来の `cloud.google.com/gke-spot=true:NoSchedule` taint を付与したまま維持できます。アプリ側では `spot-patch.yaml`（Spot向けの Pod 設定）と `toleration-patch.yaml`（環境固有 toleration）を組み合わせることで正確にノードスケジュールを制御しています。

---

## 12. アプリケーション用シークレットの登録 (Secret Manager)

Gitにコミットできない機密情報（DBパスワードやAPIキー等）は、GCPの **Secret Manager** に手動で登録し、External Secrets Operator (ESO) 経由でクラスタに同期させる必要があります。

### 12.1. シークレットの作成と値の登録

以下のコマンドで、GCP上にシークレットを作成し、本物のパスワードを登録します。

```powershell
# DBパスワードの登録
echo -n "your-super-secret-db-password" | gcloud secrets create frontend-db-password `
  --data-file=- `
  --project=wax100

# APIキーの登録
echo -n "your-api-key-here" | gcloud secrets create frontend-api-key `
  --data-file=- `
  --project=wax100
```

### 12.2. Workload Identityへのアクセス権付与

ESOがGCPのSecret Managerを読み取れるよう、IAMロール（参照権限）を付与します。

```powershell
gcloud projects add-iam-policy-binding wax100 `
  --member="principalSet://iam.gserviceaccount.com/wax100.svc.id.goog/infra/external-secrets" `
  --role="roles/secretmanager.secretAccessor"
```

これだけで、GitOpsリポジトリ内にある `external-secret.yaml`（引換券）が自動的に機能し、クラスタ内に本物のパスワードが入ったK8sネイティブな `Secret` リソース（`frontend-secret`）が安全に生成・マウントされます！

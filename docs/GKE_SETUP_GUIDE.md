# GKEクラスタ構築手順書

本ドキュメントは、GCP上で「Zonal GKEクラスタ + Spot VM + e2-micro(フリー枠) NATゲートウェイ」を活用した、極限コスト最適化・高可用性GitOpsアーキテクチャをゼロから構築するための手順です。

## 0. 事前準備・前提条件

本手順を実行する前に、以下のベースネットワークリソース（VPC、サブネット、FW）がすでにGCP上に作成されていることを前提とします。

| リソース                | 値                                                                   |
| ----------------------- | -------------------------------------------------------------------- |
| **プロジェクトID**      | `wax100`                                                             |
| **リージョン / ゾーン** | `asia-northeast1` / `asia-northeast1-a`                              |
| **VPC**                 | `wax100-vpc` (カスタムモード)                                        |
| **サブネット (メイン)** | `wax100-subnet` / `10.0.0.0/22` / Private Google Access: **有効**    |
| **サブネット (LB用)**   | `wax100-subnet-lb` / `10.2.0.0/24`                                   |
| **ファイアウォール**    | HTTP(80), HTTPS(443), IAP, Health Check の許可ルール設定済み         |

> [!IMPORTANT]
> 上記の「VPCやサブネット」が存在しない真っさらなプロジェクトから構築する場合は、先にTerraform等で上記リソースを作成してください。

## 0. 事前準備 (API有効化と権限付与)

何もないGCPプロジェクトからスタートする場合、まずは必要な機能をすべて有効化します。

### 0.1. 必要なGCP APIの有効化
```powershell
gcloud services enable `
  compute.googleapis.com `
  container.googleapis.com `
  artifactregistry.googleapis.com `
  secretmanager.googleapis.com `
  anthos.googleapis.com `
  cloudbuild.googleapis.com `
  developerconnect.googleapis.com
```

### 0.2. Compute Engineデフォルトサービスアカウントへの権限付与
ノードがArtifact Registryから新しいコンテナイメージ（GitOpsの設定ファイル等）を安全に引き出せるようにするため、インフラの標準アカウントに特権を付与します。
（※これを行わないと、以降のPodデプロイで `ErrImagePull` や `ImagePullBackOff` が発生します）

```powershell
# プロジェクト番号の取得
$PROJECT_NUMBER = gcloud projects describe wax100 --format="value(projectNumber)"

# ノード必須権限の付与（--condition=Noneで条件プロンプトを回避）
gcloud projects add-iam-policy-binding wax100 `
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" `
  --role="roles/container.defaultNodeServiceAccount" `
  --condition=None
```

---

## 1. GKEクラスタの作成

コスト最適化のため、**Zonalクラスタ（管理費無料）** および **完全プライベートクラスタ（NAT依存）** として作成します。

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
| `--zone`                   | `asia-northeast1-a`            | シングルゾーン指定によりクラスタ管理費（約$73/月）を**完全無料**にするため                  |
| `--network / --subnetwork` | `wax100-vpc` / `wax100-subnet` | 既存のカスタムVPC上に構築                                                                   |
| `--enable-private-nodes`   | -                              | 外部IPを付与せず、後の「自作NATルーター」を通すことでCloud NAT料金を削減するため            |
| `--master-ipv4-cidr`       | `172.16.0.0/28`                | Controlplane用の専用CIDR（既存サブネットと重複しないレンジ）                                |
| `--enable-ip-alias`        | -                              | VPCネイティブクラスタ（Pod/Service IPの効率的なルーティング）                               |
| `--cluster-ipv4-cidr`      | `10.4.0.0/14`                  | Pod用のセカンダリCIDR（既存サブネット `10.0.0.0/22`, `10.2.0.0/24` と重複しない上位レンジ） |
| `--services-ipv4-cidr`     | `10.8.0.0/20`                  | Kubernetes Service ClusterIP用のセカンダリCIDR（Pod CIDRと重複しない独立レンジ）            |
| `--num-nodes=1`            | -                              | GKEの制約上、最初はノード指定が必要です。後続の手順で削除します。                           |
| `--workload-pool`          | `wax100.svc.id.goog`           | Workload Identity連携（ESOやConfig Sync等がGCPサービスへ安全にアクセスするために必須）    |
| `--logging=NONE`           | -                              | Cloud Loggingの高額な従量課金を完全にブロックするため                                       |
| `--monitoring=NONE`        | -                              | Cloud Monitoringの高額な従量課金を完全にブロックするため                                    |

---

## 2. システムノードプール（system-pool）の追加

GKEのコアシステム（通信・メトリクス等）やArgoCDを安定稼働させるため、Spotではない通常VMのノードプールを作成します。

```powershell
gcloud container node-pools create system-pool `
  --project=wax100 `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --machine-type=e2-medium `
  --num-nodes=1 `
  --disk-size=30 `
  --enable-autoscaling `
  --min-nodes=1 `
  --max-nodes=2 `
  --node-labels=workload-type=system
```

> [!NOTE]
> Config Syncの同期エンジン（`root-reconciler`等）やシステムリソースを安定稼働させるため、`e2-medium`（2vCPU / 4GB RAM）を採用しています。

## 3. アプリケーション用ノードプールの追加

全環境（Dev/Stag/Prod）のアプリ稼働を受け入れるための専用ノードを作成します。
すべてに `--node-labels=workload-type=app` を付与することで、アプリが正確にここへスケジュールされます。

### 3.1 開発・検証用ノードプール（spot-pool）
コスト最適化の核となる、アプリ稼働用のSpot VMノードプールです。

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

```powershell
gcloud container node-pools delete default-pool `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --quiet
```

---

## 5. エッジVM（NAT兼LBゲートウェイ）の構築

**【重要】GKEクラスタにアプリをデプロイする前に設定が必要です！**
プライベートクラスタの外部通信（GCP公式リポジトリからのコンテナpull等）と、インターネットからのIngressトラフィック転送を担う `e2-micro` VMを構築します。

### 5.1. VMインスタンスの作成
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

### 5.2. VM内での自動追従リバースプロキシ設定（NAT + Caddy）
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
sudo /usr/local/bin/sync-gke-nodes.sh

# 3. 1分ごとに自動追従するためのCron設定
echo "* * * * * root /usr/local/bin/sync-gke-nodes.sh" | sudo tee /etc/cron.d/sync-gke-nodes

# 4. IPマスカレード（NAT）の有効化と永続化
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo iptables -t nat -A POSTROUTING -o ens4 -j MASQUERADE

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

### 5.3. GKEノードのデフォルトルート変更
GCPネイティブの「Cloud NAT（約$32/月）」を使わず、作成した `edge-gateway` にすべて迂回させます。

```powershell
$GKE_TAG = (gcloud compute instances list --filter="name~'^gke-wax100-platform-'" --format="value(tags.items[0])" | Select-Object -First 1).Trim()

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

## 6. kubectlの認証設定

```powershell
gcloud components install gke-gcloud-auth-plugin --quiet
gcloud container clusters get-credentials wax100-platform `
  --project=wax100 `
  --zone=asia-northeast1-a
```

---

## 7. Config Sync のブートストラップ (パスワードレスGitOps)

### 7.1. Config Sync API の有効化とインストール
```powershell
gcloud beta container fleet config-management enable
```

### 7.2. OCI同期用インフラ基盤の構築 (完全パスワードレス)

#### 1. Artifact Registry リポジトリの作成
```powershell
gcloud artifacts repositories create config-sync-repo `
  --repository-format=docker `
  --location=asia-northeast1 `
  --description="OCI repository for Config Sync manifests" `
  --project=wax100
```

#### 2. Developer Connect の接続作成（ブラウザ必須）

[Developer Connect](https://console.cloud.google.com/developer-connect/connections) は GitHub の OAuth 認証をブラウザで行う必要があるため、GCPコンソールから設定します。

1. [Cloud Build > リポジトリ（asia-northeast1）](https://console.cloud.google.com/cloud-build/repositories;region=asia-northeast1) を開く
2. **「接続を作成」** をクリック
3. 以下を入力：
   - **プロバイダー**: `GitHub`
   - **リージョン**: `asia-northeast1`（※GKE/Artifact Registryと同一リージョンにすること）
   - **接続名**: 任意（例: `waxsd100`）
4. GitHub の OAuth 認証画面で承認し、**「Only select repositories」を選択して対象のマニフェストリポジトリのみ**をチェックして保存

> [!IMPORTANT]
> リージョンは必ず GKE クラスタ・Artifact Registry と同じ `asia-northeast1` を選択してください。
> 異なるリージョンを選ぶと、クロスリージョン転送コストが発生し、同期速度も低下します。

#### 3. Cloud Build 専用サービスアカウントの作成と権限付与

GCPのベストプラクティスに従い、レガシーのデフォルトSAではなく **Cloud Build 専用のユーザー管理サービスアカウント** を作成し、必要最小限の権限のみを付与します。

```powershell
# Cloud Build 専用サービスアカウントの作成
gcloud iam service-accounts create cloudbuild-sa `
  --display-name="Cloud Build Manifest Sync" `
  --project=wax100

# Artifact Registry への書き込み権限（OCIイメージのプッシュに必要）
gcloud projects add-iam-policy-binding wax100 `
  --member="serviceAccount:cloudbuild-sa@wax100.iam.gserviceaccount.com" `
  --role="roles/artifactregistry.writer" `
  --condition=None

# Cloud Logging への書き込み権限（ビルドログの出力に必要）
gcloud projects add-iam-policy-binding wax100 `
  --member="serviceAccount:cloudbuild-sa@wax100.iam.gserviceaccount.com" `
  --role="roles/logging.logWriter" `
  --condition=None

# Developer Connect 経由でソースコードを読み取る権限
gcloud projects add-iam-policy-binding wax100 `
  --member="serviceAccount:cloudbuild-sa@wax100.iam.gserviceaccount.com" `
  --role="roles/developerconnect.readTokenAccessor" `
  --condition=None

# Cloud Build の実行権限
gcloud projects add-iam-policy-binding wax100 `
  --member="serviceAccount:cloudbuild-sa@wax100.iam.gserviceaccount.com" `
  --role="roles/cloudbuild.builds.builder" `
  --condition=None
```

> [!NOTE]
> **SA の役割分担（最小権限の原則）**
> | サービスアカウント | 用途 | 権限 |
> |---|---|---|
> | `cloudbuild-sa` | Cloud Build がOCIイメージを**書き込む** | `artifactregistry.writer` + `logging.logWriter` + `developerconnect.readTokenAccessor` + `cloudbuild.builds.builder` |
> | `config-sync-sa` | Config Sync がOCIイメージを**読み取る** | `artifactregistry.reader` |

#### 4. Cloud Build トリガーの作成

##### 方法A: GCPコンソールから作成（推奨）

[Cloud Build > トリガー > トリガーを作成](https://console.cloud.google.com/cloud-build/triggers;region=asia-northeast1/add) を開き、以下を入力して保存：

| 項目 | 値 |
|---|---|
| **名前** | `manifest-sync` |
| **リージョン** | `asia-northeast1` |
| **イベント** | `ブランチに push する` |
| **ソース（第2世代）** | 接続: `waxsd100` / リポジトリ: `waxsd100-k8s-platform` |
| **ブランチ** | `^main$` |
| **構成** | `Cloud Build の構成ファイル（yaml または json）` |
| **場所** | リポジトリ / `/cloudbuild.yaml` |
| **サービスアカウント** | `cloudbuild-sa@wax100.iam.gserviceaccount.com` |

##### 方法B: gcloud CLI から作成

```powershell
# 接続名とリポジトリリンク名を確認
gcloud developer-connect connections git-repository-links list `
  --connection=waxsd100 `
  --location=asia-northeast1 `
  --project=wax100

# トリガーを作成
gcloud builds triggers create github `
  --name="manifest-sync" `
  --region=asia-northeast1 `
  --project=wax100 `
  --repository="projects/wax100/locations/asia-northeast1/connections/waxsd100/gitRepositoryLinks/waxsd100-k8s-platform" `
  --branch-pattern="^main$" `
  --build-config="cloudbuild.yaml" `
  --service-account="projects/wax100/serviceAccounts/cloudbuild-sa@wax100.iam.gserviceaccount.com"
```

> [!TIP]
> トリガー作成後、初回は手動でCloud Buildを実行してArtifact Registryにイメージを登録する必要があります：
> ```powershell
> gcloud builds submit . --config cloudbuild.yaml --region=asia-northeast1 --project=wax100
> ```
> 以降は `git push` のたびに自動でパイプラインが起動します。

#### 5. 認証用GCPサービスアカウントの作成と紐付け（Config Sync用）
```powershell
gcloud iam service-accounts create config-sync-sa --project=wax100

gcloud projects add-iam-policy-binding wax100 `
  --member="serviceAccount:config-sync-sa@wax100.iam.gserviceaccount.com" `
  --role="roles/artifactregistry.reader" `
  --condition=None

gcloud iam service-accounts add-iam-policy-binding config-sync-sa@wax100.iam.gserviceaccount.com `
  --role="roles/iam.workloadIdentityUser" `
  --member="serviceAccount:wax100.svc.id.goog[config-management-system/root-reconciler]" `
  --project=wax100 `
  --condition=None
```

---

## 8. Config Sync の適用 (GitOps開始)

Cloud Build トリガーを作成した後、一度GitHubへコミットをPushするか、手動でCloud Buildを実行して、Artifact Registry にイメージをアップロード（ビルド）させてください。

```powershell
# ビルド完了後、各環境の同期起点（RootSync - OCIモード版）を適用
kubectl apply -f clusters/development-cluster/root-sync.yaml
kubectl apply -f clusters/staging-cluster/root-sync.yaml
kubectl apply -f clusters/production-cluster/root-sync.yaml
```

これにより、Config SyncがGCPの公式権限を使ってArtifact Registryからファイルを拾い上げ、インフラ基盤からアプリまで全自動で展開を開始します！！

---

## 9. 構築完了後の確認

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
```

---

## 10. 全リソースの完全削除（Teardown）

```powershell
gcloud container clusters delete wax100-platform --project=wax100 --zone=asia-northeast1-a --quiet
gcloud compute instances delete edge-gateway --project=wax100 --zone=asia-northeast1-a --quiet
gcloud compute routes delete nat-route --project=wax100 --quiet
```

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

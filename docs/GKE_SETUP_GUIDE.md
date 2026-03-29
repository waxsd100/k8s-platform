# GKEクラスタ構築手順書

本ドキュメントは、GCP上で「Zonal GKEクラスタ + Spot VM + e2-micro(フリー枠) NATゲートウェイ」を活用した、極限コスト最適化・高可用性GitOpsアーキテクチャをゼロから構築するための手順です。

## 0. 事前準備・前提条件

本手順を実行する前に、以下のベースネットワークリソース（VPC、サブネット、FW）がすでにGCP上に作成されていることを前提とします。

| リソース                 | 値                                                                |
| ------------------------ | ----------------------------------------------------------------- |
| **プロジェクトID**       | `wax100`                                                          |
| **リージョン / ゾーン**  | `asia-northeast1` / `asia-northeast1-a`                           |
| **VPC**                  | `wax100-vpc` （カスタムモード）                                   |
| **サブネット（メイン）** | `wax100-subnet` / `10.0.0.0/22` / Private Google Access: **有効** |
| **サブネット（LB用）**   | `wax100-subnet-lb` / `10.2.0.0/24`                                |
| **ファイアウォール**     | HTTP(80), HTTPS(443), IAP, Health Check の許可ルール設定済み      |

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

ノードが Artifact Registry から新しいコンテナイメージ（GitOpsの設定ファイル等）を安全に引き出せるようにするため、インフラの標準アカウントに特権を付与します。
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
用途に合わせて、監視・ロギングの有無（コスト最優先で完全に無効にする構成か、運用監視を有効にする構成か）を選択して実行してください。

### パターンA: 監視完全無効（コスト最優先構成）

Cloud Logging と Cloud Monitoring の従量課金を完全にブロックします（全くログが残りません）。

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

### パターンB: 監視有効（推奨構成）

Cloud Logging と Cloud Monitoring をシステムコンポーネントのみ有効（`SYSTEM`）にし、最低限のクラスタ正常性確認やログ調査を行えるようにします。アプリのログは出力されません。

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
  --logging=SYSTEM `
  --monitoring=SYSTEM
```

### パラメータの解説

| パラメータ                   | 値                             | 理由                                                                                         |
| ---------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------- |
| `--zone`                     | `asia-northeast1-a`            | シングルゾーン指定によりクラスタ管理費（約$73/月）を**完全無料**にするため                   |
| `--network` / `--subnetwork` | `wax100-vpc` / `wax100-subnet` | 既存のカスタムVPC上に構築                                                                    |
| `--enable-private-nodes`     | -                              | 外部IPを付与せず、後の「自作NATルーター」を通すことでCloud NAT料金を削減するため             |
| `--master-ipv4-cidr`         | `172.16.0.0/28`                | Controlplane用の専用CIDR（既存サブネットと重複しないレンジ）                                 |
| `--enable-ip-alias`          | -                              | VPCネイティブクラスタ（Pod/Service IPの効率的なルーティング）                                |
| `--cluster-ipv4-cidr`        | `10.4.0.0/14`                  | Pod用のセカンダリCIDR（既存サブネット `10.0.0.0/22`, `10.2.0.0/24` と重複しない上位レンジ）  |
| `--services-ipv4-cidr`       | `10.8.0.0/20`                  | Kubernetes Service ClusterIP用のセカンダリCIDR（Pod CIDRと重複しない独立レンジ）             |
| `--num-nodes=1`              | -                              | GKEの制約上、最初はノード指定が必要です。後続の手順で削除します。                            |
| `--workload-pool`            | `wax100.svc.id.goog`           | Workload Identity連携（ESOやConfig Sync等がGCPサービスへ安全にアクセスするために必須）       |
| `--logging`                  | `NONE` 又は `SYSTEM`           | `NONE`は高額な従量課金をブロックするため。`SYSTEM`はシステムコンポーネントの基本ログ監視用。 |
| `--monitoring`               | `NONE` 又は `SYSTEM`           | `NONE`は高額な課金をブロックするため。`SYSTEM`はシステムリソース推移などの基本メトリクス用。 |

---

## 2. システムノードプール (`system-pool`) の追加

GKEのコアシステム（通信・メトリクス等）や ArgoCD を安定稼働させるため、Spotではない通常VMのノードプールを作成します。

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
  --max-nodes=1 `
  --node-labels=workload-type=system
```

> [!NOTE]
> Config Sync の同期エンジン（`root-reconciler` 等）やシステムリソースを安定稼働させるため、`e2-medium`（2vCPU / 4GB RAM）を採用しています。

## 3. アプリケーション用ノードプールの追加

全環境（Dev / Stag / Prod）のアプリ稼働を受け入れるための専用ノードを作成します。
すべてに `--node-labels=workload-type=app` を付与することで、アプリが正確にここへスケジュールされます。

### 3.1. 開発・検証用ノードプール (`app-pool`)

コスト最適化の核となる、アプリ稼働用の Spot VM ノードプールです。

```powershell
gcloud container node-pools create app-pool `
  --project=wax100 `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --machine-type=e2-small `
  --spot `
  --num-nodes=2 `
  --disk-size=20 `
  --enable-autoscaling `
  --min-nodes=0 `
  --max-nodes=3 `
  --node-labels=workload-type=app `
  --node-taints=cloud.google.com/gke-spot=true:NoSchedule `
  --tags="gke-wax100-platform-app-pool,use-custom-nat"
```

> [!NOTE]
> `--node-taints` を付与することで、Spot耐性を持たない本番環境（Prod等）のPodが誤って強制終了リスクのある Spot VM に配置されるのを防ぎます。
> 逆に Dev / Stag 環境のPodは、Toleration（通行手形）を使ってこのプールに好んで進入します。

### 3.2. 本番用ノードプール (`prod-pool`)

```powershell
gcloud container node-pools create prod-pool `
  --project=wax100 `
  --cluster=wax100-platform `
  --zone=asia-northeast1-a `
  --machine-type=e2-small `
  --spot `
  --num-nodes=1 `
  --disk-size=30 `
  --enable-autoscaling `
  --min-nodes=1 `
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

## 5. クラスタ外部通信（NAT）の構築

**【重要】GKEクラスタにアプリをデプロイする前に設定が必要です！**
完全プライベートクラスタはそのままではインターネット（GCP公式リポジトリ等からのコンテナpull）へ通信できません。
本アーキテクチャでは、「Prod環境は高可用な Cloud NAT」「Dev/Stag環境は安価な自作 エッジVM」を利用する**同一クラスタ内ハイブリッドNAT構成**を採用しています。

### 5.1. Cloud NAT の構築（Prod環境のデフォルト出口）

運用保守の手間がなく、高可用・高帯域幅のSLAが提供されるGCP標準のNATを作成します。これがクラスタ全体のデフォルトのインターネット出口となります。

```powershell
# Cloud Router の作成
gcloud compute routers create wax100-router `
  --project=wax100 `
  --network=wax100-vpc `
  --region=asia-northeast1

# Cloud NAT の作成
gcloud compute routers nats create wax100-nat `
  --project=wax100 `
  --router=wax100-router `
  --region=asia-northeast1 `
  --auto-allocate-nat-external-ips `
  --nat-all-subnet-ip-ranges
```

### 5.2. 自作エッジVMの構築（Dev/Stag環境向けの迂回出口）

コスト最適化のため、Spot VM 用ノードプール（`app-pool`）に乗っているPodの通信だけは、Cloud NAT を通さず無償枠の `e2-micro` VMへ迂回させて処理します。

#### 1. VMインスタンスの作成

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

#### 2. VM内での自動追従プロキシ・NAT設定

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

> [!NOTE]
> ここまでVM内での作業となります。

#### 3. 開発用ノードの専用迂回ルート設定

ノードプール作成時に付与した `use-custom-nat` タグを持つVM（＝Dev/Stag用ノード）のみ、トラフィックを Cloud NAT ではなく `edge-gateway` へ直接流れるようにカスタムルートを設定します。

```powershell
gcloud compute routes create nat-route `
  --project=wax100 `
  --network=wax100-vpc `
  --destination-range=0.0.0.0/0 `
  --next-hop-instance=edge-gateway `
  --next-hop-instance-zone=asia-northeast1-a `
  --tags="use-custom-nat" `
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
>
> | サービスアカウント | 用途 | 権限 |
> |---|---|---|
> | `cloudbuild-sa` | Cloud Build がOCIイメージを**書き込む** | `artifactregistry.writer` + `logging.logWriter` + `developerconnect.readTokenAccessor` + `cloudbuild.builds.builder` |
> | `config-sync-sa` | Config Sync がOCIイメージを**読み取る** | `artifactregistry.reader` |

#### 4. Cloud Build トリガーの作成

##### 方法A: GCPコンソールから作成（推奨）

[Cloud Build > トリガー > トリガーを作成](https://console.cloud.google.com/cloud-build/triggers;region=asia-northeast1/add) を開き、以下を入力して保存：

| 項目                   | 値                                                     |
| ---------------------- | ------------------------------------------------------ |
| **名前**               | `manifest-sync`                                        |
| **リージョン**         | `asia-northeast1`                                      |
| **イベント**           | `ブランチに push する`                                 |
| **ソース（第2世代）**  | 接続: `waxsd100` / リポジトリ: `waxsd100-k8s-platform` |
| **ブランチ**           | `^main$`                                               |
| **構成**               | `Cloud Build の構成ファイル（yaml または json）`       |
| **場所**               | リポジトリ / `/cloudbuild.yaml`                        |
| **サービスアカウント** | `cloudbuild-sa@wax100.iam.gserviceaccount.com`         |

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
>
> ```powershell
> gcloud builds submit . --config cloudbuild.yaml --region=asia-northeast1 --project=wax100
> ```
>
> 以降は `git push` のたびに自動でパイプラインが起動します。

#### 5. 認証用GCPサービスアカウントの作成と紐付け (Config Sync用)

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

これにより、Config SyncがGCPの公式権限を使って Artifact Registry からファイルを拾い上げ、インフラ基盤からアプリまで全自動で展開を開始します！！

---

## 9. 構築完了後の確認

```powershell
# ノードの状態確認
kubectl get nodes -o wide

# Config Sync の同期ステータス確認
kubectl get rootsync -n config-management-system
```

### 9.1. Cloudflare Zero Trust 経由での Kubernetes Dashboard アクセス設定

本構成では、より安全にアクセスするため、Cloudflare Tunnel を経由して Dashboard を公開します。

#### 1. Cloudflare Tunnel の作成（ブラウザ）

1. Cloudflare Zero Trust ダッシュボードを開き、`Networks` > `Tunnels` へ進みます。
2. `Create a tunnel` をクリックし、`Cloudflared` を選択します。
3. トンネル名（例: `k8s-dashboard`）を入力して保存します。
4. インストール手順に表示されるコマンドの中から **トークン (`TUNNEL_TOKEN`)** の文字列をコピーします。

```powershell
# （例）発行されたトークンを用いてサービスをインストールするコマンド
cloudflared.exe service install TUNNEL_TOKEN
```

#### 2. 公開ルートの設定（ブラウザ）

引続きトンネルの設定画面から `Public Hostname` タブを開き、以下を設定して保存します：

- **Public hostname**: 割り当てるドメイン名（例: `dashboard.example.com`）
- **Service**:
  - Type: `HTTPS`
  - URL: `kubernetes-dashboard-kong-proxy.infra.svc.cluster.local:443`
- **Additional application settings** > **TLS**:
  - `No TLS Verify` を **有効(Enable)** にします（※Dashboardの自己署名証明書によるエラーを回避するため必須です）。

#### 3. クラスタへのトークン登録（ターミナル）

前段でコピーしたトークンを用いて、GKEクラスタの `infra` Namespace に Secret を作成します。
（GitOpsによって展開される `cloudflared` のポッドが、このSecretを読み取ってトンネルを確立します。）

```powershell
kubectl create secret generic cloudflared-credentials `
  --namespace=infra `
  --from-literal=TUNNEL_TOKEN="TUNNEL_TOKEN"
```

#### 4. ダッシュボードへのログイン

```powershell
# ログイン用Adminトークンの取得
kubectl create token dashboard-admin -n infra
```

上記で設定した Public Hostname（例: `https://dashboard.wax100.io`）にブラウザでアクセスし、取得したAdminトークンをペーストしてログインします。

---

## 10. 全リソースの完全削除 (Teardown)

```powershell
gcloud container clusters delete wax100-platform --project=wax100 --zone=asia-northeast1-a --quiet

# 自作NAT VMとルートの削除
gcloud compute instances delete edge-gateway --project=wax100 --zone=asia-northeast1-a --quiet
gcloud compute routes delete nat-route --project=wax100 --quiet

# Cloud NAT の削除
gcloud compute routers nats delete wax100-nat --project=wax100 --router=wax100-router --region=asia-northeast1 --quiet
gcloud compute routers delete wax100-router --project=wax100 --region=asia-northeast1 --quiet
```

---

## 11. 補足: 環境別 Taint の運用

本リポジトリではワークロードの環境分離のため、ノードプールに `environment=<env>:NoSchedule` の Taint を付与し、各オーバーレイ側で `toleration-patch.yaml` を通じて該当環境の Pod のみを許容する構成を採用しています。

### 例: 開発用 Node Pool に Taint を付与するコマンド例

```powershell
gcloud container node-pools update <DEV_POOL> `
  --cluster=<CLUSTER_NAME> `
  --zone=<ZONE> `
  --node-taints=environment=development:NoSchedule
```

既存の Spot ノードプールには従来の `cloud.google.com/gke-spot=true:NoSchedule` Taint を付与したまま維持できます。アプリ側では `spot-patch.yaml`（Spot向けの Pod 設定）と `toleration-patch.yaml`（環境固有 Toleration）を組み合わせることで、正確にノードスケジュールを制御しています。

---

## 12. アプリケーション用シークレットの登録 (Secret Manager)

Gitにコミットできない機密情報（DBパスワードやAPIキー等）は、GCPの **Secret Manager** に手動で登録し、External Secrets Operator (ESO) 経由でクラスタに同期させる必要があります。

### 12.1. シークレットの作成と値の登録

以下のコマンドで、GCP上にシークレットを作成し、本物のパスワードを登録します。

```powershell
# Kubernetes Dashboard の CSRFキー登録 (256文字のランダム自動生成)
-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 256 | % {[char]$_}) | gcloud secrets create dashboard-csrf-key `
  --data-file=- `
  --project=wax100

# APIキーの登録
echo -n "your-api-key-here" | gcloud secrets create frontend-api-key `
  --data-file=- `
  --project=wax100
```

### 12.2. Workload Identity へのアクセス権付与

ESO が GCP の Secret Manager を読み取れるよう、IAMロール（参照権限）を付与します。

```powershell
gcloud projects add-iam-policy-binding wax100 `
  --member="principalSet://iam.gserviceaccount.com/wax100.svc.id.goog/infra/external-secrets" `
  --role="roles/secretmanager.secretAccessor"
```

これだけで、GitOps リポジトリ内にある `external-secret.yaml`（引換券）が自動的に機能し、クラスタ内に本物のパスワードが入ったK8sネイティブな `Secret` リソース（`frontend-secret`）が安全に生成・マウントされます！

---

## 13. アプリケーション (wax100-blog) 用 CI/CD パイプラインの構成

Config Sync による「インフラとK8sマニフェストの自動展開 (Pull型)」とは別に、アプリケーション側（`wax100-blog` リポジトリ）のコンテナイメージをビルドし、環境ごとの静的タグ（`dev`, `stg`, `prod`）として Artifact Registry に自動でPushするビルドパイプライン (Push型) のトリガーを設定します。

### 13.1. Developer Connect アプリ側リポジトリの接続

`7.2` 節で `manifest` リポジトリを接続したのと同じ要領で、`wax100-blog` アプリケーションリポジトリも Developer Connect（`waxsd100` 接続等の中）に追加・アクセス許可を出しておきます。

### 13.2. 開発用 (Development) トリガーの作成

`main` ブランチへの Push をトリガーとして、開発用イメージ (`dev` タグ) をビルドします。

```powershell
gcloud builds triggers create github `
  --name="wax100-blog-main-ci" `
  --region=asia-northeast1 `
  --project=wax100 `
  --repository="projects/wax100/locations/asia-northeast1/connections/waxsd100/gitRepositoryLinks/wax100-blog" `
  --branch-pattern="^main$" `
  --build-config="cloudbuild-main.yaml" `
  --service-account="projects/wax100/serviceAccounts/cloudbuild-sa@wax100.iam.gserviceaccount.com"
```

### 13.3. リリース用 (Staging/Production) トリガーの作成

リリースタグ (`v*`ベース) の作成をトリガーとして、デプロイ用イメージ (`stg`, `prod` タグ) をビルドします。

```powershell
gcloud builds triggers create github `
  --name="wax100-blog-release-ci" `
  --region=asia-northeast1 `
  --project=wax100 `
  --repository="projects/wax100/locations/asia-northeast1/connections/waxsd100/gitRepositoryLinks/wax100-blog" `
  --tag-pattern="^v.*" `
  --build-config="cloudbuild-release.yaml" `
  --service-account="projects/wax100/serviceAccounts/cloudbuild-sa@wax100.iam.gserviceaccount.com"
```

> [!NOTE]
> アプリケーションのトリガー設定後、アプリケーションコードのコミットやタグ切りが行われると、Artifact Registry に配置されるコンテナのみが新しいものに差し替わります。

## 14. GitHub Environments の設定

GitHub Actions (`prod-deploy-status.yml` 等) で `environment: production` のように環境指定を行っている場合、GitHub リポジトリの設定で環境（Environments）を事前に作成しておく必要があります。作成されていない場合、ワークロードのバリデーションエラーが発生します。

### 14.1. gh CLI での作成

以下のコマンドで、必要な環境を一括作成できます。

```powershell
gh api --method PUT repos/waxsd100/k8s-platform/environments/development
gh api --method PUT repos/waxsd100/k8s-platform/environments/staging
gh api --method PUT repos/waxsd100/k8s-platform/environments/production
```

### 14.2. ブラウザでの作成

1. GitHub リポジトリの **Settings** タブを開く
2. 左サイドバーから **Environments** を選択
3. **New environment** をクリックし、`development`, `staging`, `production` をそれぞれ作成する

> [!TIP]
> 環境ごとに **Deployment branch policy** を設定したり、**Required reviewers** を設定することで、本番環境へのデプロイに追加の承認フローを挟むことが可能です。

---

## 15. GitHub App による認証設定

セキュリティ向上のため、Personal Access Token (PAT) の代わりに GitHub App を使用してリポジトリ間の操作を行います。

### 15.1. GitHub App の作成と設定

1. **GitHub App の作成**: [Settings > Developer settings > GitHub Apps](https://github.com/settings/apps) から新しい App を作成します。
   - **Permissions (Repository permissions)**:
     - `Contents`: Read & Write
     - `Pull requests`: Read & Write
     - `Deployments`: Read & Write
     - `Metadata`: Read-only (必須)
2. **非公開鍵の生成**: 作成した App の設定画面下部から `Private key` (.pem) を生成し、手元に保存します。
3. **App のインストール**: `Install App` メニューから、`wax100-blog` と `k8s-platform` の両方のリポジトリに App をインストールします。

### 15.2. Secrets の登録

各リポジトリ（または Organization 共通設定）の **Settings > Secrets and variables > Actions** に以下を登録します。

- **`GH_APP_ID`**: 作成した App の `App ID`
- **`GH_APP_PRIVATE_KEY`**: 保存した `.pem` ファイルの内容をそのまま貼り付けます。

---

## 16. 秘密情報の管理と漏洩防止 (Secret Scanning)

リポジトリに API キーやパスワード、非公開鍵などの機密情報が誤ってコミットされるのを防ぐため、CI パイプラインで **Gitleaks** による自動スキャンを実行しています。

### 16.1. 秘密情報の検知と対応

GitHub Actions の `Format and Lint` ワークフローが実行され、秘密情報が検知された場合は CI が失敗します。

- **検知された場合**:
  1. 該当する文字列をリポジトリから削除します。
  2. もし既に Push してしまった場合は、その秘密情報（APIキー等）を無効化（Revoke）し、新しいものに差し替えるのが鉄則です（Git の履歴を書き換えても一度流出したものは安全ではありません）。
- **誤検知（False Positive）への対応**:
  テスト用の文字列などでどうしても含める必要がある場合は、以下のいずれかの方法で除外します。
  - **行末コメント**: 秘密情報と同じ行に `# gitleaks:allow` コメントを記述します。
  - **.gitleaksignore**: リポジトリルートの `.gitleaksignore` に fingerprint を追加します。

> [!CAUTION]
> 本物のシークレットは絶対にコミットせず、必ず **Secret Manager** (GCP) か **GitHub Secrets** を利用してください。

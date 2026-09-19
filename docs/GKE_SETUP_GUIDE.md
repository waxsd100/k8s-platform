# GKE クラスタ構築手順書

ゼロからプラットフォームを立ち上げる手順です。**インフラは Terraform が構築し、クラスタ内のマニフェストは Config Sync が同期します。** 手動の `gcloud` 操作は、Terraform で扱えない箇所（ブラウザ認証が必要な Developer Connect、Secret の中身の登録）に限定しています。

コマンド例は PowerShell 前提です（行継続はバッククォート`` ` ``）。

## 1. 前提条件

| 項目 | 内容 |
| :--- | :--- |
| GCP プロジェクト | `wax100`（`terraform/variables.tf` の `project_id`） |
| リージョン / ゾーン | `asia-northeast1` / `asia-northeast1-a` |
| 必要ツール | `gcloud`, `terraform` (>= 1.5), `kubectl`, `kustomize` (v5), `helm` (v3), `yq`, `kubeconform`, `cargo-make` |
| 必要権限 | プロジェクトのオーナー、または相当する IAM 権限 |
| ドメイン | Cloudflare で管理しているゾーン（例: `wax100.io`） |

```powershell
gcloud auth login
gcloud config set project wax100
gcloud auth application-default login
```

## 2. Terraform で構築する範囲

`terraform apply` 一回で以下が作られます。

| ファイル | 内容 |
| :--- | :--- |
| `main.tf` | 必要な GCP API の有効化 |
| `network.tf` | VPC、サブネット、ファイアウォール、Cloud Router / NAT |
| `private-services.tf` | Cloud SQL 用の VPC ピアリング（Private Services Access） |
| `gke.tf` | GKE クラスタ本体と 3 種のノードプール |
| `canine.tf` | Cloud SQL for PostgreSQL、Secret Manager、Canine 用 GSA と Workload Identity |
| `registry-cache.tf` | Artifact Registry のリモートキャッシュ 4 種 |
| `secrets.tf` | Cloudflare 関連 Secret の「器」、ESO への参照権限 |
| `gitops.tf` | Config Sync 用 Artifact Registry、Cloud Build トリガー、Fleet メンバーシップ |
| `iam.tf` | ノード用サービスアカウントへの権限付与 |

### 2.1 apply

```powershell
cd terraform
terraform init
terraform plan
terraform apply
```

Cloud SQL インスタンスの作成に 10 分前後、クラスタとノードプールに 10〜15 分かかります。

> **Developer Connect の接続だけは事前にブラウザで作成が必要です。** `gitops.tf` の Cloud Build トリガーは、GitHub との接続（`var.github_account_name` の名前）が既に存在していることを前提にしています。GCP コンソールの Cloud Build → リポジトリ から GitHub 接続を作成してから apply してください。

### 2.2 作られるノードプール

| プール | 種別 | マシン | スケール | taint |
| :--- | :--- | :--- | :--- | :--- |
| `system-pool` | 通常 VM | e2-medium | 2〜3 | なし |
| `platform-{xs,sm,md,lg}` | Spot | e2-small 〜 e2-standard-4 | 各 0〜3 | `cloud.google.com/gke-spot=true:NoSchedule` |
| `apps-pool` | Spot | e2-medium（`apps_pool_machine_type`） | 0〜3（`apps_pool_max_nodes`） | なし |

`apps-pool` に taint を付けていない理由は `docs/ARCHITECTURE.md` の「4. ノードプール設計」を参照してください。

## 3. Secret の中身を登録する

Terraform は Secret の「器」だけを作ります。中身は手動で投入します（Terraform state に平文を残さないため）。

```powershell
# Cloudflare Tunnel のトークン（器は Terraform が作成済み。
# Cloudflare ダッシュボードで Tunnel を作成して取得した値を投入する）
"<TUNNEL_TOKEN>" | gcloud secrets versions add cloudflared-tunnel-token --data-file=-

# Cloudflare API トークン / Zone ID（器は Terraform が作成済み）
"<API_TOKEN>" | gcloud secrets versions add cloudflare-api-token --data-file=-
"<ZONE_ID>"   | gcloud secrets versions add cloudflare-zone-id --data-file=-
```

Canine の `canine-db-password` と `canine-secret-key-base` は Terraform が自動生成して投入済みです。手動登録は不要です。

## 4. kubectl の認証設定

```powershell
gcloud container clusters get-credentials wax100-platform `
  --zone asia-northeast1-a --project wax100

kubectl get nodes
```

## 5. Config Sync の開始

Terraform が済ませるのは **Fleet メンバーシップと Config Sync 機能の有効化まで**です。
同期の起点となる `RootSync` オブジェクト自体は、OCI イメージが存在してから手動で一度適用します（`fleet_default_member_config` にソース指定を持たせていないため）。

```powershell
# main にマージすると Cloud Build (manifest-sync) が発火する
git push origin main
```

手動でビルドを走らせる場合:

```powershell
gcloud builds submit --config=cloudbuild.yaml --project=wax100
```

ビルド完了後（Artifact Registry に `platform` タグが存在する状態で）、RootSync を適用します。

```powershell
kubectl apply -f clusters/platform/root-sync.yaml
```

以降は Config Sync が OCI イメージを継続的に Pull します。この 1 ファイルだけは
`clusters/platform/kustomization.yaml` の `resources` に含めていない（同期対象の中に
自分自身の起点を入れない）ため、ブートストラップ時の手動適用が必要です。

RootSync の状態確認:

```powershell
kubectl get rootsync -n config-management-system
kubectl describe rootsync root-sync-platform -n config-management-system
nomos status   # nomos CLI を入れている場合
```

## 6. Canine のセットアップ

`docs/CANINE_SETUP.md` を参照してください。要点のみ:

1. Cloudflare でトンネルに Public hostname を追加（`canine.wax100.io` → `http://canine.canine.svc.cluster.local:3000`）
2. ブラウザでアクセスしてアカウント作成
3. オンボーディングで in-cluster のクラスタ接続を選択
4. **Canine が入れようとする ingress / cert-manager / metrics-server はスキップする**（Cloudflare Tunnel と GKE 標準機能で足りるため）
5. Cloudflare Access で `canine.wax100.io` に認証を掛ける（Canine は cluster-admin 相当の権限を持つため必須）

## 7. 構築確認

```powershell
# ノードプールが揃っているか
kubectl get nodes -L node-pool,workload-type

# プラットフォーム構成要素
kubectl get pods -n kyverno
kubectl get pods -n external-secrets
kubectl get pods -n infra           # cloudflared
kubectl get pods -n canine          # canine (web) / canine-worker

# ESO が Secret を作れているか
kubectl get externalsecret -n canine
kubectl get secret canine -n canine -o jsonpath='{.data}' | Out-Null

# Kyverno のイメージ書き換えが効いているか
kubectl get pod -n canine -o jsonpath='{.items[*].spec.containers[*].image}'
# -> asia-northeast1-docker.pkg.dev/wax100/ghcr-cache/... になっていれば成功
```

## 8. トラブルシューティング

| 症状 | 原因と対処 |
| :--- | :--- |
| Canine の Pod が `CreateContainerConfigError` | ESO が Secret `canine` を作れていない。`kubectl describe externalsecret -n canine` で Secret Manager 側の値の有無を確認 |
| Canine が DB に接続できない | Cloud SQL Auth Proxy のログを確認。Workload Identity のバインディング（KSA `canine/canine` → GSA `canine-sa`）と `roles/cloudsql.client` を確認 |
| `ImagePullBackOff` | GAR のリモートキャッシュ（`registry-cache.tf`）が作られているか、ノードの SA に `roles/artifactregistry.reader` があるかを確認 |
| アプリ Pod が Pending のまま | `apps-pool` の上限（`apps_pool_max_nodes`）に到達、またはクラスタオートスケーラの `resource_limits`（CPU 16 / メモリ 64）に到達 |
| Cloud Build が失敗する | `kustomize build --enable-helm clusters/platform` をローカルで再現。Helm チャートの取得はビルド時にネットワークを使う |
| RootSync が同期しない | `config-sync-sa` の Workload Identity と、Artifact Registry の読み取り権限を確認 |

## 9. 完全削除 (Teardown)

```powershell
cd terraform

# 削除保護を外す（クラスタと Cloud SQL の両方）
# gke.tf: deletion_protection = false
# canine.tf: deletion_protection = false
terraform apply

terraform destroy
```

Secret Manager のシークレットと Artifact Registry のイメージは Terraform 管理外の版が残ることがあるため、必要に応じて手動で削除してください。

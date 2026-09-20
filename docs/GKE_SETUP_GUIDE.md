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
| `cloudflare-access.tf` | Canine UI を保護する Cloudflare Access のアプリとポリシー |
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
| `apps-pool` | Spot | e2-medium（`apps_pool_machine_type`） | 0〜3（`apps_pool_max_nodes`） | `cloud.google.com/gke-spot=true:NoSchedule` |

アプリ Pod には Kyverno が `nodeSelector: workload-type=app` と Spot の toleration を注入するため、**アプリは `apps-pool` にのみ載り、`system-pool` には載りません**。詳細は `docs/ARCHITECTURE.md` の「4. ノードプール設計」を参照してください。

## 3. Secret の中身を登録する

Terraform は Secret の「器」だけを作ります。中身は手動で投入します。

> **state には平文が入ります。** Canine の DB パスワードと `SECRET_KEY_BASE` は
> Terraform が生成して Secret Manager に投入するため、Cloudflare のトンネルトークンや
> API トークンと同じく **state に平文で残ります**。ローカルファイルのままにせず、
> `state-bucket.tf` のバケットを作って `terraform init -migrate-state` で GCS へ移してください。

> **Zone ID / Account ID は Secret Manager ではなく変数で渡します。**
> `cloudflare_zone_id` / `cloudflare_account_id` は機密ではないため、
> `terraform.tfvars` か `-var` で指定してください。**未設定だと Cloudflare の
> リソースが 1 つも作られず、しかもエラーになりません**（cloudflared が
> トークンを受け取れず CrashLoop します）。

> **apply は 2 段階になります。** Cloudflare のリソースは Secret Manager の
> `cloudflare-api-token` を読んでから作られるため、1 回目は Cloudflare 関連の変数を
> 空にして apply し、下の API トークンを登録してから、変数を設定して 2 回目を apply します。

```powershell
# Cloudflare API トークン（器は Terraform が作成済み）
# 必要な権限:
#   Account / Cloudflare Tunnel : Edit
#   Account / Zero Trust        : Edit
#   Account / Access: Apps and Policies : Edit
#   Zone    / DNS               : Edit
"<API_TOKEN>" | gcloud secrets versions add cloudflare-api-token --data-file=-

# アプリ定義スナップショット用の GitHub トークン
# （スナップショット先リポジトリの Contents: Read and write を持つ Fine-grained PAT）
"<GITHUB_PAT>" | gcloud secrets versions add canine-snapshot-github-token --data-file=-

# 昇格 PR 用の GitHub トークン
# （k8s-platform の Contents / Pull requests: Read and write を持つ Fine-grained PAT）
"<GITHUB_PAT>" | gcloud secrets versions add canine-promote-github-token --data-file=-
```

Canine の `canine-db-password` と `canine-secret-key-base` は Terraform が自動生成して投入済みです。
**`cloudflared-tunnel-token` も手動登録は不要です** — `cloudflare_manage_tunnel = true`（既定）なら
Terraform がトンネルを作り、そのトークンを Secret Manager に書き込みます。
ダッシュボードで作った既存のトンネルを使う場合だけ `cloudflare_manage_tunnel = false` と
`cloudflare_tunnel_id` を指定し、トークンを手で登録してください。

## 4. コントロールプレーンへの到達経路 (DNS エンドポイント + IAM)

コントロールプレーンには口が 2 つあります。本構成では次のように使い分けます。

| 口 | 状態 | 誰が使うか |
| :--- | :--- | :--- |
| IP エンドポイント | **内部のみ**（`private_control_plane_only = true`） | ノード、VPC 内部 |
| DNS エンドポイント | **有効**（`enable_dns_endpoint_external = true`） | 管理者の `kubectl`、CI |

外部 IP エンドポイントは無効で、認可ネットワークも空です。インターネットから IP で
コントロールプレーンに触ることはできません。

管理者は **DNS ベースエンドポイント**を使います。これは Google が提供する口で、
認可は**ネットワークではなく IAM**（`container.clusters.connect`）で行われます。
**クラスタ内の何にも依存しません** — `cloudflared` が落ちていても、ノードが 0 台でも
`kubectl` は通ります。踏み台も VPN も WARP も要りません。

> "Access to the control plane requires requests to be authenticated with a role with
> the new IAM permission `container.clusters.connect`."

### 4.1 アクセス権を付ける（初回のみ）

`terraform.tfvars` に列挙します。

```hcl
cluster_operator_members = [
  "user:<EMAIL>",
  # CI から触るなら
  # "serviceAccount:cloudbuild@wax100.iam.gserviceaccount.com",
]
```

`roles/container.developer`（`container.clusters.connect` を含む）が付きます。
Kubernetes 側の RBAC はこの IAM プリンシパルにマッピングされます。

**ここを空のままにすると、プロジェクトのオーナー権限を持つ人しか `kubectl` を
打てません。** 管理者を増やすときはこのリストに足して `terraform apply` するだけで、
端末側の作業はありません。

### 4.2 kubectl の設定

```powershell
gcloud auth login

gcloud container clusters get-credentials wax100-platform `
  --location asia-northeast1-a --project wax100 --dns-endpoint

kubectl get nodes
```

`--dns-endpoint` を付けると kubeconfig の `server` が Google の払い出す DNS 名になります。
認証は `gke-gcloud-auth-plugin` が毎回 `gcloud` の資格情報からトークンを取るため、
**接続を張りっぱなしにする概念がありません**。`gcloud auth login` が生きていれば打てます。

### 4.3 CI から触る

同じ経路をサービスアカウントで使えます。GitHub Actions なら Workload Identity 連携、
Cloud Build ならビルド用サービスアカウントに `roles/container.developer` を付けて、
同じ `get-credentials --dns-endpoint` を実行します。

### 4.4 守り方

ネットワークの壁が無い分、ここが防御線になります。

- **Google アカウントの 2 段階認証を必須にする。** 資格情報が漏れると、どこからでも
  コントロールプレーンに届きます。
- `container.clusters.connect` を持つプリンシパルを最小限に保つ。
- 境界が必要なら VPC Service Controls を被せる
  （`container.googleapis.com` と `kubernetesmetadata.googleapis.com` を
  restricted services に入れる）。その場合は
  `enable_dns_endpoint_external = false` にして、VPC 内部からのみ到達させます。

### 4.5 締め出されたら

**この経路では起きません。** DNS エンドポイントはクラスタの状態に依存しないため、
`cloudflared` が死んでも、ノードプールが 0 台でも、Config Sync が壊れても `kubectl` は通ります。
失うとしたら IAM 権限そのものなので、その場合はプロジェクトのオーナー権限で付け直します。

出典:
[New DNS-based endpoint for the GKE control plane](https://cloud.google.com/blog/products/containers-kubernetes/new-dns-based-endpoint-for-the-gke-control-plane) ·
[Customize your network isolation in GKE](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/latest/network-isolation)

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
kubectl apply -f bootstrap/root-sync.yaml
```

以降は Config Sync が OCI イメージを継続的に Pull します。このファイルが
`clusters/` ではなく `bootstrap/` にあるのは、**ライフサイクルが違う**ためです。
`clusters/platform/` の中身は Config Sync が繰り返し適用するもので、
root-sync.yaml はそれを起動するために人が 1 回打つものです。同期対象の中に
自分自身の起点は入れません。

RootSync の状態確認:

```powershell
kubectl get rootsync -n config-management-system
kubectl describe rootsync root-sync-platform -n config-management-system
nomos status   # nomos CLI を入れている場合
```

## 6. Canine のセットアップ

`docs/CANINE_SETUP.md` を参照してください。要点のみ:

1. `canine.wax100.io` のルーティングと DNS は Terraform が作成済み（`cloudflare-tunnel.tf`）。ダッシュボードでの追加作業は不要
2. ブラウザでアクセスしてアカウント作成
3. オンボーディングで in-cluster のクラスタ接続を選択
4. **Canine が入れようとする ingress / cert-manager / metrics-server はスキップする**（Cloudflare Tunnel と GKE 標準機能で足りるため）
5. Cloudflare Access は `terraform/cloudflare-access.tf` が作成済み（`cloudflare_account_id` と `canine_admin_emails` を設定して apply した場合）。未設定のまま公開しないこと

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

## 8. 運用手順

### 8.1 canine-db のリストア演習

**アプリケーションの定義は Git に存在せず、`canine-db` のバックアップが唯一の復旧経路です。** 構築直後に一度通しておかないと、バックアップがあること自体が保証になりません。

```powershell
# バックアップの一覧
gcloud sql backups list --instance=canine-db --project=wax100

# 検証用インスタンスへリストア（本番を上書きしないこと）
gcloud sql instances create canine-db-restore-test `
  --database-version=POSTGRES_16 --tier=db-g1-small --region=asia-northeast1 `
  --no-assign-ip --network=wax100-vpc --project=wax100

gcloud sql backups restore <BACKUP_ID> `
  --restore-instance=canine-db-restore-test --backup-instance=canine-db --project=wax100

# 確認できたら検証用インスタンスを削除する
gcloud sql instances delete canine-db-restore-test --project=wax100
```

PITR（ポイントインタイムリカバリ）は `--point-in-time` を指定した `gcloud sql instances clone` で行います。保持期間はトランザクションログ 7 日、バックアップ 7 世代です。

### 8.2 Artifact Registry のリモートキャッシュを手動作成済みの場合

`registry-cache.tf` のリポジトリが既に存在すると `terraform apply` は 409 で失敗します。state に取り込んでください。

```powershell
terraform import google_artifact_registry_repository.docker_hub_cache `
  projects/wax100/locations/asia-northeast1/repositories/docker-hub-cache
terraform import 'google_artifact_registry_repository.custom_caches["ghcr-cache"]' `
  projects/wax100/locations/asia-northeast1/repositories/ghcr-cache
```

### 8.3 state と実体のずれ

クラスタを手動で削除した後などは、state に存在しないリソースが残ります。`terraform plan` を必ず読み、消えている分は `terraform state rm <アドレス>` で整理してから apply してください。

### 8.4 Secret をローテーションしたとき

ESO が Secret を更新すると、**Reloader が対象の Deployment を自動で rollout restart します**（`reloader.stakater.com/auto: "true"` を付けた `canine` / `canine-worker` / `cloudflared`）。手動操作は不要です。反映は ESO の `refreshInterval`（1 時間）に依存するため、即座に反映したい場合だけ手動で再起動してください。

```powershell
# 即時反映したいとき
kubectl annotate externalsecret canine -n canine force-sync=$(Get-Date -UFormat %s) --overwrite
kubectl rollout status deployment/canine -n canine
```

### 8.5 dev から本番への昇格

Canine の dev 環境で確認できたら、Namespace にラベルを付けます。**必要なのは初回だけです。**

```powershell
kubectl label ns <app> wax100.io/promote=true
```

毎時 15 分に `canine-promote` の CronJob が動き、`components/apps/<app>/` を生成して
本リポジトリへ Pull Request を立てます。すぐ試したい場合は手動実行できます。

```powershell
kubectl create job --from=cronjob/canine-promote canine-promote-manual -n canine
kubectl logs -n canine job/canine-promote-manual -f
```

PR には以下が入ります。

| ファイル | 内容 | 再昇格時 |
| :--- | :--- | :--- |
| `base/resources.yaml` | dev の実体 | 上書きされる |
| `overlays/production/namespace.yaml` | `prod-<app>` | 上書きされる |
| `overlays/production/ingress.yaml` | `<app>.apps.wax100.io` での公開 | **保持** |
| `overlays/production/external-secret.yaml` | 参照 Secret の雛形 | **保持** |
| `overlays/production/kustomization.yaml` | overlay 本体 | **保持** |

**PR 本文にやることが書かれています** — 公開 URL、Secret Manager に登録が必要なシークレット ID、
PVC の警告。Secret を登録するまで本番の Pod は起動しません。

```powershell
# PR 本文に出た ID をそのまま登録する
"<VALUE>" | gcloud secrets create prod-<app>-<secret>-<key> --data-file=- --replication-policy=automatic
```

マージすると Config Sync が `prod-<app>` へ同期し、**以降その Namespace は Canine から
変更できなくなります**（Kyverno の `canine-namespace-boundary` が Admission で拒否）。
本番の変更は `components/apps/` への PR で行ってください。

**2 回目以降はラベル操作も不要です。** 一度 `components/apps/` に載ったアプリは、ジョブが
毎時 dev の状態と突き合わせ、差分があれば自動で追従 PR を立てます。同じアプリの PR が
開いている間は新しい PR を立てません。マージは常に手動です。

本番固有の差分（レプリカ数、リソース要求など）は `overlays/production/` に書いてください。
`base/resources.yaml` は再昇格のたびに上書きされます。

#### アプリの公開について

`*.apps.wax100.io` は Cloudflare Tunnel がまとめて ingress-nginx に流しているため、
**アプリごとに Cloudflare 側でやることはありません**。上表の `ingress.yaml` が Git に
入った時点で `https://<app>.apps.wax100.io` が有効になります。別のホスト名にしたい場合だけ
`ingress.yaml` の `host` を書き換え、その名前の DNS を Cloudflare に足してください。

### 8.6 アプリ定義のスナップショット

`canine-snapshot` の CronJob が毎日 JST 04:00 に、アプリ用 Namespace の実体を
`waxsd100/canine-apps-snapshot` へコミットします。Secret は RBAC 上読めないため含まれません。

```powershell
# 直近の実行結果
kubectl get cronjob canine-snapshot -n canine
kubectl logs -n canine -l job-name=$(kubectl get jobs -n canine -o jsonpath='{.items[-1:].metadata.name}')

# 手動実行
kubectl create job --from=cronjob/canine-snapshot canine-snapshot-manual -n canine
```

スナップショットからの復旧は `kubectl apply -f namespaces/<ns>.yaml`。**Canine の管理下には戻らない**（Canine の DB にはその記録が無い）ため、あくまで応急処置として使い、本復旧は `canine-db` のリストアで行います。

## 9. トラブルシューティング

| 症状 | 原因と対処 |
| :--- | :--- |
| Canine の Pod が `CreateContainerConfigError` | ESO が Secret `canine` を作れていない。`kubectl describe externalsecret -n canine` で Secret Manager 側の値の有無を確認 |
| Canine が DB に接続できない | Cloud SQL Auth Proxy のログを確認。Workload Identity のバインディング（KSA `canine/canine` → GSA `canine-sa`）と `roles/cloudsql.client` を確認 |
| `ImagePullBackOff` | GAR のリモートキャッシュ（`registry-cache.tf`）が作られているか、ノードの SA に `roles/artifactregistry.reader` があるかを確認 |
| アプリ Pod が Pending のまま | `apps-pool` の上限（`apps_pool_max_nodes`）に到達、またはクラスタオートスケーラの `resource_limits`（CPU 16 / メモリ 64）に到達 |
| Cloud Build が失敗する | `kustomize build --enable-helm clusters/platform` をローカルで再現。Helm チャートの取得はビルド時にネットワークを使う |
| RootSync が同期しない | `config-sync-sa` の Workload Identity と、Artifact Registry の読み取り権限を確認 |
| `kubectl` が 401 / 403 | `gcloud auth login` が切れているか、IAM に `container.clusters.connect`（`roles/container.developer` 等）が無い。`gcloud container clusters get-credentials ... --dns-endpoint` をやり直す |
| `kubectl` が接続できない | kubeconfig が内部 IP を指している可能性がある。`--dns-endpoint` 付きで `get-credentials` をやり直す |
| アプリが `apps-pool` 以外に載る | Kyverno の `pin-apps-to-apps-pool` が対象 Namespace を除外していないか確認（`kubectl get clusterpolicy pin-apps-to-apps-pool -o yaml`） |
| Canine が本番 Namespace を更新できない | 仕様です。`canine-namespace-boundary` が拒否しています。本番の変更は `components/apps/` への PR で行ってください |
| 昇格 PR が立たない | 初回はラベル（`kubectl get ns -l wax100.io/promote=true`）を確認。2 回目以降は `components/apps/<app>/` の有無を確認。**同じアプリの PR が開いていると新しい PR は立ちません**。ジョブのログと `canine-promote` Secret（PAT の権限）も確認 |
| 本番アプリが `CreateContainerConfigError` | `overlays/production/external-secret.yaml` が指す ID が Secret Manager に無い。`kubectl describe externalsecret -n prod-<app>` で不足している ID を確認 |
| `https://<app>.apps.wax100.io` が 404 | ingress-nginx まで届いて Ingress のホストに一致していない。`kubectl get ingress -n prod-<app>` の host と、Cloudflare のトンネル設定に `*.apps.wax100.io` があるかを確認 |

## 10. 完全削除 (Teardown)

```powershell
cd terraform

# 削除保護を外す（クラスタと Cloud SQL の両方）
# gke.tf: deletion_protection = false
# canine.tf: deletion_protection = false
terraform apply

terraform destroy
```

Secret Manager のシークレットと Artifact Registry のイメージは Terraform 管理外の版が残ることがあるため、必要に応じて手動で削除してください。

# GKE クラスタ構築手順書

ゼロからプラットフォームを立ち上げる手順です。**インフラは Terraform が構築し、クラスタ内のマニフェストは Config Sync が同期します。** 手動の `gcloud` 操作は、Terraform で扱えない箇所（ブラウザ認証が必要な Cloud Build の GitHub 接続、Secret の中身の登録）に限定しています。

コマンド例は PowerShell 前提です（行継続はバッククォート`` ` ``）。

## 1. 前提条件

| 項目                | 内容                                                                                                             |
| :------------------ | :--------------------------------------------------------------------------------------------------------------- |
| GCP プロジェクト    | `wax100`（`terraform/variables.tf` の `project_id`）                                                             |
| リージョン / ゾーン | `asia-northeast1` / `asia-northeast1-a`                                                                          |
| 必要ツール          | `gcloud`, `terraform` (>= 1.5), `kubectl`, `kustomize` (v5), `helm` (v3 以上), `yq`, `kubeconform`, `cargo-make` |

> CI（Cloud Build）は kustomize **5.8.1** / helm **4.3.0** でハイドレートします。ローカルでも同じ版を
> 推奨します。kustomize 5.8.0 以降は、helm が生成したリソースに `namespace:` が効かなくなる
> 変更が入っています（本リポジトリでは明示パッチで吸収済み）。
> | 必要権限 | プロジェクトのオーナー、または相当する IAM 権限 |
> | ドメイン | Cloudflare で管理しているゾーン（例: `wax100.io`） |

```powershell
gcloud auth login
gcloud config set project wax100
gcloud auth application-default login
```

## 2. Terraform で構築する範囲

以下を Terraform が作ります。**apply は 1 回では終わりません** — Cloudflare 関連は Secret Manager に
API トークンを入れてからの 2 回目、state の GCS 移行はバケット作成後に行います（§3 と下の 2.3）。

| ファイル               | 内容                                                                                                                |
| :--------------------- | :------------------------------------------------------------------------------------------------------------------ |
| `apis.tf`              | 必要な GCP API の有効化                                                                                             |
| `network.tf`           | VPC、サブネット、ファイアウォール、Cloud Router / NAT                                                               |
| `private-services.tf`  | Cloud SQL 用の VPC ピアリング（Private Services Access）                                                            |
| `gke.tf`               | GKE クラスタ本体と system / platform / apps の 3 プール                                                             |
| `build-pool.tf`        | Canine のビルダー専用プールと、その専用ノード SA                                                                    |
| `database.tf`          | 共有の Cloud SQL for PostgreSQL インスタンス `wax100-db`（今後のアプリも DB を作って使う）                          |
| `canine.tf`            | `wax100-db` の中の Canine 用 DB とユーザー、Secret Manager、Canine 用 GSA と Workload Identity                      |
| `storage.tf`           | GKE のワークロードが使う唯一の GCS バケット `wax100-platform`（ソフト削除 30 日。用途はマネージドフォルダで分ける） |
| `backup.tf`            | restic のリポジトリ（`gs://wax100-platform/restic/`）のマネージドフォルダと権限、restic の鍵                        |
| `registry-cache.tf`    | Artifact Registry のリモートキャッシュ 4 種                                                                         |
| `secrets.tf`           | Cloudflare API トークン・GitHub トークン等の Secret の「器」、ESO への参照権限                                      |
| `gitops.tf`            | Config Sync 用 Artifact Registry、Cloud Build トリガー、Fleet メンバーシップ                                        |
| `cloudflare-access.tf` | Canine UI・Headlamp・Backrest を保護する Cloudflare Access のアプリとポリシー                                       |
| `cloudflare-tunnel.tf` | Cloudflare Tunnel 本体・ルーティング・DNS、トンネルトークンの Secret Manager への書き込み                           |
| `iam.tf`               | ノード用サービスアカウント (`gke-node`) と、kubectl を打てる人 (`cluster_operator_members`)                         |
| `state-bucket.tf`      | Terraform state を置く GCS バケット（移行手順つき）                                                                 |

### 2.1 apply

```powershell
cd terraform
terraform init
terraform plan
terraform apply
```

Cloud SQL インスタンスの作成に 10 分前後、クラスタとノードプールに 10〜15 分かかります。

> **Cloud Build の GitHub 接続だけは事前にブラウザで作成が必要です。** `gitops.tf` の Cloud Build トリガーは、Cloud Build の**第 2 世代リポジトリ**（`projects/<project>/locations/asia-northeast1/connections/<接続名>/repositories/<リポジトリ名>`）が既に存在していることを前提にしています。GCP コンソールの Cloud Build → リポジトリ →「第 2 世代」で、リージョン `asia-northeast1`・接続名 `var.github_account_name` で GitHub 接続を作り（GitHub App のインストールと認可はブラウザで行う）、続けて `var.github_repo_platform` のリポジトリを**リンク**してから apply してください。
>
> トリガーの SA（`cloudbuild-sa`）に付けるのは、`config-sync-repo` への書き込み・ログ書き込み・リポジトリのトークン読み取り（`roles/cloudbuild.readTokenAccessor`）だけです。`roles/cloudbuild.builds.builder` は全リポジトリへの書き込みを含むため付けていません。

### 2.2 作られるノードプール

| プール          | 種別    | マシン                                                            | スケール                          | taint                              |
| :-------------- | :------ | :---------------------------------------------------------------- | :-------------------------------- | :--------------------------------- |
| `system-pool`   | 通常 VM | e2-medium（`system_pool_machine_type`）                           | 2〜3                              | なし                               |
| `platform-pool` | Spot    | e2-standard-2（`platform_pool_machine_type`）。Config Sync もここ | 1〜3（`platform_pool_max_nodes`） | `gke-spot:NoSchedule`              |
| `apps-pool`     | Spot    | e2-medium（`apps_pool_machine_type`）                             | 0〜3（`apps_pool_max_nodes`）     | `gke-spot:NoSchedule`              |
| `build-pool`    | Spot    | e2-standard-2（`build_pool_machine_type`）                        | 0〜1（`build_pool_max_nodes`）    | `gke-spot` + `workload-type=build` |

外からの入口（cloudflared / ingress-nginx）は **system-pool** に載ります。構築後、system の空き容量を確認してください。GKE 自身の kube-system がどれだけ使っているかは実機でしか分かりません。

```powershell
kubectl describe nodes -l workload-type=system | Select-String -Context 0,8 "Allocated resources"
```

実使用量は `kubectl top nodes -l workload-type=system` で見ます。常時 3 台（上限）になるなら余裕がありません。e2-small は、構築直後に GKE の部品だけで 3 台・メモリ 68〜101% になったため使えません。

```powershell
terraform apply -var="system_pool_machine_type=e2-medium"   # 恒久化するなら terraform.tfvars に書く
```

Config Sync は Kyverno が入った後に platform-pool へ移ります（`addons/kyverno/base/clusterpolicy-config-sync-placement.yaml`）。Kyverno が入る前に起動した Pod は system-pool に残るので、Kyverno が動き始めたら一度作り直してください。

```powershell
kubectl get pods -n config-management-system -o wide    # NODE が platform-pool か確認
kubectl delete pods -n config-management-system --all   # system-pool に残っていたら作り直す
kubectl delete pods -n config-management-monitoring --all
kubectl delete pods -n resource-group-system --all
```

アプリ Pod には Kyverno が `nodeSelector: workload-type=app` と Spot の toleration を注入するため、**アプリは `apps-pool` にのみ載り、`system-pool` には載りません**。詳細は `docs/ARCHITECTURE.md` の「4. ノードプール設計」を参照してください。

### 2.3 state を GCS に移す

state には Cloudflare の API トークン・トンネルトークン、Canine の DB パスワードと
`SECRET_KEY_BASE` が**平文で**入ります。初回 apply で `state-bucket.tf` のバケットが
できたら、ローカルから移してください。

```powershell
# terraform/providers.tf の backend "gcs" ブロックのコメントを外してから
terraform init -migrate-state
# 移行を確認したら、ローカルの terraform.tfstate と *.backup を削除する
```

## 3. Secret の中身を登録する

Terraform は Secret の「器」だけを作ります。中身は手動で投入します。

> **state には平文が入ります。** Canine の DB パスワードと `SECRET_KEY_BASE` は
> Terraform が生成して Secret Manager に投入するため、Cloudflare のトンネルトークンや
> API トークンと同じく **state に平文で残ります**。ローカルファイルのままにせず、
> `state-bucket.tf` のバケットを作って `terraform init -migrate-state` で GCS へ移してください。
>
> **Account ID・Zone ID・Access を通すメールアドレスは `variables.tf` の既定値に書いてあります。**
> 機密ではないので Secret Manager にも `terraform.tfvars` にも置きません。
>
> **ゾーンに既存の `*.wax100.io` があると 2 回目の apply が失敗します。** Terraform がワイルドカードの
> CNAME を作るため、同じ名前の A レコードなどは先にダッシュボードで消しておいてください。
>
> **apply は 2 段階になります。** Cloudflare のリソースは Secret Manager の
> `cloudflare-api-token` を読んでから作られるため、1 回目は `-var=cloudflare_account_id=` で
> Cloudflare を外して apply し、下の API トークンを登録してから、`-var` なしで 2 回目を apply します。
>
> **PowerShell で `"値" | gcloud ... --data-file=-` と書かないでください。** パイプで渡すと
> PowerShell が末尾に改行を足し、トークンに改行が入ったまま登録されます（認証が通らない）。
> 下の関数は、値を改行なし・BOM なしのファイルに書いてから登録します。

```powershell
# 値を画面に出さずに受け取り、改行なしで Secret Manager に登録する
function Add-SecretVersion([string]$Id, [switch]$Create) {
  $s = Read-Host -AsSecureString "$Id の値"
  $v = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
         [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
  $f = New-TemporaryFile
  try {
    [IO.File]::WriteAllText($f, $v)   # 改行なし・BOM なし
    if ($Create) {
      gcloud secrets create $Id --data-file=$f --replication-policy=user-managed --locations=asia-northeast1 --project=wax100
    } else {
      gcloud secrets versions add $Id --data-file=$f --project=wax100
    }
  } finally {
    Remove-Item $f
  }
}

# Cloudflare API トークン（器は Terraform が作成済み）
# 必要な権限:
#   Account / Cloudflare Tunnel : Edit
#   Account / Zero Trust        : Edit
#   Account / Access: Apps and Policies : Edit
#   Zone    / DNS               : Edit
Add-SecretVersion cloudflare-api-token

# 昇格 PR 用の GitHub トークン
# （k8s-platform の Contents / Pull requests: Read and write を持つ Fine-grained PAT）
Add-SecretVersion canine-promote-github-token
```

Canine の `canine-db-password` と `canine-secret-key-base` は Terraform が自動生成して投入済みです。
**`cloudflared-tunnel-token` も手動登録は不要です** — `cloudflare_manage_tunnel = true`（既定）なら
Terraform がトンネルを作り、そのトークンを Secret Manager に書き込みます。
ダッシュボードで作った既存のトンネルを使う場合だけ `cloudflare_manage_tunnel = false` と
`cloudflare_tunnel_id` を指定し、トークンを手で登録してください。

## 4. コントロールプレーンへの到達経路 (DNS エンドポイント + IAM)

コントロールプレーンには口が 2 つあります。本構成では次のように使い分けます。

| 口                 | 状態                                                | 誰が使うか             |
| :----------------- | :-------------------------------------------------- | :--------------------- |
| IP エンドポイント  | **内部のみ**（`private_control_plane_only = true`） | ノード、VPC 内部       |
| DNS エンドポイント | **有効**（`enable_dns_endpoint_external = true`）   | 管理者の `kubectl`、CI |

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
5. Cloudflare Access は `terraform/cloudflare-access.tf` が作成済み（`canine_admin_emails` のアドレスだけが通る）。未設定のまま公開しないこと。ログインに使う ID プロバイダを 1 つに決めているなら、その ID を `cloudflare_access_allowed_idps` に 1 件だけ書くと、選択画面を飛ばしてその IdP へ直接送られます（空なら Zero Trust に登録済みの全 IdP から選ぶ画面が出ます）

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

### 7.1 スケールアウト / スケールインの確認

ノードの増減はリソースの **requests** で決まります（実使用量ではない）。apps-pool を 0 台から増やし、0 台へ戻るところまで確かめます。

```powershell
# 1. 何も無い状態では apps-pool は 0 台
kubectl get nodes -l workload-type=app

# 2. アプリ用の Namespace に負荷用の Deployment を置く
#    requests を書かないのは意図的。Kyverno が既定の requests (100m / 128Mi) を入れ、
#    apps-pool 行きの nodeSelector と Spot の toleration も注入する。
kubectl create namespace scale-test
kubectl create deployment filler -n scale-test --image=registry.k8s.io/pause:3.10 --replicas=1
kubectl get pod -n scale-test -o jsonpath='{.items[0].spec.nodeSelector}{"\n"}{.items[0].spec.containers[0].resources}{"\n"}'
# -> {"workload-type":"app"} と {"requests":{"cpu":"100m","memory":"128Mi"}}

# 3. スケールアウト: e2-medium (1 台あたり CPU 約 940m) に入り切らない数へ増やす
kubectl scale deployment filler -n scale-test --replicas=20
kubectl get nodes -l workload-type=app -w      # 数分で 2〜3 台に増える（上限 apps_pool_max_nodes）
kubectl get events -n scale-test --field-selector reason=TriggeredScaleUp

# 4. スケールイン: 消して 10 分強待つと 0 台に戻る
kubectl delete namespace scale-test
kubectl get nodes -l workload-type=app -w
```

増えない・減らないときは、オートスケーラの判断理由をログで見ます。

```powershell
gcloud logging read 'logName="projects/wax100/logs/container.googleapis.com%2Fcluster-autoscaler-visibility"' `
  --project=wax100 --freshness=1h --limit=20 --format=json
# noScaleUp / noScaleDown の reason を見る。例:
#   no.scale.down.node.pod.kube.system.unmovable  kube-system の Pod が移せない（GKE 1.32.4 以降は 1 時間動いた Pod なら退避できる）
#   no.scale.down.node.pod.not.enough.pdb         PDB で退避できない
#   scale.up.error.quota.exceeded                  CPU などの割り当て不足
#   scale.up.error.out.of.resources                ゾーンに Spot の在庫が無い
```

各プールの想定:

| プール   | 平常時                                    | 増える条件                                                              | 減る条件                                                                                                |
| :------- | :---------------------------------------- | :---------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------ |
| system   | 2 台（作成時から 2 台）                   | cloudflared / ingress-nginx / kube-system の requests が 2 台に入らない | 3 台目の Pod が残り 2 台に収まる。cloudflared と ingress-nginx は必須の anti-affinity で 2 台に分かれる |
| platform | 1 台（作成時から 1 台）                   | Canine・Config Sync・Kyverno などの requests が 1 台に入らない          | 他のノードに収まる。Kyverno の admission は PDB（minAvailable 1）で 1 本ずつしか退避しない              |
| apps     | 0 台                                      | アプリの Pod が Pending                                                 | アプリが無くなれば 0 台                                                                                 |
| build    | 0 台（Build Cloud を入れている間は 1 台） | ビルダーの Pod が Pending                                               | ビルダーが無くなれば 0 台                                                                               |

NOTE: どのプールも単一ゾーン（`asia-northeast1-a`）です。Spot の在庫がそのゾーンで尽きると、オートスケーラは増やせずに待ちます（`scale.up.error.out.of.resources`）。

## 8. 運用手順

### 8.1 wax100-db のリストア演習

**Canine の dev アプリの定義は Git に存在せず、`wax100-db` のバックアップが唯一の復旧経路です。** バックアップはインスタンス単位なので、リストアすると同じインスタンスに DB を置いている他のアプリも同じ時点に戻ります（本番に向けてリストアする前に、影響するアプリを確認してください）。 構築直後に一度通しておかないと、バックアップがあること自体が保証になりません。

```powershell
# バックアップの一覧
gcloud sql backups list --instance=wax100-db --project=wax100

# 検証用インスタンスへリストア（本番を上書きしないこと）
gcloud sql instances create wax100-db-restore-test `
  --database-version=POSTGRES_16 --tier=db-g1-small --region=asia-northeast1 `
  --no-assign-ip --network=wax100-vpc --project=wax100

gcloud sql backups restore <BACKUP_ID> `
  --restore-instance=wax100-db-restore-test --backup-instance=wax100-db --project=wax100

# 確認できたら検証用インスタンスを削除する
gcloud sql instances delete wax100-db-restore-test --project=wax100
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

| ファイル                                   | 内容                                      | 再昇格時     |
| :----------------------------------------- | :---------------------------------------- | :----------- |
| `base/resources.yaml`                      | dev の実体                                | 上書きされる |
| `overlays/production/namespace.yaml`       | `prod-<app>`                              | 上書きされる |
| `overlays/production/ingress.yaml`         | `<app>.wax100.io` での公開                | **保持**     |
| `overlays/production/hpa.yaml`             | Deployment ごとの HPA（CPU 70%、2〜5 台） | **保持**     |
| `overlays/production/external-secret.yaml` | 参照 Secret の雛形                        | **保持**     |
| `overlays/production/kustomization.yaml`   | overlay 本体                              | **保持**     |

**PR 本文にやることが書かれています** — 公開 URL、Secret Manager に登録が必要なシークレット ID、
PVC の警告。Secret を登録するまで本番の Pod は起動しません。

```powershell
# PR 本文に出た ID をそのまま登録する（Add-SecretVersion は「3. Secret の中身を登録する」で定義）
Add-SecretVersion prod-<app>-<secret>-<key> -Create
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

`*.wax100.io` は Cloudflare Tunnel がまとめて ingress-nginx に流しているため、
**アプリごとに Cloudflare 側でやることはありません**。上表の `ingress.yaml` が Git に
入った時点で `https://<app>.wax100.io` が有効になります。別のホスト名にしたい場合だけ
`ingress.yaml` の `host` を書き換え、その名前の DNS を Cloudflare に足してください。

### 8.6 アプリ定義のバックアップ

dev のアプリ定義は Canine の DB にしかないため、CronJob `infra/manifest-backup` が毎日書き出しています（Secret は含まない）。
取り出し方と戻し方は [BACKUP.md](BACKUP.md) の 5.2 を見てください。

### 8.7 プラットフォームの requests を見直す

プラットフォームの Pod 数は固定で、ノード数は requests で決まります。requests が実際の使用量より小さいとノードに詰め込まれて溢れ、大きいと無駄にノードが増えます。GKE の VPA を**推奨値を出すだけ**のモード（`updateMode: "Off"`、`components/infrastructure/vpa-recommendations`）で動かしているので、数日動かしてから推奨値と今の requests を比べます。VPA は Pod を書き換えも再起動もしません。

```powershell
# 推奨値（target が目安。lowerBound〜upperBound が妥当な範囲）
kubectl get vpa -A
kubectl get vpa -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.recommendation.containerRecommendations[*].target}{"\n"}{end}'

# 今の requests
kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.template.spec.containers[*].resources.requests}{"\n"}{end}'
```

差が大きいものは、そのコンポーネントのマニフェスト（Helm の values など）の requests を直して PR を出します。Git が真実の源なので、VPA に自動で書き換えさせません。
アプリには VPA を付けません（HPA が CPU で台数を変えるので、同じ指標で VPA を重ねない）。

### 8.8 アプリの DB とバックアップ

アプリの DB は **dev も本番もクラスタ内**に置きます（Cloud SQL の wax100-db は Canine 本体専用）。
毎日 JST 03:30 に CronJob `infra/db-backup` が全 DB の論理ダンプを取り、restic で GCS 上のリポジトリに送ります（[BACKUP.md](BACKUP.md)）。

#### DB の作り方（Canine のアドオン）

Canine の Add-on で、**公式イメージを使うチャート**を選びます。

| DB                  | チャート（Helm リポジトリ `https://groundhog2k.github.io/helm-charts/`） | イメージ                                                                                           |
| :------------------ | :----------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------- |
| PostgreSQL          | `groundhog2k/postgres`                                                   | 公式 `postgres`                                                                                    |
| MySQL（Ghost など） | `groundhog2k/mysql`                                                      | 公式 `mysql`。Ghost なら `image.tag` を `8.0` にする（Ghost の CI が使う版。チャートの既定は 9.x） |
| MariaDB             | `groundhog2k/mariadb`                                                    | 公式 `mariadb`                                                                                     |

- **Bitnami のチャート（`bitnami/postgresql`・`bitnami/mysql`）は使わないでください。** Bitnami は 2025 年 8 月に無料イメージの配布を縮小し、
  `docker.io/bitnami/mysql` にはタグが残っておらず、`bitnami/postgresql` も `latest` だけです。バックアップの対象にもなりません
- values で **`storage.requestedSize`（例: `5Gi`）を必ず指定**してください。指定しないとデータは Pod の一時領域に置かれ、再起動で消えます
- パスワードは `settings.superuserPassword.value`（postgres）/ `settings.rootPassword.value`（mysql・mariadb）で指定します
- DB は同じ Namespace にも別の Namespace にも、何台立ててもかまいません。バックアップは見つけたものを全部取ります
- **Namespace はアプリと同じにします。** 作成画面の「+ Add namespace configuration」で Namespace にアプリの Namespace 名を入れ、
  「Automatically create namespace」を外します。こうすると昇格ジョブがアプリと一緒に DB（StatefulSet と PVC）も本番へ持ち込み、
  本番は `prod-<app>` の中に DB が立ちます（中身は空。パスワードは PR 本文の ID で Secret Manager に登録）。
  別の Namespace に入れた DB は本番に持ち込まれません
- DB の Pod も apps-pool（Spot）に載ります。回収されるとしばらく止まりますが、データは Persistent Disk にあるので消えません

#### バックアップと戻し方

DB は dev・本番とも毎日自動で取られます（本番の PVC のファイルも）。仕組み・構築直後の確認・戻し方は [BACKUP.md](BACKUP.md) にまとめています。

### 8.9 Headlamp（dashboard.wax100.io）にログインする

Cloudflare Access を通ったあと、トークンを求められる。トークンは期限付きで発行する。

```powershell
kubectl create token headlamp-user -n headlamp --duration=24h
```

権限はクラスタ全体が `view`（Secret は見えない）、`edit` は Canine が作った Namespace（`caninemanaged=true`）と `prod-*` だけ（`addons/kyverno/base/clusterpolicy-headlamp-edit.yaml`）。本番のリソースで Git に書かれている値を GUI で変えても、Config Sync が Git の値に戻す。

### 8.10 kube-dns から Cloud DNS に切り替える（既存クラスタで 1 回だけ）

クラスタ内の名前解決は Cloud DNS for GKE に任せます（`terraform/gke.tf` の `dns_config`）。
kube-dns は 2 本で CPU 540m を要求し、taint の無い system-pool にしか載らないため、e2-medium の system-pool が
3 台に増えて減らない原因になっていました（各ノードの常駐 Pod だけで割り当て枠 940m のうち約 500m を使う）。

**`terraform apply` だけでは何も軽くなりません。** 次の 2 つは GKE の仕様です
（[Cloud DNS for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/cloud-dns)）。

- Pod が Cloud DNS を使い始めるのは、ノードが**新しい版**に上がったとき（または新しいノードプールを作ったとき）だけ。
  **同じ版への upgrade では切り替わらない**。オートスケーラが足した同じ版のノードも切り替わらない
- kube-dns は Cloud DNS を有効にした後も動き続ける。止めるには kube-dns とそのオートスケーラを手で 0 本にする。
  **全プールが切り替わる前に 0 本にすると、切り替わっていない Pod の名前解決が壊れる**

#### 1. apply の前に、今の版を控える

```bash
cluster=wax100-platform; loc=asia-northeast1-a
gcloud container clusters describe "${cluster}" --location "${loc}" --format='value(currentMasterVersion)'
gcloud container node-pools list --cluster "${cluster}" --location "${loc}" --format='table(name,version)'
```

#### 2. `terraform apply`

`google_container_cluster.primary` の `dns_config` の変更（in-place）と、`dns.googleapis.com` の有効化だけが出ることを plan で確かめます。

#### 3. 全プールを新しい版に上げる

（`cluster` と `loc` は 1 で決めたもの）

ノードの版がコントロールプレーンより古いプールは、そのまま上げれば切り替わります（版を省くとコントロールプレーンの版になる）。
サージ更新なので 1 台ずつ入れ替わり、止まりません。

```bash
for pool in system-pool platform-pool apps-pool build-pool; do
  gcloud container clusters upgrade "${cluster}" --location "${loc}" --node-pool "${pool}" --quiet
done
```

1 の時点でノードとコントロールプレーンの版が同じだったプールは、上の upgrade では切り替わりません。
次の自動アップグレード（STABLE チャンネル）で新しい版に上がるのを待つか、先にコントロールプレーンを
チャンネル内の新しい版へ上げてから、上のループをもう一度流します。

```bash
# STABLE で選べる版（currentMasterVersion より新しいものを使う）
gcloud container get-server-config --location "${loc}" --flatten=channels \
  --filter='channels.channel=STABLE' --format='value(channels.validVersions)'
gcloud container clusters upgrade "${cluster}" --location "${loc}" --master --cluster-version <新しい版> --quiet
```

**全プールの版が 1 で控えたものから変わるまで、4 に進まないでください。**

```bash
gcloud container node-pools list --cluster "${cluster}" --location "${loc}" --format='table(name,version)'
```

#### 4. kube-dns を止める

オートスケーラを先に止めます（先に kube-dns を 0 にすると、オートスケーラが戻してしまう）。

```bash
kubectl scale deployment kube-dns-autoscaler -n kube-system --replicas=0
kubectl scale deployment kube-dns -n kube-system --replicas=0
```

すぐに、各プールの Pod から名前が引けることを確かめます。

```bash
# platform-pool
kubectl exec -n infra deploy/backrest -- nslookup rest-server.infra.svc.cluster.local
# system-pool（infra は Kyverno の振り分けの対象外なので nodeSelector がそのまま効く）
kubectl run dnstest -n infra --rm -it --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"nodeSelector":{"workload-type":"system"}}}' -- nslookup kubernetes.default.svc.cluster.local
# apps-pool（default は Kyverno が apps-pool に振り分ける。0 台ならノードが起きるまで数分待つ）
kubectl run dnstest -n default --rm -it --restart=Never --pod-running-timeout=10m --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local
```

1 つでも引けなければ、すぐに戻して 3 をやり直します。

```bash
kubectl scale deployment kube-dns-autoscaler -n kube-system --replicas=1
```

#### 5. system-pool が 2 台に戻ったことを確かめる

```bash
kubectl describe nodes -l node-pool=system-pool | grep -E "^Name:|^  cpu  "
```

オートスケーラが 2 台に戻します。20 分ほど待っても 3 台のままなら、手で 2 台にします
（入口の cloudflared / ingress-nginx は 2 本を別ノードに置くので、2 台より減らさないこと）。

```bash
gcloud container clusters resize "${cluster}" --location "${loc}" --node-pool system-pool --num-nodes 2
```

kube-dns は GKE が管理する部品で、Git では 0 本を保てません。念のため、クラスタのアップグレードの後は
`kubectl get deploy -n kube-system kube-dns kube-dns-autoscaler` で 0 本のままかを確かめ、戻っていれば 4 のコマンドで止め直してください。

## 9. トラブルシューティング

| 症状                                             | 原因と対処                                                                                                                                                                                                                                 |
| :----------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Canine の Pod が `CreateContainerConfigError`    | ESO が Secret `canine` を作れていない。`kubectl describe externalsecret -n canine` で Secret Manager 側の値の有無を確認                                                                                                                    |
| Canine が DB に接続できない                      | Cloud SQL Auth Proxy のログを確認。Workload Identity のバインディング（KSA `canine/canine` → GSA `canine-sa`）と `roles/cloudsql.client` を確認                                                                                            |
| `ImagePullBackOff`                               | GAR のリモートキャッシュ（`registry-cache.tf`）が作られているか、ノードの SA に `roles/artifactregistry.reader` があるかを確認                                                                                                             |
| アプリ Pod が Pending のまま                     | `apps-pool` の上限（`apps_pool_max_nodes`）に到達。クラスタ全体の `resource_limits` は**設定していません**（手動プールの合計にも効き、各プールの上限より先に頭打ちになるため）                                                             |
| Cloud Build が失敗する                           | `kustomize build --enable-helm clusters/platform` をローカルで再現。Helm チャートの取得はビルド時にネットワークを使う                                                                                                                      |
| RootSync が同期しない                            | `config-sync-sa` の Workload Identity と、Artifact Registry の読み取り権限を確認                                                                                                                                                           |
| `kubectl` が 401 / 403                           | `gcloud auth login` が切れているか、IAM に `container.clusters.connect`（`roles/container.developer` 等）が無い。`gcloud container clusters get-credentials ... --dns-endpoint` をやり直す                                                 |
| `kubectl` が接続できない                         | kubeconfig が内部 IP を指している可能性がある。`--dns-endpoint` 付きで `get-credentials` をやり直す                                                                                                                                        |
| アプリが `apps-pool` 以外に載る                  | Kyverno の `pin-apps-to-apps-pool` が対象 Namespace を除外していないか確認（`kubectl get clusterpolicy pin-apps-to-apps-pool -o yaml`）                                                                                                    |
| Canine のビルドが始まらない / ビルダーが Pending | ビルダーは `build-pool` にしか載らない。Canine の Build Cloud 設定で指定した CPU / メモリの要求が `build_pool_machine_type` の割当可能量を超えていないか確認。`kubectl get pods -n canine-k8s-builder -o wide`                             |
| cloudflared か ingress-nginx の 2 本目が Pending | 必須の anti-affinity で別ノードを要求している。`system-pool` が 1 台しか居ない（障害中など）と 2 本目は載らない。オートスケーラが 2 台目を起こすまで待つ                                                                                   |
| Canine が本番 Namespace を更新できない           | 仕様です。`canine-namespace-boundary` が拒否しています。本番の変更は `components/apps/` への PR で行ってください                                                                                                                           |
| 昇格 PR が立たない                               | 初回はラベル（`kubectl get ns -l wax100.io/promote=true`）を確認。2 回目以降は `components/apps/<app>/` の有無を確認。**同じアプリの PR が開いていると新しい PR は立ちません**。ジョブのログと `canine-promote` Secret（PAT の権限）も確認 |
| 本番アプリが `CreateContainerConfigError`        | `overlays/production/external-secret.yaml` が指す ID が Secret Manager に無い。`kubectl describe externalsecret -n prod-<app>` で不足している ID を確認                                                                                    |
| `https://<app>.wax100.io` が 404                 | ingress-nginx まで届いて Ingress のホストに一致していない。`kubectl get ingress -n prod-<app>` の host と、Cloudflare のトンネル設定に `*.wax100.io` があるかを確認                                                                        |

## 10. 完全削除 (Teardown)

```powershell
cd terraform

# 削除保護を外す（クラスタと Cloud SQL の両方）
# gke.tf: deletion_protection = false
# database.tf: deletion_protection = false と settings の deletion_protection_enabled = false
terraform apply

terraform destroy
```

Secret Manager のシークレットと Artifact Registry のイメージは Terraform 管理外の版が残ることがあるため、必要に応じて手動で削除してください。

restic の鍵（`random_password.restic_repository`）には `prevent_destroy` を付けているので、`terraform destroy` は止まります。
本当に消すときは、必要なダンプを手元に取ってから `terraform/backup.tf` の `prevent_destroy` を外して apply し、
バケット `wax100-platform` を `gcloud storage rm -r gs://wax100-platform/**` で空にしてから、もう一度 `terraform destroy` を実行します。
（ソフト削除で残った分はバケットごと消えるときに消えます。）

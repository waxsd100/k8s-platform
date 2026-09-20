# Canine on GKE セットアップガイド

[Canine](https://github.com/CanineHQ/canine) は Kubernetes 上に Heroku 風の PaaS 体験を載せる OSS
（Rails + GoodJob + PostgreSQL）。本リポジトリでは **クラスタ内モード（`BOOT_MODE=cluster`）** で
platform クラスタに常駐させ、自分自身が乗っているクラスタを管理対象とする構成を取る。

## 構成概要

| 要素 | 選択 | 理由 |
| --- | --- | --- |
| 配置 | GKE platform ノードプール上の Deployment (web / worker) | Config Sync 管理下に置ける |
| DB | Cloud SQL for PostgreSQL + Cloud SQL Auth Proxy (native sidecar) | Private IP のみ、kubeconfig も資格情報も持ち回らない |
| 公開 | Cloudflare Tunnel (`cloudflared`) | LB 固定費 $0、外部 IP 不要 |
| 認証情報 | Secret Manager + External Secrets Operator | 既存 `gcp-secret-store` を再利用 |
| クラスタ接続 | In-cluster ServiceAccount トークン | kubeconfig をどこにも保存しない |
| 守備範囲 | dev / プレビュー環境のみ | 本番は Git (`components/apps/`) と Config Sync が管理し、Canine は Admission で締め出される |

### ファイル構成

公式 Helm チャート (`https://caninehq.github.io/canine`) を `helmCharts:` で取り込み、
チャートに足りない部分だけを Kustomize パッチで補う構成。
`addons/kyverno` や `addons/external-secrets` と同じ書き方に揃えてある。

```
components/infrastructure/canine/
├── base/
│   ├── kustomization.yaml    # helmCharts: canine 0.1.10 + valuesInline + パッチ定義
│   ├── namespace.yaml
│   ├── external-secret.yaml  # Secret "canine" (secret-key-base / DATABASE_URL) を供給
│   ├── pvc.yaml              # Active Storage 用 10Gi (チャートには PVC が無い)
│   ├── web-patch.yaml        # Probe / PVC マウント / Cloud SQL Proxy サイドカー
│   └── worker-patch.yaml     # Cloud SQL Proxy サイドカー
└── overlays/production/
    ├── kustomization.yaml
    ├── hostname-web-patch.yaml     # APP_HOST / ALLOWED_HOSTNAME
    └── hostname-worker-patch.yaml

terraform/canine.tf              # Cloud SQL / Secret Manager / GSA / Workload Identity
clusters/platform/kustomization.yaml に overlays/production を登録済み
```

### チャートをそのまま使えない箇所と対処

| チャートの挙動 | 問題 | 対処 |
| --- | --- | --- |
| `templates/secret.yaml` が `lookup` で既存 Secret を探し、無ければ `randAlphaNum 64` | `lookup` はクラスタ非接続の `kustomize build --enable-helm` では常に空。Hydrate のたびに `SECRET_KEY_BASE` が変わりセッション/暗号化データが壊れる | チャートの Secret を `$patch: delete` し、同名・同キーの Secret を ExternalSecret で供給 |
| `DATABASE_URL` を `postgresql.auth.*` から直書き（外部 DB 用の値が無い） | Cloud SQL に向けられない。values に平文パスワードが載る | JSON Patch で env を丸ごと `secretKeyRef` に置換。`op: test` で index ずれを検知して build を失敗させる |
| `postgresql` / `cert-manager` / `traefik` をサブチャートで同梱 | Cloud SQL と二重になり、公開経路も Cloudflare Tunnel と衝突する | すべて `enabled: false` |
| Probe が未定義 | 起動途中の Pod に振り分けられる | `web-patch.yaml` で startup/readiness/liveness を追加 |
| DB プロキシの起動順序 | 通常のサイドカーだと Rails の `db:prepare` が先に走り CrashLoopBackOff を挟む | Cloud SQL Auth Proxy を native sidecar（`initContainers` + `restartPolicy: Always`、Kubernetes 1.29+）として定義 |
| PVC が無い | 再起動で Active Storage の中身が消える | `pvc.yaml` + マウントを追加 |
| ClusterRole が `apiGroups/resources/verbs: ["*"]` | 実質 cluster-admin | 仕様。Cloudflare Access での保護を推奨 |

## 前提の確認事項

- `RAILS_ENV=production` のとき Canine は `config/database.yml` の
  `database: canine_production` / `username: canine` を使う。Terraform 側の DB 名・ユーザー名は
  これに合わせてある。
- 公式イメージの ENTRYPOINT (`bin/docker-entrypoint`) は、コマンドが `./bin/rails server`
  のときだけ `db:create` / `db:prepare` を実行する。チャートの web Deployment は
  `command` を指定せずイメージ既定の CMD を使うため、起動時にマイグレーションが走る。
  そのため別途マイグレーション Job は置いていない（`strategy: Recreate` にしてある）。
- `BOOT_MODE=cluster` では `K8::Connection.in_cluster?` が
  `KUBERNETES_SERVICE_HOST` と ServiceAccount トークンの存在で判定され、in-cluster kubeconfig が
  自動生成される。オンボーディング画面に「このクラスタを接続」の導線が出る。
- クラスタ内モードのビルダーは `k8s` 固定（`BuildConfiguration::BUILDER_OPTIONS`）。
  Docker ソケットのマウントは不要。

## 手順

### 1. Terraform apply

```powershell
cd terraform
terraform init
terraform apply -target="google_sql_database_instance.canine_db" `
                -target="google_sql_database.canine" `
                -target="google_sql_user.canine" `
                -target="google_secret_manager_secret_version.canine_db_password_version" `
                -target="google_secret_manager_secret_version.canine_secret_key_base_version" `
                -target="google_service_account_iam_member.canine_workload_identity" `
                -target="google_project_iam_member.canine_sql_client"
```

Cloud SQL インスタンスの作成には 10 分前後かかる。

> `canine_db_tier` は既定 `db-g1-small`（約 $25/月）。最小構成にする場合は
> `-var="canine_db_tier=db-f1-micro"` を指定するが、0.6 GiB では web + worker の
> 同時接続で不安定になりやすい。

### 2. Cloudflare Tunnel のルーティング

**トンネル本体もルーティングも Terraform が作る**（`terraform/cloudflare-tunnel.tf`）。
トークンは Secret Manager に自動で書き込まれ、ESO 経由で cloudflared に渡るため、
ダッシュボードでトンネルを作ってトークンをコピーする作業は無い。

| hostname | 転送先 |
| :--- | :--- |
| `canine.wax100.io` | `http://canine.canine.svc.cluster.local:3000` |
| `*.apps.wax100.io` | `http://ingress-nginx-controller.infra.svc.cluster.local:80` |
| （その他） | 404 |

DNS もワイルドカード CNAME 1 件を Terraform が作るため、**アプリを増やしたときに
Cloudflare 側でやることは何もない**。アプリは `Ingress` を 1 つ持てば公開される。

有効化には `cloudflare_account_id` と `cloudflare_zone_id`、そして Secret Manager の
`cloudflare-api-token` が必要。未設定なら何も作られないので、その場合だけ手動設定する。
既存のトンネルを使い回す場合は `cloudflare_manage_tunnel = false` と `cloudflare_tunnel_id` を指定する。

Cloudflare が担うのは**公開の口だけ**。管理者の `kubectl` は GKE の DNS ベース
エンドポイント（IAM 認可）を使うため、WARP も Private Network ルートも使わない。
詳細は `docs/GKE_SETUP_GUIDE.md` §4。

`overlays/production/hostname-*-patch.yaml` の `APP_HOST` / `ALLOWED_HOSTNAME` を
実際に割り当てるホスト名に合わせて変更すること。

### 3. マニフェストの検証とコミット

```powershell
cargo make pre-commit   # validate (kubeconform) + hydrate (_result.json 生成)
git add .
git commit -m "feat: add Canine PaaS control plane"
git push
```

Cloud Build が `clusters/platform` を Hydrate し、Config Sync が `platform` タグの OCI イメージを同期する。

### 4. 初期セットアップ

1. `https://canine.wax100.io` にアクセスしてアカウントを作成
2. オンボーディングで「in-cluster」のクラスタ接続を選択
3. Canine が ingress / cert-manager / metrics-server 等の依存アドオンを
   インストールしようとするが、**いずれもスキップする**。公開は Cloudflare Tunnel、
   メトリクスは GKE 標準のもので足りるため
4. アカウント作成後は追加サインアップを塞ぐため、`ACCOUNT_SIGN_IN_ONLY=true` を
   env パッチで追加して再デプロイする（チャートには対応する values が無い）

## 運用上の注意

- **RBAC**: チャートの ClusterRole は全リソース・全 verb を許可する（実質 cluster-admin）。
  Cloudflare Tunnel 経由とはいえインターネット公開されるため、Cloudflare Access（Zero Trust）で
  `canine.wax100.io` に認証を掛けることは**必須**。UI を奪われるとクラスタ全体を奪われる。
- **Kyverno のイメージ書き換え**: `ghcr.io/caninehq/canine` は ClusterPolicy により
  `asia-northeast1-docker.pkg.dev/<PROJECT_ID>/ghcr-cache/` に書き換えられる。
  GAR のリモートリポジトリ `ghcr-cache` が存在することを確認すること。
- **イメージタグ**: 公式は `latest` 運用だが、本構成ではダイジェストで固定している
  （`tag: latest@sha256:...`）。固定しないと Spot ノードの再作成のたびに別バージョンを引き、
  web と worker で版がずれてマイグレーション済みスキーマと食い違う。
  更新するときは `crane digest ghcr.io/caninehq/canine:latest` で取得した値に差し替える。
- **チャートのアップグレード**: `base/kustomization.yaml` の `version: 0.1.10` を上げると、
  差分が `_result.json` に現れて PR でレビューできる。上げた際は
  `op: test` のガード（DATABASE_URL の env index）が通るかを必ず確認すること。
- **Spot ノード**: web は RWO PVC と Recreate 戦略のため、退避時に数十秒〜数分の
  ダウンタイムが発生する。Canine が管理しているアプリ自体は影響を受けない（Canine はコントロールプレーンのみ）。

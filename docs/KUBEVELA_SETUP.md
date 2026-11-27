# KubeVela / VelaUX on GKE セットアップガイド

[KubeVela](https://kubevela.io/)（`vela-core` `1.12.0-alpha.3`）と VelaUX（`ghcr.io/waxsd100/velaux:kubevela-1.12-ja`、`waxsd100/velaux` の `feat/kubevela-1.12` ブランチからビルド）を、シングルクラスタ構成（`multicluster.enabled: false`）かつ外部 DB レス（`--datastore-type=kubeapi`・`--datastore-database=velaux-store`）で GKE 上に構築・運用するためのガイドです。開発環境（Dev）は VelaUX の Web UI から作成・編集でき、本番環境（`prod-*`）は Config Sync による GitOps 管理と VelaUX 上の読取専用可視化（`Production (GitOps Read-Only)`）を両立させます。

## 1. 構成概要

| 要素                 | 選択                                                                                    | 理由                                                                                                                                      |
| :------------------- | :-------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------- |
| コントロールプレーン | `vela-core` `1.12.0-alpha.3`（`addons/kubevela/base`、`vela-system`）                   | シングルクラスタ専用（`multicluster.enabled: false`）で運用し、厳選 48 定義（5 SourceDefinition 含む）と CEL 式 / Definition 継承を提供   |
| Web UI / API         | `velaux-server` `kubevela-1.12-ja`（`components/infrastructure/velaux`、`vela-system`） | `platform-pool`（Spot）で動作するステートレス Deployment（RWO PVC なし）。`vela-core` と合わせた requests 合計は `150m` CPU / `256Mi` RAM |
| データストア         | Kubernetes API（`velaux-store` Namespace の ConfigMap）                                 | 外部 Cloud SQL 不要（コスト `$0`）。`velaux-store` は Secret 相当として隔離し、`infra/manifest-backup` で毎日暗号化バックアップ           |
| 公開・認証           | Cloudflare Tunnel + Cloudflare Access + VelaUX ローカル認証                             | `https://vela.wax100.io` → `velaux-server.vela-system:8000`。Access（`platform_admin_emails`）と `origin_request.access` JWT 検証で保護   |
| 権限・境界           | 最小権限 RBAC + API サーバー組み込み VAP 3 種 + Kyverno 境界 2 種                       | `cluster-admin` 不使用。`velaux-cluster-boundary`・`vela-core-cluster-boundary`・`vela-application-guard` 等で多層防御                    |
| 守備範囲             | Dev は GUI 編集可、本番（`prod-*`）は GitOps + 読取専用可視化                           | Dev は `usage.oam.dev/runtime=target` ラベルで識別し gVisor 実行。本番は `Production (GitOps Read-Only)` で状態・トポロジ・ログ閲覧のみ   |

### ファイル構成

```text
addons/kubevela/
├── base/
│   ├── kustomization.yaml       # vela-core 1.12.0-alpha.3 Helm チャート + digest pin + セキュリティパッチ
│   ├── namespace.yaml           # vela-system (PSS enforce: baseline, warn/audit: restricted)
│   ├── rbac.yaml                # 最小権限 ClusterRole kubevela-vela-core:manager
│   ├── networkpolicy.yaml       # Ingress (Webhook :9443) + Egress 制限
│   └── definitions/             # 厳選 48 定義 (5 Component / 25 Trait / 6 Policy / 7 WorkflowStep / 5 Source)
└── config-templates/
    ├── kustomization.yaml       # Kustomize images FieldSpec 衝突回避のため分離した ConfigTemplate 群
    └── vela-core-http-deny.yaml # 1.12 同梱の ConfigTemplate (vela-core-http-deny)

components/infrastructure/velaux/
├── base/
│   ├── kustomization.yaml
│   ├── namespace.yaml           # velaux-store (PSS enforce/warn/audit: restricted、Pod なし)
│   ├── deployment.yaml          # ghcr.io/waxsd100/velaux:kubevela-1.12-ja@sha256:... (kubeapi datastore)
│   ├── service.yaml             # velaux-server (ClusterIP :8000)
│   ├── rbac.yaml                # velaux-minimal + velaux-store-datastore + 事前作成 kubevela:writer*
│   ├── networkpolicy.yaml       # velaux-allow-from-cloudflared (:8000) + Egress + velaux-store-deny-all
│   ├── production-project.yaml  # ConfigMap/pj-production (owner: admin, Production GitOps Read-Only)
│   ├── develop-project.yaml     # ConfigMap/pj-develop (owner: admin, Develop)
│   ├── views.yaml               # 8 VelaQL ビュー ConfigMap (3 件ハードニング + 1 件空スタブ化)
│   ├── reports.yaml             # 12 ビルトインレポート ConfigMap (GitOps 事前配置)
│   └── schemas.yaml             # 14 UI スキーマ ConfigMap
└── overlays/production/
    └── kustomization.yaml

components/infrastructure/vela-promote/base/
├── kustomization.yaml           # 共通ユーティリティイメージ (ruby / alpine/kubectl) の digest pin
├── cronjob.yaml                 # Namespace infra で毎時 15 分に実行される昇格 CronJob
├── promote.rb                   # Application CR 整形・機密スキャン・velaux-sync.yaml 生成
├── rbac.yaml                    # Secret 読取ゼロの最小権限 RBAC
├── external-secret.yaml         # Secret Manager (vela-promote-github-token) からの同期
└── networkpolicy.yaml           # vela-promote-egress-restrict (API・GitHub HTTPS・DNS のみ)
```

これらはすべて `clusters/platform/kustomization.yaml` に登録され、Config Sync が一括同期します。

### 上流チャート・マニフェストへの主な適用パッチ

| 上流の挙動                                                                                       | 問題                                                                                                 | 本リポジトリでの対処                                                                                                                                                                          |
| :----------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ClusterRoleBinding/kubevela-vela-core:manager-rolebinding` が `cluster-admin` を付与            | コントローラ侵害時に全 Secret・RBAC・VAP を書き換え可能                                              | `op: test` ガード付き JSON パッチで最小権限 `kubevela-vela-core:manager` へ置換                                                                                                               |
| `builtin-definitions` の Helm フック Job 3 本 + ステージング ConfigMap 5 個                      | Config Sync がフックを管理できず、`k8s-objects` / `raw` / `http-get` / `git-file` 等の危険定義が入る | `$patch: delete` で除去し、厳選 48 定義（安全な 5 `SourceDefinition` 含む）を `addons/kubevela/base/definitions/` から宣言的に適用                                                            |
| クラスタスコープの WebhookConfiguration に `metadata.namespace` が付く / `failurePolicy: Ignore` | Config Sync が `KNV1052` で停止し、Webhook 障害時に検証が素通しになる                                | `op: test` パッチで `metadata.namespace` を除去し、全 11 Validating + 2 Mutating Webhook を `failurePolicy: Fail` へ引き上げ（証明書は内蔵生成）                                              |
| `multicluster`（`cluster-gateway`）・無制限 Helm キャッシュ・HTTP ワークフロー                   | シングルクラスタで不要な攻撃面・SSRF 経路・メモリ膨張を生む                                          | `multicluster.enabled: false`、`helmCache.maxBytes: 67108864`、`blockPrivateHTTPAddresses: true`・`disableWorkflowHTTP: true` を維持しつつ 1.12 の CEL 式（opt-in）と Definition 継承を有効化 |
| VelaUX の `/api/v1/system_info` が未認証で HTTP 401 を返す                                       | Kubernetes の `readinessProbe` が失敗し続ける                                                        | `readinessProbe` に `/api/v1/auth/login_type`、`livenessProbe` に `/` を設定。`vela-core`・`velaux-server` とも非 root（UID/GID `65532`）・RO rootfs・`/tmp` emptyDir                         |
| VelaUX が `kubevela:writer*` 権限を自己管理しようとすると高権限が必要                            | `ClusterRoleBinding` 書き込み権限を与えると権限昇格の経路になる                                      | `kubevela:writer` / `kubevela:writer:application` / `kubevela:writer:binding` を宣言的に事前作成し、`velaux-cluster-boundary` VAP で `RoleBinding` 4 不変条件を強制                           |

## 2. 導入手順（新規構築）

### 2.1 Terraform apply と Cloudflare Tunnel / Access

[GKE_SETUP_GUIDE.md](GKE_SETUP_GUIDE.md) の §2.1・§3 に従い、Terraform を 2 段階で apply します。

- `terraform/terraform.tfvars` に `cloudflare_account_id`・`cloudflare_zone_id`・`cloudflare_access_team_name`・`platform_admin_emails` を設定します。
- Secret Manager に `cloudflare-api-token` と `vela-promote-github-token` を登録してから 2 回目の `terraform apply` を実行します。

Terraform（`terraform/cloudflare-tunnel.tf`・`terraform/cloudflare-access.tf`）が作成するルーティングは次のとおりです。

| hostname              | 転送先                                                       | アクセス制御                                         |
| :-------------------- | :----------------------------------------------------------- | :--------------------------------------------------- |
| `vela.wax100.io`      | `http://velaux-server.vela-system.svc.cluster.local:8000`    | Cloudflare Access + `origin_request.access` JWT 検証 |
| `dashboard.wax100.io` | `http://headlamp.headlamp.svc.cluster.local:80`              | 同上                                                 |
| `backup.wax100.io`    | `http://backrest.infra.svc.cluster.local:9898`               | 同上                                                 |
| `*.wax100.io`         | `http://ingress-nginx-controller.infra.svc.cluster.local:80` | アプリ次第                                           |
| （その他）            | `http_status:404`                                            | なし                                                 |

公開 URL は `terraform output velaux_url` で確認できます。ホスト名を変更する場合は `terraform/variables.tf` の `velaux_hostname`（既定 `vela.wax100.io`）を変更します。

### 2.2 マニフェスト同期と起動確認

変更を加えた場合はローカル（bash / WSL / Cloud Shell）で事前検証し、Cloud Build → Config Sync 経由で同期します。

```bash
cargo make pre-commit
```

同期完了後、コントロールプレーン・データストア・定義が揃っていることを確認します。

```powershell
kubectl get pods -n vela-system
kubectl get cm -n velaux-store pj-production
kubectl get componentdefinitions -n vela-system
```

### 2.3 初回 VelaUX 管理者セットアップ（重要）

1. ブラウザで `https://vela.wax100.io` を開き、Cloudflare Access の認証を通過します。
2. 初回初期化画面（`InitAdmin`）で、**推測されにくい任意の管理者ユーザー名**と強力なパスワード・メールアドレスを登録して初期化します。

   > **補足**: `components/infrastructure/velaux/base/production-project.yaml` の `ConfigMap/pj-production` には `client.lifecycle.config.k8s.io/mutation: ignore` を付与しています。初回作成は Config Sync が行い、その後 `InitAdmin` が `owner` を任意の管理者名で上書きしても Config Sync が差し戻さないため、`admin` 以外のユーザー名で安全に初期化できます（公開リポジトリに実ユーザー名を記載する必要もありません）。

3. プロジェクト一覧に **Production (GitOps Read-Only)**（内部名 `production`）が表示されていることを確認します。
4. **Production プロジェクトの RBAC 設定**: 運用用アカウントや追加ユーザーを作成する場合、`production` プロジェクトへ割り当てるロールは必ず読取専用の **`project-view`** に限定してください。UI 層での誤操作を防ぐことに加え、仮に管理者が UI から本番へ変更を試みても、K8s RBAC（`velaux-minimal`）・API サーバー組み込み VAP（`velaux-cluster-boundary`）・Kyverno（`velaux-namespace-boundary`）の 3 層防御が本番（`prod-*`）への書き込みを確実に拒否します。

## 3. Dev アプリの作成・編集（VelaUX GUI）

1. VelaUX で開発用プロジェクト（例: `dev`）を作成し、Delivery Target（Cluster: `local`、Namespace: `dev-<app>` を推奨）および Environment を作成します。
   - VelaUX が Target を作成すると、対象 Namespace に自動で `usage.oam.dev/runtime=target` ラベルが付与されます。
   - このラベルにより、Kyverno が以下を自動適用します。
     - `pin-apps-to-apps-pool`: `apps-pool`（Spot）へ配置固定 + 既定 requests（`100m` / `128Mi`）+ `RuntimeDefault` seccomp 注入
     - `run-dev-in-gvisor`: Dev の全 Pod を gVisor（GKE Sandbox）で隔離実行
     - `environment-isolation`: `environment-isolation` / `dev-access-relay` / `dev-to-dev` NetworkPolicy を自動生成
     - `environment-access` / `headlamp-edit-app-namespaces`: `wax100-dev`・`headlamp-user` へ Dev Namespace の編集権限を付与
2. Application を作成し、厳選された定義から組み合わせてデプロイします。
   - **ComponentDefinition（5 種）**: `webservice`, `worker`, `task`, `cron-task`, `statefulset`
   - **TraitDefinition（25 種）**: `env`, `scaler`, `storage`, `volumes`, `pvc`, `resource`, `expose`, `gateway`, `ingress-1-20`, `annotations`, `labels`, `command`, `init-container`, `sidecar`, `k8s-update-strategy` 等
   - **SourceDefinition（5 種、1.12+）**: `configmap-local`, `vela-config`, `vela-env`, `vela-app`, `vela-component`（SSRF 経路となる `http-get` / `git-file` / `vela-addon` は除外）
   - コンテナイメージはあらかじめ Docker Hub / GHCR / Artifact Registry 等へ push 済みのイメージを指定します（クラスタ内に privileged ビルダーは置きません）。
   - アプリ用 DB（PostgreSQL 18 / MySQL 8.0 / MariaDB 等）も同じ Application 内の `statefulset` コンポーネント + `storage`（PVC）トレイトで同居させられます。PostgreSQL 拡張（`vector` 等）が必要な場合は `annotations` トレイトで `wax100.io/postgres-extensions: "vector"` を付与してください（詳細は [GKE_SETUP_GUIDE.md](GKE_SETUP_GUIDE.md) の §8.8）。
3. **Dev の外部公開**: 外からアクセスしたい場合のみ、`gateway`（または `ingress-1-20`）トレイトで **`dev-<app>.wax100.io`** を指定します。`wax100.io` の 1 階層下かつ `dev-` 接頭辞が必須で、本番ホスト名や多段サブドメインは `ingress-hosts-by-environment` が拒否します。
4. **機密情報の扱い**: パスワードや API キーは Dev Namespace 内に手動で Kubernetes Secret を作成し、Component の `env`（`valueFrom.secretKeyRef`）や `storage.secret` から参照してください。環境変数や ConfigMap に平文の機密を書くと、本番昇格時に `vela-promote` の機密スキャナが検知して昇格を停止します。

## 4. 本番への昇格と VelaUX での本番可視化（GitOps Read-Only）

1. 初回のみ、昇格したい Dev Namespace にラベルを付与します。

   ```powershell
   kubectl label ns <dev の Namespace> wax100.io/promote=true

   # Dev に Ingress / gateway が無く、本番だけ外部公開（https://<app>.wax100.io）したい場合
   kubectl label ns <dev の Namespace> wax100.io/public=true

   # 2 台同時稼働で壊れるアプリ（Discord BOT 等）を 1 台・Recreate で昇格したい場合
   kubectl label ns <dev の Namespace> wax100.io/single-replica=true
   ```

   毎時 15 分を待たずに即時実行する場合は手動 Job を起動します。

   ```powershell
   kubectl create job --from=cronjob/vela-promote vela-promote-manual -n infra
   kubectl logs -n infra job/vela-promote-manual -f
   ```

2. `infra` Namespace の `vela-promote` が `components/apps/<app>/{base,overlays/production}` を生成し、GitHub へ Pull Request を作成します（`base/application.yaml`、非所有補助リソースがある場合の `base/resources.yaml`、`overlays/production/{namespace,velaux-sync,ingress,hpa,pdb,external-secret,kustomization}.yaml`）。
3. PR 本文の指示に従って Secret Manager へ `prod-<app>_<secret>-<key>` を登録し、差分をレビューして `main` へマージします。
4. マージ後、Cloud Build → Artifact Registry (OCI) → Config Sync が `prod-<app>` と、`velaux-store` 内の `ConfigMap/tg-local-prod-<app>`・`ConfigMap/ev-prod-<app>`（`velaux-sync.yaml`）を同期します。
5. **VelaUX 上での本番可視化（GitOps バイパスゼロ）**: VelaUX の `CR2UX` が `prod-<app>` の `Application` を自動検出し、**Production (GitOps Read-Only)** プロジェクト内で Status・Topology・Pod・Logs・Events を閲覧できます。VelaUX から `prod-*` への書き込みは一切発生せず、本番の変更はすべて Git の PR（または Dev 更新による自動追従 PR）経由で行います。

詳細な昇格仕様・除外項目・HPA / PVC の扱いは [DEPLOYMENT_FLOW.md](DEPLOYMENT_FLOW.md) を参照してください。

## 5. 不要になった Dev Namespace の削除

API サーバー組み込み VAP `velaux-cluster-boundary` は、gVisor（`run-dev-in-gvisor`）およびネットワーク隔離（`environment-isolation`）の回避を防ぐため、VelaUX SA（`kubevela-ux`）による Dev Namespace からの `usage.oam.dev/runtime=target` ラベル剥奪と Namespace 削除を意図的に禁止しています。

そのため、使わなくなった Dev 環境を片付けるときは次の手順で行います。

1. VelaUX UI で該当する Application・Environment・Target を削除します。
2. 管理者コンテキスト（`wax100-admin`）から Namespace を直接削除します。

```powershell
kubectl delete ns <dev の Namespace>
```

## 6. 運用上の注意・アップグレード

- **最小権限 RBAC と 3 層境界**: `velaux-server`（`kubevela-ux`）にはクラスタ全体の Secret 読取権限が無く、`velaux-store` の ConfigMap（JWT 署名鍵・bcrypt ハッシュ格納先）も `wax100-cluster-view` / `headlamp-user-view` から隔離しています。依然として Dev 環境の作成・操作とクラスタ状態閲覧が可能な管理画面であるため、Cloudflare Access（`platform_admin_emails`）と VelaUX 認証の二重保護を維持してください。
- **許可された Definition 以外が使えない理由**: `vela-application-guard` VAP が `addons/kubevela/base/definitions/` の 48 定義と 1:1 で照合し、`k8s-objects` / `raw` / `ref-objects` / `vela-cli` / `apply-terraform-*` や `app.oam.dev/service-account-name`・`service-account` の `privileges`・他 Namespace `topology` を拒否します。新しい Definition を追加したい場合は `addons/kubevela/base/definitions/` と `addons/kyverno/base/validatingadmissionpolicy-vela-core-boundary.yaml`（および必要なら `components/infrastructure/vela-promote/base/promote.rb`）をセットで PR レビューして追加してください。
- **イメージのダイジェスト固定**: `oamdev/vela-core:v1.12.0-alpha.3@sha256:...`（`addons/kubevela/base/kustomization.yaml`）および `ghcr.io/waxsd100/velaux:kubevela-1.12-ja@sha256:...`（`components/infrastructure/velaux/base/deployment.yaml`、`waxsd100/velaux` の `feat/kubevela-1.12` ブランチからビルド）は digest 固定です。アップグレード時はチャート版・イメージタグ・digest を同時に更新し、`cargo make pre-commit` で `op: test` パッチガード・`check-backup-consistency.sh`・`_result.json` 差分を確認してください。
- **Spot ノード回収時の挙動**: `vela-core` と `velaux-server` は RWO PVC を持たないステートレス Deployment（状態は Kubernetes API / `velaux-store` に保存）のため、Spot 退避時は数十秒で再起動・復旧します。稼働中のアプリ Pod には影響しません。
- **Kyverno のイメージ書き換え**: `oamdev/vela-core` は Docker Hub 由来のため `docker-hub-cache`、`ghcr.io/waxsd100/velaux` は GHCR 由来のため `ghcr-cache` 経由に書き換わります。

## 7. トラブルシューティング・デバッグ・バックアップ

- **gVisor 環境の Dev への port-forward**: gVisor の Pod には直接 `kubectl port-forward` できないため、`dev-access` の中継 Pod を使うスクリプトを利用します。

  ```bash
  bash hack/dev-port-forward.sh <dev の Namespace> <Service> <ポート> [ローカルポート]
  # 例: bash hack/dev-port-forward.sh dev-myapp postgres 5432
  ```

- **kubectl コンテキストの使い分け**: `bash hack/kubectl-contexts.sh` を実行すると `wax100-dev` / `wax100-prod` / `wax100-admin` の 3 コンテキストを作成できます。
- **Dev アプリ定義と `velaux-store` のバックアップ / リストア**: 毎日 JST 03:30 に `infra/manifest-backup` が Dev の `Application` + 補助リソース（タグ `manifests`）と `velaux-store` の ConfigMap 一式（タグ `velaux-store`、暗号化保管）を restic リポジトリ（`gs://wax100-platform`）へ送信します。リストア手順は [BACKUP.md](BACKUP.md) の §5.2 を参照してください。

### よくあるエラーと確認コマンド

| 症状                                        | 確認先・対処                                                                                                                                           |
| :------------------------------------------ | :----------------------------------------------------------------------------------------------------------------------------------------------------- |
| VelaUX にアクセスできない / 502             | `kubectl get pods -n vela-system`、`kubectl logs -n vela-system deploy/velaux-server`、`kubectl logs -n infra deploy/cloudflared` を確認               |
| Application 作成時に Admission 拒否         | `vela-application-guard` / `velaux-cluster-boundary` / `ingress-hosts-by-environment` のメッセージを確認（許可外 Definition・`dev-` 以外のホスト名等） |
| `pj-production` で Config Sync ドリフト     | `pj-production` に `client.lifecycle.config.k8s.io/mutation: ignore` アノテーションが付いているか確認（§2.3）                                          |
| Dev Namespace が消せない / ラベルを外せない | 仕様です。§5 のとおり VelaUX で Application / Environment / Target を削除したあと、`wax100-admin` から `kubectl delete ns <dev の Namespace>` を実行   |

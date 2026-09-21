# GitOps アーキテクチャ・ブループリント

## 1. システム概要

本リポジトリは、Google Kubernetes Engine (GKE) 環境に最適化された宣言的なGitOpsアーキテクチャを定義しています。
**本番は GitOps、開発は Canine** という分担です。プラットフォーム基盤と本番アプリを Git で宣言し、開発・プレビュー環境だけを **Canine**（Kubernetes 向けの PaaS コントロールプレーン）が受け持ちます。採用している技術スタックは以下の通りです：

- **GitOps コントローラー**: Google Cloud Config Sync (OCI アプローチ)
- **マニフェストレンダリングエンジン**: Kustomize (Base/Overlay パターン)
- **PaaS コントロールプレーン**: Canine (`components/infrastructure/canine`、公式 Helm チャート) — dev / プレビュー環境を担当
- **ポリシーエンジン / Mutating Webhook**: Kyverno
- **シークレット同期**: External Secrets Operator + Google Secret Manager
- **外部公開**: Cloudflare Tunnel (`cloudflared`) + ingress-nginx (ClusterIP) — 外部ロードバランサを持たない。`*.apps.<domain>` をまとめて受ける
- **管理者のアクセス**: GKE の DNS ベースエンドポイント + IAM — 踏み台・VPN なし
- **コンテナレジストリプロキシ**: Google Artifact Registry (GAR) リモートリポジトリ・キャッシュ
- **監視**: GKE 標準のシステムメトリクス / ログ (`monitoring_config` / `logging_config`)

## 2. ディレクトリ構造と関心の分離

本リポジトリのアーキテクチャは、影響範囲（ブラスト・ラジアス）を最小化し、RBAC（CodeOWNERSなど）の境界を明確にするため、クラスタ全体のアドオンとプラットフォーム・ミドルウェアの間に厳密なトポロジー的分離を強制しています。

- `addons/`: クラスタ全体やシステムレベルの機能を提供するKubernetesネイティブコンポーネント（Kyverno, External Secrets Operator, Reloader）
- `components/infrastructure/`: 基本的なアドオンより上位に位置するプラットフォーム・ミドルウェア（Canine, cloudflared, ingress-nginx）
- `clusters/platform/`: Kustomization トラッキング用ディレクトリ。Cloud Build で OCI イメージへと Hydrate されます。
- `bootstrap/`: Config Sync の起点 (RootSync)。同期対象ではなく、構築時に人が 1 回だけ `kubectl apply` します。

- `components/apps/`: **本番で稼働するアプリケーション**。Canine の dev 環境から昇格された Pull Request が追記します

### 昇格 (dev → 本番)

開発は Canine の UI で行い、本番に出すときは Namespace にラベルを付けます（**初回だけ**）。

```bash
kubectl label ns <app> wax100.io/promote=true
```

`canine-promote` の CronJob が実体を `components/apps/<app>/{base,overlays/production}` に整形して Pull Request を立てます。生成されるのはマニフェストだけではありません。

- **公開用の `Ingress`** — `*.apps.wax100.io` は Cloudflare Tunnel が ingress-nginx にまとめて流しているため、これだけで `https://<app>.apps.wax100.io` が生えます。Cloudflare 側の作業も DNS 追加も不要です
- **`ExternalSecret` の雛形** — 参照している Secret 名とキーから組み立てます（値は読みません）。値は Secret Manager に登録してください。必要な ID は PR 本文に出ます

マージすると Config Sync が `prod-<app>` へ同期します。以降その Namespace は **Kyverno の Admission により Canine からは変更できません**（Config Sync と Canine が同じリソースを奪い合うのを構造的に防ぐため）。

**2 回目以降はラベルが要りません。** 一度昇格したアプリは dev の変更に自動で追従し、差分があれば PR が立ちます。マージは常に手動です。

dev 環境の定義は Canine のデータベースにしかないため、`canine-db` のバックアップと日次スナップショット（`components/infrastructure/canine-snapshot`）で補っています。

### Kustomization 戦略

各コンポーネントは以下の標準的なKustomizeレイアウトに準拠しています：

- `base/`: 環境に依存しない普遍的なKubernetesリソース（Deployment, Service, RBAC等）。上流の Helm チャートは `helmCharts:` で取り込み、足りない部分だけをパッチで補う。チャートのバージョンは固定する（一覧は `docs/ARCHITECTURE.md` の「2.1 固定しているバージョン」）。
- `overlays/<environment>/`: 環境固有の差分。単一クラスタ構成のため、現在は `production` のみ（Canine 本体と、昇格した本番アプリ）。

## 3. Config Sync と同期ロジック

クラスタの継続的な同期ロジックは、Cloud Build によって GKE Config Sync へ向けた OCI イメージの書き出しを介して駆動されます。
複雑なコンポーネント間のデプロイメント依存関係を安全に解決するため、必要に応じて Config Sync のアノテーション(`config.kubernetes.io/depends-on`)を用いた順序制御を検討します。

### 決定論的デプロイメント構想

1. **Phase 1:** 基盤アドオン (`addons/kyverno`等)
   - _Rationale (根拠):_ 後続のすべてのPodのAdmission Requestをインターセプトし、Mutating Webhookによるコンテナイメージの書き換えを確実に行うため、極限まで早期に（最優先で）デプロイされるべきです。
2. **Phase 2:** ミドルウェア群 (`components/infrastructure/cloudflared`, `nginx-ingress`)
   - _Rationale:_ アプリケーションが動作する上で必須の Ingress 等の層を用意する。cloudflared → ingress-nginx → 各アプリの Ingress、という公開経路がここで成立する。
3. **Phase 3:** PaaS コントロールプレーンと本番アプリ (`components/infrastructure/canine`, `components/apps/`)
   - _Rationale:_ Canine は起動時に Secret（ESO 経由）と Cloud SQL 接続を必要とするため、アドオンとミドルウェアが健全に稼働した後にデプロイする。`config.kubernetes.io/depends-on` で External Secrets への依存を明示している。
   - dev 環境のアプリは Canine が直接デプロイし、Config Sync は関与しない。**昇格した本番アプリ（`components/apps/`）は Config Sync が管理**し、Canine からの変更は Kyverno が拒否する。

## 4. コンテナレジストリ・キャッシュ戦略 (Kyverno Webhook)

パブリックインターネットにおけるレート制限（Docker Hub等）を回避し、GKEノードでのイメージ取得を高速かつ決定論的にするため、本アーキテクチャではコンテナイメージの取得をGoogle Artifact Registry (GAR) のリモートリポジトリ・キャッシュ (`asia-northeast1`) へ向けます（ベストエフォート。後述）。

**MutatingAdmissionWebhook の実装詳細:**
（複雑なHelm/Kustomize構成を含む `kube-prometheus` などで運用が破綻する）手動の `images` トランスフォーマーの定義をすべての `kustomization.yaml` に対して個別に行うのではなく、本構成では **KyvernoのClusterPolicy** (`clusterpolicy-registry-mirror.yaml`) をデプロイするアプローチを取ります。

- **Trigger (発火条件)**: Kubernetes APIのAdmissionフェーズ中に発行される `Pod` 作成のメタデータをインターセプト。
- **Mutation (ミューテーション)**: コンテナの `image` 文字列を条件評価し、JMESPath関数（`replace_all`）を利用してレジストリドメインを動的に書き換え（Rewrite）ます：
  - `docker.io/` -> `asia-northeast1-docker.pkg.dev/<PROJECT_ID>/docker-hub-cache/`
  - `ghcr.io/` -> `asia-northeast1-docker.pkg.dev/<PROJECT_ID>/ghcr-cache/`
  - `quay.io/` -> `asia-northeast1-docker.pkg.dev/<PROJECT_ID>/quay-cache/`
  - `registry.k8s.io/` -> `asia-northeast1-docker.pkg.dev/<PROJECT_ID>/k8s-cache/`
  - レジストリを省略した参照（`nginx:1.27`, `bitnami/redis:7`）も Docker Hub のキャッシュへ
- **ベストエフォート**: このポリシーは `failurePolicy: Ignore` です。書き換えはレート制限回避の最適化でセキュリティ統制ではないため、Kyverno が止まっている間は上流から直接取得させ、Pod の作成を止めません。
- **Kyverno 自身は対象外**: Kyverno は既定の `resourceFilters` で自分の Namespace を除外しているため、Kyverno 自身の Pod は書き換えられず、上流から直接取得されます。

## 5. マニフェストハイドレーションと CI 検証

本リポジトリは、堅牢なCI/CDパイプラインプロセス（`.github/workflows/hydrate.yml` および `format-and-lint.yml` に定義）の存在を前提としています。

- **コード品質統制 (Format & Lint)**: `format-and-lint.yml` により、コミットされたすべてのYAMLやMarkdownに対してPrettierによる自動フォーマットとSuper-Linter（各種構文チェック）が実行され、コードの均一性を強制します（設定ファイルは `.github/linters/` ディレクトリに集約）。

- **Hydration Output (ハイドレーション出力)**: CIで `kustomize build components/infrastructure/canine/overlays/production` などを実行し、複数のオーバーレイを含む構成を明示的かつ生（Raw）のKubernetes YAMLオブジェクトへとコンパイルします。
- **Data Transformation (データ変換)**: `yq '[.]' -o=json` を利用して、マルチドキュメントYAMLを構造化されたJSON配列（`_result.json`）へとシリアライズします。
- この生成されたArtifactは、ConftestやOPA等のポリシー評価エンジンによる統合的なCIバリデーションを可能にし、人間や外部AIエージェントのレビュアーに対し、Config SyncがGKEに対して同期しようとする最終的なAPIオブジェクトの明確なスナップショットを提供します。

## 6. クラスタのブートストラップ・シーケンス (Day 0)

1. `terraform/` にて、対象のGKEクラスタとConfig Syncの初期設定(`google_gke_hub_feature.configmanagement`)のapplyを実行します。**Cloudflare 関連は API トークン登録後の 2 回目の apply で作られます**（手順は `docs/GKE_SETUP_GUIDE.md`）。
2. Config Sync がアクセスするための ServiceAccount と Workload Identity のバインディングがTerraformにより構成され、GCP側のリソースとGKEクラスタの権限が安全に連携します。
3. マニフェスト変更がメインブランチにマージされると、Cloud Build によって自動的に Kustomize ビルド結果が Tar 化され、Artifact Registry に OCI イメージとしてプッシュされます。
4. **`kubectl apply -f bootstrap/root-sync.yaml` を 1 回だけ実行**して Config Sync を起動します（同期対象の中に自分自身の起点は入れないため、ここだけ手動です）。
5. 以降、Config Sync が継続的なクラスタ管理を引き継ぎます。クラスタのステートは OCI イメージから引っ張られ、Gitの `HEAD` コンテキストが常にクラスタと同期されるようになります。
6. Canine の初期セットアップ（クラスタ接続、アプリ登録）は `docs/CANINE_SETUP.md` を参照してください。

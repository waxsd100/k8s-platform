# GitOps アーキテクチャ・ブループリント

## 1. システム概要

本リポジトリは、Google Kubernetes Engine (GKE) 環境に最適化された宣言的なGitOpsアーキテクチャを定義しています。
プラットフォーム基盤（アドオン・ミドルウェア）を Git で宣言し、その上で動くアプリケーションは **Canine**（Kubernetes 向けの PaaS コントロールプレーン）が管理します。採用している技術スタックは以下の通りです：

- **GitOps コントローラー**: Google Cloud Config Sync (OCI アプローチ)
- **マニフェストレンダリングエンジン**: Kustomize (Base/Overlay パターン)
- **PaaS コントロールプレーン**: Canine (`components/infrastructure/canine`、公式 Helm チャート)
- **ポリシーエンジン / Mutating Webhook**: Kyverno
- **シークレット同期**: External Secrets Operator + Google Secret Manager
- **外部公開**: Cloudflare Tunnel (`cloudflared`) — 外部ロードバランサを持たない
- **コンテナレジストリプロキシ**: Google Artifact Registry (GAR) リモートリポジトリ・キャッシュ
- **監視**: GKE 標準のシステムメトリクス / ログ (`monitoring_config` / `logging_config`)

## 2. ディレクトリ構造と関心の分離

本リポジトリのアーキテクチャは、影響範囲（ブラスト・ラジアス）を最小化し、RBAC（CodeOWNERSなど）の境界を明確にするため、クラスタ全体のアドオンとプラットフォーム・ミドルウェアの間に厳密なトポロジー的分離を強制しています。

- `addons/`: クラスタ全体やシステムレベルの機能を提供するKubernetesネイティブコンポーネント（Kyverno, External Secrets Operator）
- `components/infrastructure/`: 基本的なアドオンより上位に位置するプラットフォーム・ミドルウェア（Canine, cloudflared）
- `clusters/platform/`: Kustomization トラッキング用ディレクトリ。Cloud Build で OCI イメージへと Hydrate されます。

**ビジネスアプリケーションはこのリポジトリでは管理しません。** アプリのデプロイは Canine が担当し、その定義は Canine 自身のデータベース（Cloud SQL）に保持されます。したがってアプリ層の復旧は Git ではなく Cloud SQL のバックアップに依存します。

### Kustomization 戦略

各コンポーネントは以下の標準的なKustomizeレイアウトに準拠しています：

- `base/`: 環境に依存しない普遍的なKubernetesリソース（Deployment, Service, RBAC等）。アップストリームとの同期を容易にするため、可能な限りGitHubの直接参照（例: `github.com/argoproj/argo-cd//manifests/ha/cluster-install?ref=v2.10.1`）を利用。
- `overlays/<environment>/`: 環境固有のミューテーション（dev, stg, prod等）。レプリカ数、ConfigMap、特定のリソース割り当てなどの環境差分パッチ（Patch）を適用。

## 3. Config Sync と同期ロジック

クラスタの継続的な同期ロジックは、Cloud Build によって GKE Config Sync へ向けた OCI イメージの書き出しを介して駆動されます。
複雑なコンポーネント間のデプロイメント依存関係を安全に解決するため、必要に応じて Config Sync のアノテーション(`config.kubernetes.io/depends-on`)を用いた順序制御を検討します。

### 決定論的デプロイメント構想

1. **Phase 1:** 基盤アドオン (`addons/kyverno`等)
   - _Rationale (根拠):_ 後続のすべてのPodのAdmission Requestをインターセプトし、Mutating Webhookによるコンテナイメージの書き換えを確実に行うため、極限まで早期に（最優先で）デプロイされるべきです。
2. **Phase 2:** ミドルウェア群
   - _Rationale:_ アプリケーションが動作する上で必須のIngress等の層を用意する。
3. **Phase 3:** PaaS コントロールプレーン (`components/infrastructure/canine`)
   - _Rationale:_ Canine は起動時に Secret（ESO 経由）と Cloud SQL 接続を必要とするため、アドオンとミドルウェアが健全に稼働した後にデプロイする。`config.kubernetes.io/depends-on` で External Secrets への依存を明示している。
   - 以降のアプリケーションのデプロイは Canine の管理下で行われ、Config Sync は関与しない。

## 4. コンテナレジストリ・キャッシュ戦略 (Kyverno Webhook)

パブリックインターネットにおけるレート制限（Docker Hub等）を回避し、GKEノードでのイメージ取得を高速かつ決定論的にするため、本アーキテクチャではすべてのコンテナイメージトラフィックをGoogle Artifact Registry (GAR) のリモートリポジトリ・キャッシュ (`asia-northeast1`) へと強制ルーティングします。

**MutatingAdmissionWebhook の実装詳細:**
（複雑なHelm/Kustomize構成を含む `kube-prometheus` などで運用が破綻する）手動の `images` トランスフォーマーの定義をすべての `kustomization.yaml` に対して個別に行うのではなく、本構成では **KyvernoのClusterPolicy** (`clusterpolicy-registry-mirror.yaml`) をデプロイするアプローチを取ります。

- **Trigger (発火条件)**: Kubernetes APIのAdmissionフェーズ中に発行される `Pod` 作成のメタデータをインターセプト。
- **Mutation (ミューテーション)**: コンテナの `image` 文字列を条件評価し、JMESPath関数（`replace_all`）を利用してレジストリドメインを動的に書き換え（Rewrite）ます：
  - `docker.io/` -> `asia-northeast1-docker.pkg.dev/<PROJECT_ID>/docker-hub-cache/`
  - `ghcr.io/` -> `asia-northeast1-docker.pkg.dev/<PROJECT_ID>/ghcr-cache/`
  - `quay.io/` -> `asia-northeast1-docker.pkg.dev/<PROJECT_ID>/quay-cache/`
  - `registry.k8s.io/` -> `asia-northeast1-docker.pkg.dev/<PROJECT_ID>/k8s-cache/`
- **Bootstrapping Exception (ブートストラップの例外処理)**: Kyvernoを動かすためのPod自体は、稼働前である彼ら自身のWebhookでインターセプトすることができません。そのため、例外的な処理として、Kyvernoのシステムイメージのみは `addons/kyverno/overlays/development/kustomization.yaml` にてKustomizeの `images` 機能を用いて明示的かつ静的に書き換えています。

## 5. マニフェストハイドレーションと CI 検証

本リポジトリは、堅牢なCI/CDパイプラインプロセス（`.github/workflows/hydrate.yml` および `format-and-lint.yml` に定義）の存在を前提としています。

- **コード品質統制 (Format & Lint)**: `format-and-lint.yml` により、コミットされたすべてのYAMLやMarkdownに対してPrettierによる自動フォーマットとSuper-Linter（各種構文チェック）が実行され、コードの均一性を強制します（設定ファイルは `.github/linters/` ディレクトリに集約）。

- **Hydration Output (ハイドレーション出力)**: CIで `kustomize build components/infrastructure/canine/overlays/production` などを実行し、複数のオーバーレイを含む構成を明示的かつ生（Raw）のKubernetes YAMLオブジェクトへとコンパイルします。
- **Data Transformation (データ変換)**: `yq '[.]' -o=json` を利用して、マルチドキュメントYAMLを構造化されたJSON配列（`_result.json`）へとシリアライズします。
- この生成されたArtifactは、ConftestやOPA等のポリシー評価エンジンによる統合的なCIバリデーションを可能にし、人間や外部AIエージェントのレビュアーに対し、Config SyncがGKEに対して同期しようとする最終的なAPIオブジェクトの明確なスナップショットを提供します。

## 6. クラスタのブートストラップ・シーケンス (Day 0)

1. `terraform/` にて、対象のGKEクラスタとConfig Syncの初期設定(`google_gke_hub_feature.configmanagement`)のapplyを実行します（例: `terraform apply`）。
2. Config Sync がアクセスするための ServiceAccount と Workload Identity のバインディングがTerraformにより構成され、GCP側のリソースとGKEクラスタの権限が安全に連携します。
3. マニフェスト変更がメインブランチにマージされると、Cloud Build によって自動的に Kustomize ビルド結果が Tar 化され、Artifact Registry に OCI イメージとしてプッシュされます。
4. 以降、Config Sync が継続的なクラスタ管理を引き継ぎます。クラスタのステートは OCI イメージから引っ張られ、Gitの `HEAD` コンテキストが常にクラスタと同期されるようになります。
5. Canine の初期セットアップ（クラスタ接続、アプリ登録）は `docs/CANINE_SETUP.md` を参照してください。

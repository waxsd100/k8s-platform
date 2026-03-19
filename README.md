# GitOps アーキテクチャ・ブループリント

## 1. システム概要
本リポジトリは、Google Kubernetes Engine (GKE) 環境に最適化された宣言的なGitOpsアーキテクチャを定義しています。採用している技術スタックは以下の通りです：
- **GitOps コントローラー**: ArgoCD (再帰的な App of Apps パターンを採用)
- **マニフェストレンダリングエンジン**: Kustomize (Base/Overlay パターン)
- **ポリシーエンジン / Mutating Webhook**: Kyverno
- **コンテナレジストリプロキシ**: Google Artifact Registry (GAR) リモートリポジトリ・キャッシュ

## 2. ディレクトリ構造と関心の分離
本リポジトリのアーキテクチャは、影響範囲（ブラスト・ラジアス）を最小化し、RBAC（CodeOWNERSなど）の境界を明確にするため、クラスタ全体のアドオン、インフラストラクチャ・ミドルウェア、およびビジネスアプリケーションの間に厳密なトポロジー的分離を強制しています。

- `addons/`: クラスタ全体やシステムレベルの機能を提供するKubernetesネイティブコンポーネント（例: Prometheus, Kyverno）
- `components/infrastructure/`: 基本的なアドオンより上位で、ビジネスロジックより下位に位置するプラットフォーム・ミドルウェア（例: ArgoCD自身の管理状態、Ingressコントローラー）
- `components/apps/`: エンドユーザー向けビジネスアプリケーション（例: frontend-web, backend-api）
- `clusters/`: 「App of Apps」の依存関係ツリーを定義・確立するための環境固有のArgoCDマニフェストのバインディング

### Kustomization 戦略
各コンポーネントは以下の標準的なKustomizeレイアウトに準拠しています：
- `base/`: 環境に依存しない普遍的なKubernetesリソース（Deployment, Service, RBAC等）。アップストリームとの同期を容易にするため、可能な限りGitHubの直接参照（例: `github.com/argoproj/argo-cd//manifests/ha/cluster-install?ref=v2.10.1`）を利用。
- `overlays/<environment>/`: 環境固有のミューテーション（dev, stg, prod等）。レプリカ数、ConfigMap、特定のリソース割り当てなどの環境差分パッチ（Patch）を適用。

## 3. ArgoCD App of Apps と Sync Waves
クラスタのブートストラップと継続的な同期ロジックは、`clusters/<env-cluster>/` にマウントされたArgoCDのApplicationマニフェストによって駆動されます。
複雑なコンポーネント間のデプロイメント依存関係を安全に解決するため、ArgoCDの Sync Waves (`argocd.argoproj.io/sync-wave`) を積極的に活用しています。

### 決定論的デプロイメントシーケンス (Deterministic Deployment Sequence):
1. **Wave -1:** `addons/kyverno`
   - *Rationale (根拠):* 後続のすべてのPodのAdmission Requestをインターセプトし、Mutating Webhookによるコンテナイメージの書き換えを確実に行うため、極限まで早期に（最優先で）デプロイする。
2. **Wave 0:** `addons/prometheus`
   - *Rationale:* 以降にデプロイされるすべてのリソースからメトリクスを収集できるよう、オブザーバビリティ群を立ち上げる。
3. **Wave 1:** `components/infrastructure/argocd`
   - *Rationale:* ArgoCD自身をArgoCDで管理する設定（自己状態指定）やミドルウェアを含むため、このタイミングでデプロイ。
4. **Wave 2:** `components/apps/`
   - *Rationale:* すべてのインフラストラクチャおよびアドオンの依存関係が健全（Healthy）に稼働していることを前提として、ビジネスロジックであるアプリ本体のデプロイを最後に実行する。

*Technical Note: ルートのマニフェスト定義（例: `clusters/dev-cluster/apps-root.yaml`）は特定のファイルではなく、トラッキング用ディレクトリ全体（`path: clusters/dev-cluster/apps/`）をターゲットとしています。このディレクトリに新しいApplicationマニフェストを追加するだけで、自動的にArgoCDの同期ループに組み込まれます（Recursive App of Apps）。*

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
- **Bootstrapping Exception (ブートストラップの例外処理)**: Kyvernoを動かすためのPod自体は、稼働前である彼ら自身のWebhookでインターセプトすることができません。そのため、例外的な処理として、Kyvernoのシステムイメージのみは `addons/kyverno/overlays/dev/kustomization.yaml` にてKustomizeの `images` 機能を用いて明示的かつ静的に書き換えています。

## 5. マニフェストハイドレーションと CI 検証
本リポジトリは、堅牢なCI/CDパイプラインプロセス（`.github/workflows/hydrate.yml` に定義）の存在を前提としています。
- **Hydration Output (ハイドレーション出力)**: CIで `kustomize build components/apps/frontend-web/overlays/dev` などを実行し、複数のオーバーレイを含む構成を明示的かつ生（Raw）のKubernetes YAMLオブジェクトへとコンパイルします。
- **Data Transformation (データ変換)**: `yq '[.]' -o=json` を利用して、マルチドキュメントYAMLを構造化されたJSON配列（`_result.json`）へとシリアライズします。
- この生成されたArtifactは、ConftestやOPA等のポリシー評価エンジンによる統合的なCIバリデーションを可能にし、人間や外部AIエージェントのレビュアーに対し、ArgoCDがGKEに対して同期しようとする最終的なAPIオブジェクトの明確なスナップショットを提供します。

## 6. クラスタのブートストラップ・シーケンス (Day 0)
1. ターゲットとなるオーバーレイを指定し、対象のGKEクラスタに対して手動で初回のArgoCDを初期化・インストールします（例: `kubectl apply -k components/infrastructure/argocd/overlays/dev`）。
2. 本Gitリポジトリへのクレデンシャル（SSHキー または PAT）をArgoCDの内部Secretに永続化させます。
3. ルートとなるApp of Appsの同期マニフェスト群を適用します（`kubectl apply -f clusters/dev-cluster/*.yaml`）。
4. 以降、ArgoCDが継続的なクラスタ管理を引き継ぎます。クラスタのステートはGitの `HEAD` によって定義された宣言的な状態へと継続的に同期されます。

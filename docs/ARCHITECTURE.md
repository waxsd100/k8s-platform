# GitOps Architecture Blueprint

このドキュメントは、本リポジトリで定義されている、極限のコスト最適化とセキュアなGKE対応GitOpsアーキテクチャの全体構造と設計思想を定義します。

## 1. アプリケーションデプロイメント構成 (OCI-Based Config Sync)

本構成では、従来のPull型（ArgoCD等）特有のレポジトリ認証情報保持リスクを排除するため、**GCP Fleet (Anthos Config Management) + Config Sync (OCIモード)** を採用しています。
Cloud Build が GitHub と連携してマニフェストを OCI（Dockerイメージ形式）として Artifact Registry にプッシュし、各環境の `RootSync` が GCP ネイティブな権限でそれを同期展開します。

```mermaid
graph TD
    %% クラスタ（環境）の定義
    subgraph "GKE Cluster (Multi-Tenant)"
        direction TB

        RootDev[RootSync: development-cluster]
        RootStg[RootSync: staging-cluster]
        RootProd[RootSync: production-cluster]

        %% Component Apps (development-cluster)
        subgraph "development namespace"
            DevAddons["Addons (Kyverno, KEDA, ESO)"]
            DevInfra["Infra (Cloudflared, Nginx)"]
            DevApps["Apps (Frontend)"]
        end

        RootDev --> DevAddons
        RootDev --> DevInfra
        RootDev --> DevApps
    end

    %% Git Repo -> Registry
    subgraph "CI Pipeline"
        direction LR
        Git[GitHub Repository] -->|Cloud Build| AR[Artifact Registry (OCI)]
    end

    AR -.->|Sync| RootDev
    AR -.->|Sync| RootStg
    AR -.->|Sync| RootProd
```

## 2. 技術スタック・インフラ要件

| コンポーネント        | 採用技術                   | 機能要件・設計意図                                                                                                         |
| :-------------------- | :------------------------- | :------------------------------------------------------------------------------------------------------------------------- |
| **GitOps同期**        | **Config Sync (OCI)**      | クラスタ状態の宣言的管理および同期。パスワードレスでの Artifact Registry 経由の展開設計。                                  |
| **マニフェスト定義**  | **Kustomize**              | グローバルな状態定義を `base/` に集約し、環境ごとの差異を `overlays/` 経由で動的に注入するDRYアーキテクチャの提供。        |
| **機密情報管理**      | **External Secrets (ESO)** | GCP Secret Manager 上の機密データを安全に K8s Secret へ自動マウント。リポジトリのパスワードレス化。                        |
| **ミューテーション**  | **Kyverno**                | レジストリイメージの強制置換（API制限回避）や、システムPodの動的Toleration注入（全ノード水平分散）などのポリシーエンジン。 |
| **ゼロスケール化**    | **KEDA (+ HTTP Add-on)**   | Dev/Stag環境において、非アクティブ時にアプリのPodを**Replicas: 0**にスケールインする究極のコストオプティマイザ。           |
| **ネットワーク/認証** | **Cloudflare Zero Trust**  | Cloudflared（トンネル）を用いたPrivateクラスタ内部のダッシュボードやアプリへのセキュアかつIngressレスなアクセス基盤。      |

## 3. リポジトリ・ディレクトリ構造

Config Sync の連携と、構成ごとの責務分離を意図したディレクトリ構成です。

```text
📦 repository-root
 ┣ 📂 .github/         # Linter定義やフォーマッターの定義
 ┣ 📂 addons/          # クラスター横断基盤ツール (Kyverno, KEDA, ESO, Prometheus)
 ┣ 📂 components/
 ┃  ┣ 📂 apps/         # ビジネスアプリケーション (frontend-web等)
 ┃  ┗ 📂 infrastructure/ # 基盤インフラサービス (Ingress, Cloudflared等)
 ┣ 📂 clusters/
 ┃  ┣ 📂 development-cluster/ # 開発用構成 (RootSyncが参照する起点)
 ┃  ┣ 📂 staging-cluster/     # 検証用構成
 ┃  ┗ 📂 production-cluster/  # 本番用構成
 ┣ 📂 docs/            # セットアップガイドやアーキテクチャドキュメント
 ┗ 📜 cloudbuild.yaml  # OCIイメージ生成パイプライン定義
```

## 4. 環境 (Environment) 分離・ノードプール設計

提供される全ての環境モデル (development / staging / production) は、単一のGKEクラスタに対するNamespaceベースの論理分割として提供され、クラスタ自体のランニングコストを最小化するマルチテナント方式を標準とします。

### 4.1. ノードプールの役割と設計

1. **`system-pool`**: GKE管理コンポーネント専用（kube-system, Config Sync等）。非Spotの安定ノード（e2-medium, min=1, max=2）。プラットフォームやアプリワークロードは配置されません。
2. **`platform-pool` (4ティア, Spot)**: Nginx Ingress, Cloudflared, Kyverno, KEDA, External Secrets等のプラットフォームコンポーネント用。e2-small / e2-medium / e2-standard-2 / e2-standard-4 の4段階で、Cluster Autoscaler が負荷に応じて適切なティアをスケーリングします。`OPTIMIZE_UTILIZATION` プロファイルにより、アイドルノードは積極的にスケールダウンされます。
3. **`dev-pool` (Dev用)**: コスト削減のための **Spot Instance** ノード（e2-small, max=1）。KEDA により未使用時は **ノードごと 0台にスケールイン** します。
4. **`stag-pool` (Stag用)**: 検証用 **Spot Instance** ノード（e2-small, max=2）。KEDA により **ノードごと 0台にスケールイン** します。
5. **`prod-pool` (3ティア, Spot)**: 本番アプリケーション用。e2-medium / e2-standard-2 / e2-standard-4 の3段階で負荷に応じてスケーリング。`dedicated=prod-app` Taint により本番ワークロード専用に隔離されます。

### 4.2. 各環境の実装パラメータ差異（frontend-web の事例）

Kustomize の `overlays/` ディレクトリ内で定義されている環境ごとのパッチ仕様差異です。

| 環境     | DBエンジン | Replicas | Spotパッチ | KEDAゼロスケール | Ingress / LB モデル      |
| :------- | :--------- | :------- | :--------- | :--------------- | :----------------------- |
| **Dev**  | SQLite     | 0 〜 N   | `適用あり` | `有 (完全0台化)` | トンネル等・プライベート |
| **Stag** | SQLite     | 0 〜 N   | `適用あり` | `有 (完全0台化)` | トンネル等・プライベート |
| **Prod** | MySQL      | 4 〜 N   | `適用なし` | `無効`           | GKE標準LB等へ委譲        |

## 5. 高度なクラスタ機能設計

### 5.1. KEDA によるゼロスケール化 (Scale to Zero)

本構成では、開発および検証環境にかかる費用を削ぎ落とすため、**KEDA HTTP Add-on** を活用しています。
トラフィックが途絶えると、対象の Deployment (アプリケーション) は即座に **Replica=0** へスケールダウンします。その後、ブラウザからのHTTPアクセスが発生した瞬間にインターセプターがリクエストを数秒間保留し、Podを `1` にスケールアップさせてから転送します。

> [!NOTE]
> 初回アクセス時のみコンテナ起動までのアイドルレイテンシ（数秒）が発生します。
> 稼働維持が絶対必須となる `production` での適用は外枠（オーバーレイパッチ）で除外しています。

### 5.2. Config Sync の負荷分散アーキテクチャ (Kyverno Mutate)

Config Sync自体がデプロイするPod（`root-reconciler` 等）は、デフォルトでは各ノードプールのTaint（Spot, dedicated等）に対するTolerationを持ちません。そのため、Taintのない `system-pool` にのみスケジュールされます。
本アーキテクチャでは、**KyvernoのClusterPolicyによってConfig Syncのリソースに対しリソースリクエスト/リミットを動的に調整**し、`system-pool` (max=2) 内でのリソース枯渇を防止しています。

### 5.3. インバウンドトラフィックの Zero Trust 実装

外部からクラスター内部アプリケーションへの安全なアクセスのため、Cloudflare の `cloudflared` コンテナをクラスタ基盤にデプロイしています。これにより、ファイアウォール（Ingressノード等）への穴あけをゼロとし、セキュアなリバースプロキシを確立します。

# GitOps Architecture Blueprint

このドキュメントは、本リポジトリで定義されているGKE対応GitOpsアーキテクチャの全体構造と設計思想を定義します。

## 1. アプリケーションデプロイメント構成 (App of Apps)

本リポジトリはArgoCDの **App of Apps パターン** に従い、クラスタ・環境ごとのディレクトリ構成によりコンポーネント展開を宣言的に管理しています。

```mermaid
graph TD
    %% クラスタ（環境）の定義
    subgraph "GKE Cluster (Multi-Tenant)"
        direction TB
        
        RootDev[ArgoCD App: development-cluster-root]
        RootStg[ArgoCD App: staging-cluster-root]
        RootProd[ArgoCD App: production-cluster-root]
        
        %% Component Apps (development-cluster)
        subgraph "development namespace"
            DevAddons[Addons (Kyverno, External Secrets)]
            DevInfra[Infra (Nginx Ingress)]
            DevApps[Apps (Frontend)]
        end
        
        RootDev --> DevAddons
        RootDev --> DevInfra
        RootDev --> DevApps
    end
    
    %% Git Repo
    subgraph "Git Repository"
        direction LR
        Git[clusters/*/apps.yaml]
    end
    
    Git -.->|Sync| RootDev
    Git -.->|Sync| RootStg
    Git -.->|Sync| RootProd
```

## 2. 技術スタック・インフラ要件

| コンポーネント | 採用技術 | 機能要件・設計意図 |
| :--- | :--- | :--- |
| **CI/CD** | **ArgoCD** | クラスタ状態とGitリポジトリ間の状態同期および自動修復（Self-heal）の自動化。 |
| **マニフェスト定義** | **Kustomize** | グローバルな状態定義を `base/` に集約し、環境ごとの差異定数を `overlays/` 経由で動的に注入するDRYアーキテクチャの提供。 |
| **機密情報管理** | **External Secrets Operator** | クラウドプロバイダ（GCP Secret Manager等）上の機密データを安全にK8s Secretへ展開。Gitリポジトリ外への機密情報の完全隔離。 |
| **レジストリ最適化** | **Kyverno** | ダウンタイムおよびAPI Rate Limit回避のため、Mutating Webhookを用いて稼働イメージ参照先を全てGCP内Artifact Registryへと透過的に置換。 |
| **Ingress** | **Nginx Ingress (Helm)** | GCE Ingressの依存排除およびコスト最適化のため、`nginxinc/kubernetes-ingress` のHelm Chartを採用。 |
| **CIバリデーション** | **Kubeconform** + **yamllint** | Kustomize展開後の全結果オブジェクトに対し、Kubernetes OpenAPIの厳格なスキーマ検証をPR/Pushイベントごとに実行。 |

## 3. リポジトリ・ディレクトリ構造

Kustomizeにおける責務と、App of Appsにおけるデプロイ起点の分離を意図した構成です。

```text
📦 repository-root
 ┣ 📂 addons/          # クラスター全体で横断的に利用される基盤ツール群 (Kyverno, Prometheus等)
 ┣ 📂 components/
 ┃  ┣ 📂 apps/         # 個別ビジネス要件アプリケーション (frontend-web等)
 ┃  ┗ 📂 infra*/       # ビジネスインフラ連携層ミドルウェア (Ingress等)
 ┣ 📂 clusters/
 ┃  ┣ 📂 development-cluster/ # 開発環境向け展開定義 (App of Apps 起点)
 ┃  ┣ 📂 staging-cluster/     # 検証環境向け展開定義
 ┃  ┗ 📂 production-cluster/  # 本番環境向け展開定義
 ┗ 📂 docs/            # アーキテクチャおよび最適化設計ドキュメント
```

## 4. 環境（Environment）分離モデル

提供される全ての環境モデル (development / staging / production) は、単一のGKEクラスタに対するNamespaceベースの論理分割として提供され、クラスタ自体のランニングコストを最小化するマルチテナント方式を標準とします。

### Development / Staging 環境 (コスト過最適化構成)

インフラストラクチャーのランニングコスト適正化に向けた非定常要件パッチが適用されています。

* **環境別 taint/toleration による分離**: ノードプールに `environment=<env>:NoSchedule` を付与し、`toleration-patch.yaml` を通じて該当環境の Pod のみをそのノードにスケジュールできるようにしています。これにより単一クラスタ内で環境を論理分離できます。
* **Spot Instanceの許容**: `spot-patch.yaml`（terminationGracePeriodSeconds, topologySpreadConstraints, lifecycle 等）を併用し、Spot (preemptible) ノードでの稼働に耐えられるよう Pod 側の堅牢性を高めています。
* **LoadBalancer依存の排除**: IngressコントローラーのService展開を `NodePort` 定義とし、独自構成の外部LB・NATへトラフィックルーティングを移譲。

### Production 環境 (高可用・標準構成)

コスト最適化要件（NodePort化・Spot耐性パッチ等）への依存を排除し、マネージドサービス前提の高可用標準アーキテクチャにフォールバックする構成です。

* GKE標準のCloud Load Balancingへの依存を許容して `nginx-ingress` デプロイ定義を除外し、安定運用へ特化。
* スケジューリングの制約を限定し、オーソドックスなKubernetesのライフサイクル統制の下に管理。

## 5. デプロイ順序制御 (Sync Waves)

リソース生成の依存関係解消のため、ArgoCDの **Sync Wave** を用いたフェージングを実装しています。

* **Wave `-1` (Cluster Policies)**
    Mutating Webhook (コンテナイメージ参照置換等) の事前展開。後続リソース生成前にポリシーを確実に適用・迎撃させるために最優先実行。
* **Wave `0` (Cluster Addons)**
    External Secrets Operator, Prometheus Metrics系など、上位レイヤーが連携を前提とするプロバイダー群の展開。
* **Wave `1` (Infrastructure Middleware)**
    ArgoCDやIngressコントローラー等のトラフィック・オーケストレーション基盤の展開。
* **Wave `2` (Business Applications)**
    全ポリシー・基盤が完全に整った後、`frontend-web` 等のビジネスロジック内包アプリケーションを最後に安全展開。

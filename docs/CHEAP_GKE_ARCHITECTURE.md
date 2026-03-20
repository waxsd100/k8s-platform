# 低コストGKE運用 アーキテクチャ設計書

本リポジトリは、[参考記事](https://zenn.dev/dekimasoon/articles/681bd59130cbb2)で提唱されている「月額約8ドルでのGKE運用」を前提としたアーキテクチャ要件をKustomize/GitOpsへ統合・設計したものです。

## 1. Spot Instanceへの可用性最適化

GKEのノードプールに通常価格より大幅にコストが低い `Spot Instance (e2-small等)` を活用することを前提とします。
Spot Instanceはクラウドプロバイダ側のリソース調整によって不定期にシャットダウンされますが、Kubernetesの可用性制御機能を用いて自律的修復・ダウンタイム抑止を実現しています。

* **`topologySpreadConstraints` の強制定義**:
    `components/apps/frontend-web/base/deployment.yaml` 等にて定義済。同一の物理ノードに対してPodが単一集中することを防ぎ、Spot Instance 1台の停止（Preemption）によるサービス全体のダウンタイムを防止します。
* **`startupProbe` によるルーティングの厳密化**:
    ノード置換直後の不安定なネットワーク状態においてトラフィックが流入しないよう、起動時のDNS名前解決・ヘルスチェック通過を条件とする厳密なProbeを実装しています。
* **Ingress Controllerの選定**:
    Spot Instance切断時のセッション切断やダウンタイム影響が少ないとされる `nginxinc/kubernetes-ingress` を採用しています。

## 2. L4 Load Balancingプロビジョニングの完全回避

Kubernetes標準の `Ingress` リソースを展開すると、自動的にGCPの Cloud Load Balancing (月額固定費: 約$18) がプロビジョニングされます。
このコストを回避するため、リポジトリ内では明示的に `Service` の `type` を `NodePort` (ポート: `30080`, `30443`) としてデプロイしています。

## 3. GitOps管理外リソース (外部インフラストラクチャ構成)

この構成を完遂するには、本GitOpsリポジトリ単体だけではなく、周辺インフラ（Terraform または GCP CLI にて構築）の事前準備を要します。

* **エッジ兼NATルーター (e2-micro)**:
    GCPのFree Tier (常時無料枠) である `e2-micro` VMをK8sクラスタの外部境界として構成します。
    1. **ロードバランサ代替 (Caddy)**: インターネットからの 80/443 トラフィックを当VMで終端し、GKEワーカーノードの NodePort (30080/30443) へリバースプロキシします。
    2. **Cloud NAT代替 (iptables)**: GKEクラスタを「プライベートクラスタ」として構築し、外部通信を当VM経由でIPマスカレード（NAT）実行させることで、Cloud NATの固定費（約$1.4/月 + 従量）を完全に削減します。

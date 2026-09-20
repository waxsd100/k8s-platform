# 低コスト GKE 運用 アーキテクチャ設計書

本プラットフォームは「GKE を動かし続けるための固定費をできるだけ削る」ことを前提に設計されています。ここでは、どこに固定費が発生し、本構成がそれをどう回避しているかを整理します。

## 1. ロードバランサの固定費を回避する (Cloudflare Tunnel)

Kubernetes の `Ingress` や `type: LoadBalancer` の Service を作ると、GCP 側に転送ルールが自動生成され、**トラフィックがゼロでも課金**されます。

| 方式 | 転送ルール料金 | 月額換算 | 備考 |
| :--- | :--- | :--- | :--- |
| グローバル外部 ALB（GKE Ingress / Gateway） | 最初の 5 ルールまで $0.025/時 | 約 $18/ルール | HTTP と HTTPS で 2 ルールになると倍 |
| 外部パススルー NLB（ingress-nginx を `type: LoadBalancer` にした場合） | 同上 | 約 $18 | |
| **Cloudflare Tunnel + ClusterIP の ingress-nginx（本構成）** | **なし** | **$0** | 外部 IP もロードバランサも作らない |

`cloudflared` はクラスタ内から Cloudflare へアウトバウンド接続を張るため、インバウンド用の外部 IP が一切不要です。データ処理料金（$0.008/GiB）も発生しません。

ingress-nginx は置いていますが **`type: ClusterIP`** です。GCP のロードバランサは作られないため固定費はゼロのまま、ホスト名による振り分けだけを担当します。Cloudflare 側は `*.apps.wax100.io` を 1 ルールで nginx に流すだけなので、**アプリを増やしても Cloudflare の設定もコストも増えません**。アプリは `Ingress` を 1 つ持てば公開されます。

出典: [Cloud Load Balancing pricing](https://cloud.google.com/load-balancing/pricing)

## 2. Spot VM とゼロスケール

ノードは `system-pool` を除いてすべて Spot VM です。Spot は通常料金より大幅に安い代わりに、GCP 側の都合で予告付き（30 秒）で停止されます。

- **`platform-{xs,sm,md,lg}`**: 4 ティアを用意し、Cluster Autoscaler が負荷に応じて適切なサイズを選びます。`xs`/`md`/`lg` は最小 0 台で、使われていなければノード自体が存在しません。
- **`apps-pool`**: 最小 0 台。アプリが 1 つも無ければノード課金はゼロです。dev の Canine 管理アプリも、昇格後に Config Sync が管理する本番アプリも、Kyverno の注入により等しくこの Spot プールに載るため、**アプリの実行コストは常に Spot 価格**になります。
- **`system-pool`**: ここだけ通常 VM。kube-system のコンポーネントが Spot の停止で巻き込まれると、クラスタ全体が不安定になるためです。

Spot 停止に備え、プラットフォーム側の Pod には `cloud.google.com/gke-spot` の toleration とノードプール優先度（`preferredDuringScheduling...`）を設定しています。アプリ側の toleration は Kyverno が Admission 時に注入します。

**Node Auto-Provisioning は無効**です。有効のままだと、既存プールに収まらない Pod のために GKE が Spot ではない通常 VM のノードプールを勝手に作り、想定外の課金につながります。

## 3. Canine 本体のコスト特性

| 項目 | 内容 | 目安 |
| :--- | :--- | :--- |
| Cloud SQL (`canine-db`) | PostgreSQL 16 / ZONAL / PD_SSD 10GB | `db-g1-small` で約 $25/月 + ストレージ約 $1.7/月 |
| Canine web + worker | Spot ノード上の 2 Deployment | requests 合計 200m CPU / 1Gi memory |
| Cloud SQL Auth Proxy | web / worker のサイドカー × 2 | requests 各 10m / 32Mi |

**ここが本構成で最大の固定費**です。`canine_db_tier` を `db-f1-micro` に落とせば約 $10/月まで下がりますが、メモリ 0.6 GiB では web と worker の同時接続で不安定になりやすいため、既定は `db-g1-small` にしています。

> **注意**: `db-f1-micro` と `db-g1-small` は共有コアのマシンタイプで、**Cloud SQL の SLA 対象外**です。Google は「低コストのテスト・開発用インスタンス向けであり、本番インスタンスには使用しないでください」と明記しています。可用性を重視するなら 1 vCPU / 3.75 GiB 以上（`db-custom-1-3840`、約 $49/月）へ引き上げてください。出典: [About instance settings](https://cloud.google.com/sql/docs/postgres/instance-settings)

Canine を常時動かす必要がなければ、`canine-db` を停止し web/worker を 0 レプリカにしておく運用も可能です（デプロイ操作のたびに起動する）。

出典: [Cloud SQL pricing](https://cloud.google.com/sql/pricing)

## 4. 監視・ログのコスト

自前の kube-prometheus-stack は運用していません。Prometheus + Grafana を常駐させると、それだけで e2-medium 1 台分のメモリを消費します。

代わりに GKE 標準の `logging_config` / `monitoring_config` を `SYSTEM_COMPONENTS` のみに絞って有効化しています。アプリのログは Canine の UI から参照できます。より細かいメトリクスが必要になった段階で、Google Managed Service for Prometheus（GMP）を有効化してください（コレクタは GKE がマネージドで動かすため、自前の Prometheus より安価です）。

## 5. 削減できていない固定費

正直に列挙しておきます。

- **Cloud SQL**: 上記のとおり最大の固定費。Canine を使う以上 PostgreSQL は必須です。
- **`system-pool` の通常 VM 2 台**: e2-medium × 2。ここを Spot にするとクラスタの安定性と引き換えになります。
- **Cloud NAT**: プライベートクラスタからの外部通信に必要。
- **Artifact Registry のストレージ**: OCI マニフェストとリモートキャッシュの実体分。
- **dev と本番の二重稼働**: 昇格したアプリは `<app>`（Canine 管理）と `prod-<app>`（Config Sync 管理）の両方で動きます。dev が不要になったら Canine 側で削除してください。

## 6. コストを見張る仕組み

想定外の課金を防ぐため、GCP の予算アラートを設定し、閾値超過時に通知（または強制停止）できるようにしておくことを推奨します。ノードプールはすべて最大台数を明示的に上限設定しており（`apps_pool_max_nodes` など）、オートスケールが青天井にならないようにしています。Cloud SQL のディスクも `disk_autoresize_limit` で上限を設けています。

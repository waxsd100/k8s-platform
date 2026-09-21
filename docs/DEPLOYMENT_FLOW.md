# デプロイメント＆リリースフロー

本プラットフォームは **本番を GitOps、開発を Canine** で分担します。どの経路を通るかは「何を、どの環境に変更するか」で決まります。

| 変更対象                                                      | 経路                                                      | 所要時間の目安         |
| :------------------------------------------------------------ | :-------------------------------------------------------- | :--------------------- |
| プラットフォーム基盤（アドオン / ミドルウェア / Canine 自身） | Git → Cloud Build → Artifact Registry (OCI) → Config Sync | 数分                   |
| **本番アプリ**                                                | `components/apps/` への PR → Cloud Build → Config Sync    | 数分                   |
| dev / プレビューのアプリ                                      | アプリの Git リポジトリ → Canine（ビルド → デプロイ）     | 数分                   |
| dev → 本番の初回昇格                                          | Namespace にラベル → 昇格 PR → レビュー → マージ          | 最大 1 時間 + レビュー |
| 昇格済みアプリの追従                                          | dev を更新するだけ → 自動で追従 PR → レビュー → マージ    | 最大 1 時間 + レビュー |

## 1. プラットフォーム変更のフロー

```mermaid
sequenceDiagram
    participant Dev as 開発者
    participant GH as GitHub (k8s-platform)
    participant CI as GitHub Actions
    participant CB as Cloud Build
    participant AR as Artifact Registry
    participant CS as Config Sync
    participant GKE as GKE

    Dev->>GH: feature ブランチを push / PR
    GH->>CI: ci.yml (kustomize build + kubeconform)
    GH->>CI: hydrate.yml (_result.json を生成しコミット)
    Dev->>GH: main へマージ
    GH->>CB: manifest-sync トリガー発火
    CB->>CB: kustomize build --enable-helm clusters/platform
    CB->>AR: tar を OCI イメージとして push (tag: platform)
    CS->>AR: RootSync が platform タグを Pull
    CS->>GKE: 差分を apply
```

### 1.1 ローカルでの事前検証

```powershell
cargo make validate    # kustomize build + kubeconform
cargo make hydrate     # _result.json を再生成
cargo make pre-commit  # 上記2つをまとめて実行
```

`_result.json` は「Config Sync が最終的にクラスタへ送る API オブジェクト」のスナップショットです。PR の差分として現れるため、Helm チャートのバージョンを上げたときに**実際に何が変わるのか**をレビューできます。

### 1.2 CI で走るもの

| ワークフロー          | 内容                                                                                  |
| :-------------------- | :------------------------------------------------------------------------------------ |
| `ci.yml`              | 全 `kustomization.yaml` を `kustomize build` し、`kubeconform -strict` でスキーマ検証 |
| `hydrate.yml`         | `_result.json` を再生成し、差分があれば PR ブランチへコミット                         |
| `format-and-lint.yml` | Prettier と Super-Linter による整形・構文チェック                                     |
| `secret-scanning.yml` | TruffleHog / gitleaks による機密情報スキャン                                          |

### 1.3 Config Sync の適用

`bootstrap/root-sync.yaml`（ブートストラップ時に手で 1 回適用する）が OCI イメージの `platform` タグを監視します。Cloud Build が新しいタグを push すると、RootSync が自動的に差分を取り込みます。

デプロイ順序は `config.kubernetes.io/depends-on` アノテーションで制御しています。

1. **Kyverno**（`addons/kyverno`）— 後続 Pod のイメージ書き換えを確実に行うため最優先
2. **External Secrets**（`addons/external-secrets`）— Kyverno の Admission Controller に依存
3. **Canine**（`components/infrastructure/canine`）— External Secrets が Secret を作ってから起動

### 1.4 ロールバック

Config Sync は Git（正確には OCI タグ）の状態に追従します。`git revert` して main に戻せば、Cloud Build が再ビルドし、クラスタも元に戻ります。緊急時は Artifact Registry 上の以前の `platform-<COMMIT_SHA>` タグを `platform` に付け替えることで、Git を待たずに巻き戻せます。

## 2. dev / プレビューのフロー (Canine)

dev 環境のアプリ定義は本リポジトリには存在せず、Canine の UI（または API）で管理します。本番へ出すときは後述の昇格フローを通ります。

```mermaid
sequenceDiagram
    participant Dev as 開発者
    participant GH as GitHub (アプリのリポジトリ)
    participant CN as Canine (web + worker)
    participant K8s as GKE

    Dev->>GH: main へ push
    GH->>CN: Webhook 通知
    CN->>K8s: ビルド用 Pod を起動 (cluster モードのビルダーは k8s 固定)
    K8s-->>CN: イメージを push
    CN->>K8s: Helm チャートを生成して helm upgrade --install
    K8s-->>CN: Pod の状態とログを返す
```

### 2.1 ビルドの仕組み

`BOOT_MODE=cluster` では、Canine のビルダーは `k8s` に固定されます（`BuildConfiguration::BUILDER_OPTIONS`）。Docker ソケットのマウントは不要で、ビルドはクラスタ内の Pod として実行されます。

ビルダー（BuildKit）は privileged で動くため、Kyverno が専用の **`build-pool`** にだけ載せ、本番アプリとは別ノードにしています。詳細は `docs/CANINE_SETUP.md` の「Build Cloud」を参照してください。

### 2.2 公開

dev 環境のアプリは Canine の中だけで完結するため、既定では外部公開されません。dev のまま外から触りたい場合だけ、Cloudflare のトンネル設定（`terraform/cloudflare-tunnel.tf`）にホスト名を足してください。

**本番に昇格したアプリは自動で公開されます。** 昇格ジョブが `Ingress` を生成し、`*.apps.wax100.io` を ingress-nginx にまとめて流しているワイルドカードのルールが拾うため、Cloudflare 側の作業も DNS の追加も要りません。

### 2.3 ロールバック

dev 環境は Canine の UI からリビジョンを選んでロールバックします（Helm のリリース履歴に相当）。本番は `git revert` してマージすれば Config Sync が元に戻します。

### 2.4 スナップショット (canine-snapshot)

Canine は真実の源をデータベース (`wax100-db`) に持ちますが、変更履歴の追跡と障害時の復旧材料として、日次で全 dev Namespace の実体を専用の Git リポジトリ (`canine-apps-snapshot`) へ一方向でコミットしています。このリポジトリはバックアップ専用であり、手動で編集してもクラスタには反映されません。

## 3. 昇格フロー (dev → 本番)

```mermaid
sequenceDiagram
    participant Dev as 開発者
    participant CN as Canine (dev namespace)
    participant PJ as canine-promote CronJob
    participant GH as GitHub (k8s-platform)
    participant CS as Config Sync

    Dev->>CN: UI でアプリを作り dev で確認
    Dev->>CN: kubectl label ns <app> wax100.io/promote=true (初回のみ)
    PJ->>CN: 毎時 15 分、ラベル付き + 追従対象の Namespace を検出
    PJ->>PJ: 実体を base + overlays/production に整形
    PJ->>GH: ブランチを push し Pull Request を作成
    PJ->>CN: ラベルを promote=done に書き換え
    Dev->>GH: レビューしてマージ
    GH->>CS: Cloud Build 経由で OCI が更新され同期
    CS->>CS: prod-<app> を作成・管理開始
```

### 3.1 生成されるもの

```text
components/apps/<app>/
├── base/
│   ├── kustomization.yaml
│   └── resources.yaml            # dev の実体（再昇格で上書きされる）
└── overlays/production/          # すべて初回のみ生成。以降は上書きしない
    ├── kustomization.yaml        # namespace: prod-<app>
    ├── namespace.yaml
    ├── ingress.yaml              # <app>.apps.wax100.io で公開
    ├── hpa.yaml                  # Deployment ごとの HPA（CPU 使用率で台数を変える）
    └── external-secret.yaml      # 参照している Secret の雛形
```

本番固有の差分（リソース要求、HPA の値など）は **overlay 側に書いてください**。

**本番は実際の負荷で台数が変わります。** 昇格ジョブが Deployment ごとに HPA（最小 2・最大 5・CPU 使用率 70%）を生成し、同じ overlay で base の `replicas` を消すパッチを当てます（残すと Config Sync が `replicas` を書き戻し、HPA と取り合う）。最小 2 は apps-pool が Spot だから（1 本だと回収で止まる）。メモリは指標にしません（使ったメモリを返さないランタイムが多く、増えたまま減らなくなる）。StatefulSet には付けません。dev は Canine が `replicas` を持つので、HPA は本番だけです。dev に HPA を置いている Deployment は、それをそのまま使います。
`base/resources.yaml` は再昇格のたびに上書きされます。

**Ingress は自動生成されます。** `http` という名前のポート、なければ 80、3000 の順で Service を選び（Headless と ExternalName は除く）、`<app>.apps.wax100.io` へのルールを作ります。Cloudflare 側の設定も DNS も不要です。dev の Ingress は持ち込みません（dev と本番で同じホストを取り合うため）。

**ExternalSecret は雛形が自動生成されます。** 昇格ジョブは Secret の値を読みません（RBAC 上も読めません）。Pod テンプレートの `secretKeyRef` / `envFrom.secretRef` / `secret`・`projected` ボリューム / `imagePullSecrets`、ServiceAccount の `imagePullSecrets` から **参照名とキーだけ**を集めて雛形を組み立てます。値は Secret Manager に `prod-<app>-<secret名>-<キー名>` の ID で登録してください（大文字・小文字・`_` はそのまま、`.` は `-` に置き換え。置き換えで重なるときと 255 文字を超えるときは末尾にハッシュが付くので、**PR 本文に出た ID をそのまま使ってください**）。`imagePullSecrets` の Secret は `kubernetes.io/dockerconfigjson` 型で作られ、Secret Manager には docker の `config.json` の中身をそのまま入れます。**登録するまで本番の Pod は起動しません。** PR 本文に必要な ID の一覧が出ます。

**ReadWriteOnce の PVC を付けた Deployment には HPA を付けません。** ディスクは 1 ノードにしか付かないので、`replicas: 1`・更新方法 `Recreate` にして昇格します（Canine の既定の RollingUpdate だと、新しい Pod が別ノードに載ったときに更新が止まる）。Canine の Volume の PVC（`storageClassName: manual`。ノードのディスクを指す hostPath の PV 用）は、StorageClass を外してクラスタの既定（Persistent Disk）で作り直します。

**DB はアプリと一緒に昇格します。** アプリの DB は dev も本番もクラスタ内に置きます。Canine のアドオン（`groundhog2k/postgres` / `groundhog2k/mysql`）をアプリと同じ Namespace に入れておくと、昇格ジョブが StatefulSet と PVC も持ち込み、本番は `prod-<app>` の中に空の DB が立ちます。DB のパスワードは他の Secret と同じく、PR 本文の ID で Secret Manager に登録します。バックアップは dev・本番とも毎日取られます（[GKE_SETUP_GUIDE.md](GKE_SETUP_GUIDE.md) の 8.8）。

### 3.1.1 2 回目以降（追従）

一度 `components/apps/` に載ったアプリは、**ラベル無しで自動的に追従されます**。ジョブが毎時 dev の状態を見に行き、差分があれば PR を立てます。同じアプリの PR が開いている間は新しい PR を立てません。

### 3.2 昇格時に落とされるもの

- `status` と、更新のたびに変わるメタデータ（`resourceVersion` / `uid` / `generation` など）
- 新しい Namespace で再採番される値（Service の `clusterIP`・`nodePort`、PVC の `volumeName`）
- 他リソースが所有しているもの（CronJob が作った Job など）と、既定の ServiceAccount
- **許可リストに無い kind すべて**。持ち込むのは Deployment / StatefulSet / DaemonSet / CronJob / Service / ConfigMap / PersistentVolumeClaim / HorizontalPodAutoscaler / ServiceAccount / NetworkPolicy だけです。**Secret** は入りません（昇格ジョブは RBAC 上も読めません。機密は `ExternalSecret` 経由）。Ingress も dev のものは持ち込まず、本番用を別に生成します
- Service の外部公開の設定。`type: LoadBalancer` / `NodePort` は `ClusterIP` に変え、`loadBalancerIP` などを外します（本番の入口は Cloudflare Tunnel → ingress-nginx だけ。LoadBalancer は Access を通らない入口と固定費を作る）。Headless Service（`clusterIP: None`）はそのまま残します

dev から昇格対象が一時的に消えても（アプリの削除や再デプロイの途中）、**本番の定義は変更しません**。本番から外すときは `components/apps/<app>` を消す PR を人が出します。

### 3.3 昇格後

その Namespace は Config Sync の管理下に入り、Kyverno の `canine-namespace-boundary` が Canine からの書き込みを拒否します。本番の変更は `components/apps/` への PR で行います。dev 側を更新すれば追従 PR が自動で立ちます。

PR のマージは**常に手動**です。本番に出るものは必ず人が見る、という前提を保っています。

## 4. 経路が交差する箇所

| 事象                                 | 影響                                                                                                                                                                                                                                                               |
| :----------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kyverno のレジストリ書き換えポリシー | Canine がデプロイするアプリの Pod にも適用される。プライベートレジストリを使う場合は除外設定が必要                                                                                                                                                                 |
| Kyverno の既定 requests              | requests も limits も書いていないアプリのコンテナに `cpu: 100m` / `memory: 128Mi` の requests が入る（作成時のみ）。requests が 0 のままだとオートスケーラが apps-pool を増やさず、HPA も使用率を計算できないため。本番で変えたいときは overlay で requests を書く |
| `apps-pool` の上限                   | `apps_pool_max_nodes` を超えるとアプリが Pending になる。Canine 側からは「起動しない」ように見える                                                                                                                                                                 |
| Canine 本体の停止                    | 稼働中のアプリは動き続ける（Canine はコントロールプレーンのみ）。dev の新規デプロイとログ参照ができなくなる。**本番は影響を受けない**（Config Sync が管理しているため）                                                                                            |
| `wax100-db` の喪失                   | **dev の定義が失われる**（ただし `canine-apps-snapshot` リポジトリの日次スナップショットから復旧可能）。本番は Git にあるため無傷                                                                                                                                  |

## 5. 認証情報

- **Cloud Build → Artifact Registry**: `cloudbuild_sa` サービスアカウント（Terraform 管理）
- **Config Sync → Artifact Registry**: `config-sync-sa` + Workload Identity。リポジトリ認証情報をクラスタに置かない
- **Canine → Cloud SQL**: `canine-sa` (KSA) → `canine-sa@<project>.iam.gserviceaccount.com` (GSA) の Workload Identity バインディング
- **Canine → GKE API**: ServiceAccount トークンから組み立てる in-cluster kubeconfig
- **Canine → GitHub**: Canine の UI から GitHub App / OAuth を接続（Canine のデータベースに保存）
- **昇格ジョブ → GitHub**: Secret Manager の `canine-promote-github-token`（k8s-platform の Contents / Pull requests: Read and write）

---
name: kubevela-app-deploy
description: Guide for naming, deploying, debugging, promoting to production, and cleaning up applications on this GKE KubeVela / VelaUX platform (k8s-platform). Use whenever the user asks how to create or configure a new app, project, target, environment, secret, ingress, database, or prod promotion on VelaUX.
---

# KubeVela / VelaUX アプリ作成・運用ガイド（k8s-platform）

このスキルは、`waxsd100/k8s-platform` 上の KubeVela（`vela-core` 1.12）＋ VelaUX で新しいアプリを設計・作成・本番昇格・片付けする際の標準手順と制約をまとめたものです。

ユーザーが新しいアプリ名（例: `RoboPolis`）を挙げて作り方を聞いてきたら、下の規則に沿って `<app>` を具体的な小文字ケバブケース（例: `robopolis`）へ当てはめて案内してください。

## 1. プロジェクト・環境・ターゲットの役割と使い分け

| 概念                                | 役割                                                 | この基盤での標準ルール                                                                                       |
| :---------------------------------- | :--------------------------------------------------- | :----------------------------------------------------------------------------------------------------------- |
| **プロジェクト（Project）**         | チーム・権限（RBAC）・Configs / Pipelines の管理境界 | 既定の **`Develop`** を使う（新設不要）。本番閲覧は自動連携される **`Production (GitOps Read-Only)`** を使う |
| **ターゲット（Delivery Target）**   | 配置先の実体（`Cluster + Namespace`）                | アプリごとに **`dev-<app>`** を 1 つ作成（クラスター `local`、Namespace `dev-<app>`）                        |
| **環境（Environment）**             | Application のデプロイ先（Target の束）              | アプリごとに **`dev-<app>`** を 1 つ作成し、Target `dev-<app>` と Namespace `dev-<app>` を紐付ける           |
| **アプリケーション（Application）** | ワークロード・DB・トレイトを束ねたアプリ本体         | 名前 **`<app>`** として環境 `dev-<app>` へデプロイ（本体＋同居 DB 等を 1 Application にまとめてよい）        |

> 個人・少人数運用では **`Develop` プロジェクト 1 つ**で全開発アプリを管理して問題ありません。別の権限境界や Configs/Secret スコープを分離したい場合のみ新設します。

## 2. 命名規則（必須制約）

`vela-promote` は **Dev Namespace 名 `dev-<app>` から先頭の `dev-` を除いた文字列** を `<app>` として本番 Namespace・Git パス・URL を自動生成します。

| 項目                       | 命名ルール                                             | 例（RoboPolis）                                 |
| :------------------------- | :----------------------------------------------------- | :---------------------------------------------- |
| `<app>` 名                 | 英小文字・数字・ハイフンのみ、1〜49 文字（予約名不可） | `robopolis`                                     |
| Dev Namespace              | `dev-<app>`                                            | `dev-robopolis`                                 |
| Target 名 / Environment 名 | `dev-<app>`（別名は任意）                              | `dev-robopolis`（別名: `RoboPolis Dev`）        |
| Application 名             | `<app>`（別名は任意）                                  | `robopolis`（別名: `RoboPolis`）                |
| Dev 公開 URL（任意）       | `dev-<app>.wax100.io`（`dev-` 接頭辞＋1 階層下必須）   | `dev-robopolis.wax100.io`                       |
| 本番 Namespace（自動）     | `prod-<app>`                                           | `prod-robopolis`                                |
| 本番公開 URL（自動）       | `<app>.wax100.io`                                      | `robopolis.wax100.io`                           |
| 本番 GitOps パス（自動）   | `components/apps/<app>/{base,overlays/production}`     | `components/apps/robopolis/`                    |
| 本番 Secret Manager 名     | `prod-<app>_<secret名>-<key名>`                        | `prod-robopolis_robopolis-secret-DISCORD_TOKEN` |

### 使用禁止の予約名・制約

- **予約アプリ名（使用不可）**: `vela`, `velaux`, `kubevela`, `dashboard`, `backup`, `infra`, `kyverno`, `headlamp`, `reloader`, `dev-access`, `default`, `prod`, `www`, `dev`
- **禁止 Namespace**: `default`, `develop`, `prod`, `prod-*`, `kube-*`, `gke-*`, `gmp-*`, `config-management-*`, `resource-group-system`, `infra`, `kyverno`, `external-secrets`, `reloader`, `headlamp`, `dev-access`, `vela-system`, `velaux-store`
- **URL 階層**: Cloudflare Universal SSL は `*.wax100.io` の **1 階層下のみ** 有効。`<app>.dev.wax100.io` のような多段サブドメインは Kyverno（`ingress-hosts-by-environment`）が拒否します。

## 3. 新規アプリ作成手順（VelaUX UI）

### Step 1: 配信ターゲットを作成

左メニュー **「配信ターゲット」→「新規作成」**:

- **名前**: `dev-<app>`（別名: 任意）
- **プロジェクト**: `Develop`
- **クラスター**: `local`
- **Namespace**: プルダウン右の **「新規作成」** ボタン → `dev-<app>` を作って選択
  - 作成時に Kyverno（`label-velaux-created-dev-namespace`）が自動で `usage.oam.dev/runtime=target` を付与し、gVisor（GKE Sandbox）・`apps-pool` 配置・ネットワーク隔離・`wax100-dev` 権限が即座に有効化されます。
- **共有変数**: **OFF のまま**（本基盤は Terraform Controller アドオン不使用のため未入力でよい）

### Step 2: 環境を作成

`Develop` プロジェクト → **「環境」→「新規作成」**:

- **名前**: `dev-<app>`（別名: 任意）
- **Namespace**: `dev-<app>`
- **ターゲット**: `dev-<app>` を選択

### Step 3: 機密情報（Secret）を事前作成（必要な場合のみ）

API キー・Bot トークン・DB パスワード等を環境変数や ConfigMap に平文直書きすると、本番昇格時に `vela-promote` の機密スキャナが検知して昇格を停止します。先に Dev Namespace へ Kubernetes Secret を作成してください。

```bash
kubectl --context wax100-dev -n dev-<app> create secret generic <app>-secret \
  --from-literal=API_KEY='...'
```

コンポーネント側からは `env` トレイトの `valueFrom.secretKeyRef`（または `storage.secret`）で参照します。

### Step 4: アプリケーションを作成

`Develop` プロジェクト → **「アプリケーション」→「新規作成」**:

- **名前**: `<app>` / **環境**: `dev-<app>`
- コンテナイメージは事前に Docker Hub / GHCR / Artifact Registry へ push 済みのものを使用（クラスタ内にビルダーは置かない）。

#### 利用可能な厳選 48 定義（`vela-application-guard` 許可リスト）

- **ComponentDefinition（5 種）**:
  - `webservice`: HTTP/Web サーバー・API（外部公開や Service を伴う常駐アプリ）
  - `worker`: Discord Bot・キューワーカー等（外部公開不要の常駐プロセス）
  - `task`: 1 回実行ジョブ（マイグレーション等）
  - `cron-task`: 定期バッチ（CronJob）
  - `statefulset`: DB（PostgreSQL / MySQL / MariaDB 等）や永続ステートを持つワークロード
- **主な TraitDefinition（全 25 種）**:
  - 公開: `gateway` または `ingress-1-20`（Dev は `dev-<app>.wax100.io` のみ）、`expose`
  - 設定・機密: `env`、`annotations`、`labels`、`command`、`lifecycle`、`startup-probe`
  - ストレージ: `storage`、`volumes`、`pvc`（`standard-rwo` のみ。`hostPath` / `manual` 等は禁止）
  - 拡張・制御: `scaler`、`hpa`、`cpuscaler`、`resource`、`k8s-update-strategy`、`init-container`、`sidecar`、`affinity`、`topologyspreadconstraints`、`hostalias`、`securitycontext`、`podsecuritycontext`、`service-account`（`privileges` 指定不可）
- **PolicyDefinition（6 種）**: `topology`（自 Namespace・`local` のみ）, `override`, `apply-once`, `read-only`, `garbage-collect`, `shared-resource`
- **WorkflowStepDefinition（7 種）**: `deploy`, `apply-component`, `apply-application`, `suspend`, `step-group`, `clean-jobs`, `print-message-in-status`
- **SourceDefinition（5 種、1.12+）**: `configmap-local`, `vela-config`, `vela-env`, `vela-app`, `vela-component`（CEL `$( )` 式を使う場合は Application に `app.oam.dev/cel-expressions: "true"` アノテーションを付与）

#### 補足・禁止事項

- **PostgreSQL 拡張（`pgvector` 等）を使う場合**: DB コンポーネントに `annotations` トレイトで `wax100.io/postgres-extensions: "vector"` を付与してください。
- **使用不可（VAP が拒否）**: `k8s-objects` / `raw` / `ref-objects` / `vela-cli` / `apply-terraform-*` / `daemon` / `helm`、`app.oam.dev/{service-account-name,username,group}` アノテーション、`service-account` の `privileges`、他 Namespace や非 `local` クラスタ向けの `topology`、`hostPath` ボリューム、`type: ExternalName` Service。

## 4. Dev 環境のデバッグ（port-forward）

Dev の Pod はすべて gVisor（GKE Sandbox）で動くため直接の `kubectl port-forward` が使えません。中継スクリプトを使用してください。

```bash
bash hack/dev-port-forward.sh dev-<app> <Service名> <ポート> [ローカルポート]
# 例: bash hack/dev-port-forward.sh dev-robopolis postgres 5432
```

## 5. 本番への昇格（`vela-promote`）

Dev で動作確認できたら、管理者コンテキストで Dev Namespace にラベルを付けます（毎時 15 分に自動で本番用 PR が生成されます）。

```bash
# 基本: 本番昇格を有効化
kubectl --context wax100-admin label ns dev-<app> wax100.io/promote=true

# Dev に Ingress/gateway が無く、本番だけ https://<app>.wax100.io で公開したい場合
kubectl --context wax100-admin label ns dev-<app> wax100.io/public=true

# Discord Bot 等、2 台同時起動で壊れる構成を 1 台・Recreate 固定で昇格したい場合
kubectl --context wax100-admin label ns dev-<app> wax100.io/single-replica=true
```

毎時 15 分を待たずに即時実行する場合:

```bash
kubectl --context wax100-admin create job --from=cronjob/vela-promote vela-promote-manual -n infra
kubectl --context wax100-admin logs -n infra job/vela-promote-manual -f
```

生成された PR の案内に従って Secret Manager へ `prod-<app>_<secret>-<key>` を登録してマージすると、Config Sync が `prod-<app>` へ同期し、VelaUX の **`Production (GitOps Read-Only)`** プロジェクトから状態・トポロジ・ログを閲覧できるようになります。

## 6. 片付け（削除手順）

1. VelaUX UI で該当する **Application → Environment → Delivery Target** を順に削除します（Target 削除後も gVisor 隔離ラベル `usage.oam.dev/runtime=target` は Kyverno により維持されます）。
2. Namespace 本体も完全に消す場合は、管理者コンテキストから `kubectl` で削除します（VelaUX UI からは仕様およびセキュリティ上 Namespace 削除不可）。

```bash
kubectl --context wax100-admin delete ns dev-<app>
```

> 同じアプリ名で作り直すだけであれば Namespace を消さずに Target 削除だけで再利用できます。

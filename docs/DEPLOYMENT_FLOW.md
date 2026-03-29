# GitOps デプロイメント＆リリースフロー

本ドキュメントは、アプリケーション (`wax100-blog`) とマニフェスト (`k8s-platform`) の2つの
リポジトリを連携させた、完全自動化された GitOps デプロイフローの全体像を解説します。

---

## 🚀 3つの環境とデプロイの流れ

### 1. Dev (開発) 環境

- **役割**: 最新の開発コードを常に反映・テストする環境。
- **デプロイトリガー**: `wax100-blog` リポジトリの `main` ブランチへのコミット（Push or Merge）。
- **フロー**:
  1. `cloudbuild-main` が起動し、最新コンテナをビルド・Artifact Registry へPush（タグ: `latest` & `[SHORT_SHA]`）。
  2. `deploy-dev.yml` (GitHub Action) が起動し、マニフェストリポジトリの `development` オーバーレイにある Kustomize の `newTag` を `[SHORT_SHA]` に更新してコミット。
  3. Config Sync がマニフェストの変更を検知し、K8s上のDev環境Podを再起動してデプロイ完了。

### 2. Staging (検証) 環境

- **役割**: 本番リリース前の機能検証を行う環境。
- **デプロイトリガー**: `wax100-blog` リポジトリにリリース用ブランチ（例: `release/v1.0.0` 又は `v1.0.0`）を作成し、Pushする。
- **フロー**:
  1. `auto-tag-release.yml` (GitHub Action) が起動し、連番プレリリースタグ（`v1.0.0-1`）を自動算出・付与してPush。
  2. 新規タグ(`v1.0.0-1`)を検知して `cloudbuild-release.yaml` が起動し、コンテナをビルド・Push（タグ: `v1.0.0-1` & `stg`）。
  3. `deploy-stg.yml` (GitHub Action) が起動し、マニフェストリポジトリの `staging` オーバーレイにある Kustomize の `newTag` を `v1.0.0-1` に更新して直接コミット。
  4. Config Sync がマニフェストの変更を検知し、Staging環境へデプロイ完了。
  - **Hotfixの対応**: 同一の `release/v1.0.0` ブランチに修正コミットを追加してPushすると、自動で `v1.0.0-2` タグが打たれ、再度このフローが回ってStagingが更新されます。

### 3. Production (本番) 環境

- **役割**: ユーザーに実際に提供される安定板の環境。
- **デプロイトリガー**: 本番行きにマージするための Pull Request (PR) の承認。
- **フロー**:
  1. Staging向けのプレリリースタグ（`v1.0.0-1`等）が自動発番されたタイミングで、**同時に** `promote-to-prod.yml` (GitHub Action) が起動。
  2. サフィックス(`-1`)を削除したベースタグ名（`v1.0.0`）を付与した状態で、マニフェストリポジトリ内に**本番環境デプロイ用のPull Request**を自動生成。
  3. QA・レビュアーがStaging環境での動作確認後、本番用PRを Approve & Merge。
  4. Config Sync が本番環境向けマニフェストの変更を検知。
  5. アプリケーションリポジトリで **手動で正式リリース版である `v1.0.0` タグをPush** して正式コンテナをビルドする（もしくはその他の正式ビルドフローを経る）ことで、本番環境のPodが `v1.0.0` のイメージを取得して起動する。

---

## 🔒 認証の仕組み (GitHub App)

リポジトリ間でマニフェストの更新やPR作成といった Git 操作を自動で行うため、セキュリティリスクのある Personal Access Token (PAT) ではなく、制限付きの **GitHub App** を用いています。

1. Appは `wax100-blog` および `k8s-platform` 両方にインストール。
2. Actionsの中の `actions/create-github-app-token@v1` ステップによって短命の一時トークンを発行。
3. トークンを用いてコミットを行うことで、GitHub Actions が連鎖的（Pushによる別ワークフローの発火）に起動できるようになっています。

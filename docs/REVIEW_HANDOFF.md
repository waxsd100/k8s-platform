# 敵対的レビューの引き継ぎメモ

このファイルは作業用の引き継ぎメモです。PR をマージする前に削除してください。

- ブランチ: `claude/beautiful-mayer-mn7xuh`
- PR: <https://github.com/waxsd100/k8s-platform/pull/32>（ドラフト）
- 依頼: リポジトリ全体を敵対的にレビューし、改善点を修正する。特にセキュリティを重視する。
  ファイルの読み書きは Haiku のサブエージェントに任せる
- 最終更新: 2026-11-16 17:10 UTC

## 進め方の決まりごと

- `_result.json` は手で触らない。PR 上の hydrate ワークフローが再生成して、このブランチに自動コミットする。
  そのため push の前に必ず `git fetch origin claude/beautiful-mayer-mn7xuh` と `git merge --no-edit FETCH_HEAD` を行う
- コミットの前に CI と同じ書式チェックを通す:
  `npx --yes prettier@3.10.1 --ignore-path .github/linters/.prettierignore --check <ファイル>`
- 検証用のバイナリは scratchpad に置いてある（コンテナが変わると消える）。
  `tf/`（terraform 1.17.2）、`kyv/`（helm 4.3.0、kustomize 5.8.1、Kyverno CLI 1.19.1、チャート kyverno 3.9.1）、
  `wf/al/bin/actionlint`
- 検証できていないことは、できたと書かない

## 完了してコミット済み

1. Terraform（1 回目）: `cluster_operator_members` の検証、Fleet 登録の `depends_on` に build-pool、
   Config Sync の Artifact Registry 読み取りを `config-sync-repo` に限定、restic の鍵の Secret に `prevent_destroy`
2. `manifest-backup.sh`: kubectl 失敗＋空の List を正常扱いにしていた不具合。`promote.rb`: env の平文を PR の注記で警告
3. ドキュメントと CI: 鍵を作業ツリーの外に作る手順、`.gitignore`、手動ビルドをトリガー実行に統一、
   MySQL の復元でパスワードを引数に渡さない、実装との食い違いの訂正、全ジョブに `timeout-minutes`
4. Kyverno: Helm フック 6 オブジェクトを描画から外す。`headlamp-backup-ops` で Pod ラベルを CronJob と一致させる
5. backup: 本番の PVC が `Lost`、または Pod が使っているのに Bound でないときはエラーにする。
   dev-access: egress の NetworkPolicy を追加（宛先は dev の Namespace と DNS だけ）
6. ワークフロー: hydrate を `render`（権限なし。PR のコードを実行）と `commit`（書き込み権限あり。PR のコードを実行しない）に分割。
   `secret-scanning` の push の対象に `promote/**` を追加
7. Terraform（2 回目）: ESO の読み取りを許可リストに変更、Secret Manager の `DATA_READ` 監査ログ、
   `maintenance_policy`、内部ファイアウォールの送信元を限定、state バケットに `prevent_destroy`、文書の訂正

検証の状況:

- Terraform は `fmt -check` と `validate` が成功。`plan` は認証が無いので未実行
- Kyverno の 4 はコピーのレンダリングと Kyverno CLI で確認。実クラスタでは未確認
- 6 の hydrate の分割は GitHub 上でしか確かめられない。**PR の `render` と `commit` の実行結果を必ず見る**
- NetworkPolicy と IAM 条件は実環境で未確認

## 適用するときの注意

- ESO の許可リストに TLS 証明書の Secret は入っていない（名前がリポジトリに無い）。
  使っている場合は `terraform/secrets.tf` の `local.eso_platform_secret_ids` に足す
- Config Sync の Artifact Registry 権限は付け替えになる。構築済みの環境では apply の間だけ取得が失敗しうる
- hydrate のジョブ名が `hydrate` から `render` と `commit` に変わった。必須チェックに `hydrate` を指定していれば直す
- 旧バケット `wax100-db-backups` は、apply の前に state から外す（`docs/BACKUP.md` の 6 章）

## 作業中（Haiku の担当に依頼済み。未コミット）

作業ツリーに途中の変更が残っている可能性がある。引き継ぐ場合は `git status` と `git diff` を見て、下の仕様と照らしてから続ける。

### B. 昇格ジョブのセキュリティ強化（`canine-promote/base/promote.rb` と `cronjob.yaml`）

リポジトリは公開で、昇格ブランチはレビューの前に push される。

1. 機密らしい値を見つけたら、書き出す前に昇格を止める。値での判定（PEM の秘密鍵、AWS・GitHub・Slack・Stripe・Google の鍵の形、
   パスワード入りの URL）と、env の名前での判定（`_PASSWORD`、`_TOKEN`、`_API_KEY` などで終わり、値が直接書かれている）。
   エラーに値は出さない
2. NetworkPolicy を昇格の対象から外す（本番では追加の許可にしかならず、dev の緩い許可が本番に入る）
3. Service の `externalIPs` を種類を問わず落とす
4. 生成する本番の Namespace に Pod Security Admission のラベルを付ける（enforce: baseline、warn と audit: restricted）
5. 追跡中のアプリの取り出し元を名前だけで決めず、`caninemanaged=true` のラベルを必須にする

### E. Kyverno の追加（`addons/kyverno/base/`）

1. アプリの Pod に `priorityClassName` を指定させない（`platform-ingress` を指定すると本番の Pod を追い出せる）
2. `seccompProfile` を省略した Pod に `RuntimeDefault` を既定で入れる（今は省略すると Unconfined のまま通る）
3. `canine-promote` の ServiceAccount が Namespace にできる変更を、`wax100.io/promote` のラベルだけに限る
   ValidatingAdmissionPolicy を足す（新しいファイル `validatingadmissionpolicy-canine-promote-boundary.yaml`）

Kyverno CLI でのテストを必須にする。CEL は実際の評価器で式を確かめる。

## 直せないと判断したもの、直さないもの

- **rest-server の GCS 削除権限**: IAM では絞れない。rest-server は一時ファイルに書いてからリネームし、
  GCS FUSE のリネームはコピーと削除なので、削除権限を外すとバックアップが失敗する。
  守りは `--append-only` と 30 日のソフトデリート。文書を実態に合わせた
- **手動トンネルで ID が空のとき何も作られない**: ファイル冒頭に明記された意図どおりの挙動
- **Service の externalIPs を Kyverno で拒否**: GKE は既定で拒否するので足さない（昇格側で落とすだけ）
- **registry-mirror が kube-system を書き換える**: Kyverno の既定の resourceFilters で対象外

## 判断が要るので手を付けていないもの（最終報告に載せる）

- バックアップ失敗の通知が無い（通知先を決める必要がある）
- 昇格用の PAT と main のブランチ保護（リポジトリの設定で、コードには無い）
- Kyverno と ESO の Webhook が Spot の 1 台に 1 レプリカ（費用との兼ね合い）
- `canine_admin_emails` と `cloudflare_account_id` の既定値がコミットされている（公開リポジトリ）
- Cloudflare の HSTS と TLS の設定がコードに無い（API トークンの権限が要る）
- `canine-system` が gVisor と分離の対象外
- Cloud Build が CI の検証を通さずに `platform` タグを更新する
- restic の保持が Pod 名ごとのグループになり、Deployment の DB では間引きが効かない
- pgvector などのイメージがダイジェストで固定されていない

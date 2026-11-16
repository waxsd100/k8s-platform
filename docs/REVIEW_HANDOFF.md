# 敵対的レビューの引き継ぎメモ

このファイルは作業用の引き継ぎメモです。PR をマージする前に削除してください。

- ブランチ: `claude/beautiful-mayer-mn7xuh`
- PR: <https://github.com/waxsd100/k8s-platform/pull/32>（ドラフト）
- 依頼: リポジトリ全体を敵対的にレビューし、改善点を修正する。特にセキュリティを重視する。
  ファイルの読み書きは Haiku のサブエージェントに任せる
- 最終更新: 2026-11-16 16:50 UTC

## 進め方の決まりごと

- `_result.json` は手で触らない。PR 上の `hydrate` ワークフローが再生成して、このブランチに自動コミットする。
  そのため push の前に必ず `git fetch origin claude/beautiful-mayer-mn7xuh` と `git merge --ff-only FETCH_HEAD` を行う
- 検証用のバイナリは `/tmp/claude-0/.../scratchpad/` に置いてある（コンテナが変わると消える）。
  `tf/`（terraform 1.17.2）、`kyv/`（helm 4.3.0、kustomize 5.8.1、Kyverno CLI 1.19.1、チャート kyverno 3.9.1）
- 検証できていないことは、できたと書かない

## 完了してコミット済み

| コミット  | 内容                                                                                                                                                                                                                | 検証                                                                            |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `8fe2b7c` | Terraform: `cluster_operator_members` の検証、Fleet 登録の `depends_on` に build-pool、Config Sync の Artifact Registry 読み取りを `config-sync-repo` に限定、restic の鍵の Secret とバージョンに `prevent_destroy` | `fmt -check` と `validate` は成功。`plan` は未実行                              |
| `736d040` | `manifest-backup.sh`: kubectl 失敗＋空の List を正常扱いにしていた不具合。`promote.rb`: env の平文を PR の注記で警告                                                                                                | 実物のスクリプトで 3 通りの分岐と注記の有無を確認                               |
| `356f0b9` | ドキュメントと CI: 鍵を作業ツリーの外に作る手順、`.gitignore`、手動ビルドをトリガー実行に統一、MySQL の復元でパスワードを引数に渡さない、実装との食い違いの訂正、全ジョブに `timeout-minutes`                       | YAML の構文確認のみ                                                             |
| `74d459d` | Kyverno: Helm フック 6 オブジェクトを描画から外す（`webhooksCleanup.enabled` と `crds.migration.enabled` を false）。`headlamp-backup-ops` で Pod ラベルを CronJob と一致させる                                     | コピーをレンダリングして差分を確認。Kyverno CLI でラベル違いの Job が拒否される |

`74d459d` で未検証のこと: 実クラスタでの CronJob 参照（apiCall）と、Headlamp の「Spawn Job」が Pod テンプレートのラベルをそのまま写すこと。

## 作業中（Haiku の担当に依頼済み。未コミット）

Haiku の利用上限で一度止まり、16:47 UTC に再開した。作業ツリーに途中の変更が残っている可能性がある。
引き継ぐ場合は `git status` と `git diff` を見て、下の仕様と照らしてから続ける。

### A. Terraform のセキュリティ強化（`terraform/`、`docs/BACKUP.md`、`docs/ARCHITECTURE.md`、`README.md`）

1. ESO のシークレット読み取りを除外方式から許可方式に変える（`secrets.tf` の `eso_secret_accessor` の IAM 条件）。
   許可するのは ExternalSecret が実際に参照する基盤のシークレットと、`prod-` で始まるものだけ。
   条件は `resource.name.startsWith("projects/<番号>/secrets/<id>/versions/")` の形にする
2. Secret Manager の `DATA_READ` 監査ログを有効にする（`google_project_iam_audit_config`）
3. クラスタに `maintenance_policy` を追加する（日本時間の土日 02:00〜10:00。UTC の金土 17:00 から 8 時間）
4. 内部ファイアウォールの送信元を `10.0.0.0/8` からノードのサブネットと Pod の範囲に絞る
5. state バケットに `prevent_destroy` を付け、バージョニングが無ければ有効にする
6. 文書の訂正: rest-server の GCS 権限は削除を含む（下の「直せないと判断したもの」）、
   README の「外部 IP を持たない」（コントロールプレーンの DNS エンドポイントは外から届き、IAM で守る）、
   ARCHITECTURE の Kyverno 停止時の影響範囲、BACKUP の旧バケット移行の手順の順序

### B. 昇格ジョブのセキュリティ強化（`canine-promote/base/promote.rb` と `cronjob.yaml`）

リポジトリは公開で、昇格ブランチはレビューの前に push される。

1. 機密らしい値を見つけたら、書き出す前に昇格を止める。値での判定（PEM の秘密鍵、AWS・GitHub・Slack・Stripe・Google の鍵の形、
   パスワード入りの URL）と、env の名前での判定（`_PASSWORD`、`_TOKEN`、`_API_KEY` などで終わり、値が直接書かれている）。
   エラーに値は出さない
2. NetworkPolicy を昇格の対象から外す（本番では追加の許可にしかならず、dev の緩い許可が本番に入る）
3. Service の `externalIPs` を種類を問わず落とす
4. 生成する本番の Namespace に Pod Security Admission のラベルを付ける（enforce: baseline、warn と audit: restricted）
5. 追跡中のアプリの取り出し元を名前だけで決めず、`caninemanaged=true` のラベルを必須にする

### C. ワークフローの強化（`.github/workflows/hydrate.yml` と `secret-scanning.yml`）

1. `hydrate.yml` を 2 つのジョブに分ける。PR のコードを実行するジョブには書き込み権限を渡さず、
   `_result.json` だけをアーティファクトで渡す。書き込み権限を持つジョブは PR のコードを一切実行せず、
   パスが `^(addons|components)/.../_result\.json$` に合う通常ファイルで、JSON として正しいものだけをコミットする。
   `actions/upload-artifact` と `download-artifact` は `git ls-remote` で確かめたコミット SHA で固定する（SHA を作らない）
2. `secret-scanning.yml` の push の対象に `promote/**` を足す

この変更は GitHub 上でしか本当には確かめられない。PR 自身の hydrate の実行結果を必ず見る。

### D. backup と dev-access（`backup/base/scripts/targets.rb`、`pvc-backup.sh`、`dev-access/base/`）

1. 本番の PVC が `Lost`、または Pod が使っているのに `Pending` のとき、スキップせずエラーにする
2. `dev-access` に egress の NetworkPolicy を足す。許可は `caninemanaged=true` の Namespace と、必要なら DNS だけ。
   今は egress が無制限で、中継用の Role は Pod の中身を縛っていない

## まだ始めていない

### E. Kyverno の追加（`addons/kyverno/base/`）

1. アプリの Pod に `priorityClassName` を指定させない（`platform-ingress` を指定すると本番の Pod を追い出せる）。
   `clusterpolicy-app-hardening.yaml` に、既存のホスト系のルールと同じ除外で deny を足す
2. `seccompProfile` を省略した Pod に `RuntimeDefault` を既定で入れる（今は省略すると Unconfined のまま通る）
3. `canine-promote` の ServiceAccount が Namespace にできる変更を、`wax100.io/promote` のラベルだけに限る
   ValidatingAdmissionPolicy を足す（今は RBAC でクラスタ全体の Namespace を patch できる）

Kyverno CLI でのテストを必須にする。CEL は `cel-python` などで式を確かめる。

## 直せないと判断したもの、直さないもの

- **rest-server の GCS 削除権限**: IAM では絞れない。rest-server は一時ファイルに書いてからリネームし、
  GCS FUSE のリネームはコピーと削除なので、削除権限を外すとバックアップが失敗する。
  守りは `--append-only` と 30 日のソフトデリート。文書を実態に合わせる（A-6）
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

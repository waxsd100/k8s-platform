# 敵対的レビューの引き継ぎメモ

このファイルは作業用の引き継ぎメモです。PR をマージする前に削除してください。

- ブランチ: `claude/beautiful-mayer-mn7xuh`
- PR: <https://github.com/waxsd100/k8s-platform/pull/32>（ドラフト）
- 依頼: リポジトリ全体を敵対的にレビューし、改善点を修正する。特にセキュリティを重視する。
  ファイルの読み書きは Haiku のサブエージェントに任せる
- 最終更新: 2026-11-16 17:45 UTC

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
7. 昇格ジョブ: 機密らしい値（鍵やトークンの形、パスワード入りの URL、`_PASSWORD` などの名前で値が直接書かれた env）を
   見つけたら書き出す前に止める。NetworkPolicy を昇格の対象から外す。Service の `externalIPs` を落とす。
   本番の Namespace に Pod Security Admission のラベル（enforce: baseline）。
   取り出し元は初回も追従も `caninemanaged=true` を必須にする
8. Kyverno（2 回目）: アプリの Pod の `priorityClassName` を拒否。`seccompProfile` を書かない Pod に `RuntimeDefault` を入れる。
   `canine-promote` の ServiceAccount が Namespace にできる変更を `wax100.io/promote` のラベルだけに限る
   ValidatingAdmissionPolicy（`canine-promote-boundary`）
9. Terraform（2 回目）: ESO の読み取りを許可リストに変更、Secret Manager の `DATA_READ` 監査ログ、
   `maintenance_policy`、内部ファイアウォールの送信元を限定、state バケットに `prevent_destroy`、文書の訂正

検証の状況:

- Terraform は `fmt -check` と `validate` が成功。`plan` は認証が無いので未実行
- Kyverno の 4 はコピーのレンダリングと Kyverno CLI で確認。実クラスタでは未確認
- 6 の hydrate の分割は PR 上で実際に動いた（`render` と `commit` を通って `_result.json` の自動コミットが載った）
- 7 はスクリプト全体をサンプル入力で実行して確認。8 は Kyverno CLI と CEL の評価器（cel-python）で確認。
  どちらも実クラスタと Kubernetes 本体の CEL では未確認
- NetworkPolicy と IAM 条件は実環境で未確認

## 適用するときの注意

- ESO の許可リストに TLS 証明書の Secret は入っていない（名前がリポジトリに無い）。
  使っている場合は `terraform/secrets.tf` の `local.eso_platform_secret_ids` に足す
- Config Sync の Artifact Registry 権限は付け替えになる。構築済みの環境では apply の間だけ取得が失敗しうる
- hydrate のジョブ名が `hydrate` から `render` と `commit` に変わった。必須チェックに `hydrate` を指定していれば直す
- 旧バケット `wax100-db-backups` は、apply の前に state から外す（`docs/BACKUP.md` の 6 章）
- 昇格ジョブは、env に直接書かれたパスワードなどがあるアプリの昇格を止めるようになった。
  止まったら、その値を Secret に移して `secretKeyRef` で参照する
- 昇格ジョブは NetworkPolicy を本番に持ち込まなくなった。本番で追加の許可が要るアプリは `overlays/production` に手で足す
- 本番の Namespace に Pod Security の baseline が効く。安全でない sysctl などを使うアプリは起動できない

## 作業中（Haiku の担当に依頼済み。未コミット）

「判断が要る」として残していた項目のうち、コードで対応できるものを進めている。
作業ツリーに途中の変更が残っている可能性がある。引き継ぐ場合は `git status` と `git diff` を見てから続ける。

### F. 通知と Cloudflare の設定（`terraform/`）

1. バックアップの Job が失敗したら通知する。変数 `alert_email`（既定は空）、メールの通知チャンネル、
   infra の Job の失敗イベントを拾うログベースのアラートポリシー。走らなかった回は検知できない（その旨をコメントに書く）
2. Cloudflare のゾーン設定（Always Use HTTPS、最小 TLS 1.2、HSTS）を変数 `cloudflare_manage_zone_security` で管理できるようにする。
   既定は false（API トークンに Zone Settings の権限が無いと apply が失敗するため）

### G. `canine-system` から Cloud SQL への通信を塞ぐ（`addons/kyverno/base/clusterpolicy-environment-isolation.yaml`）

`canine-system` は gVisor と分離の対象外で、Canine が部品を入れられる。Cloud SQL の範囲だけ egress を塞ぐ
NetworkPolicy `deny-cloudsql-egress` を Kyverno に配らせる。ipBlock だけだと Pod 間通信まで止まるので、
全 Namespace 宛ての許可を同じルールに入れる

### H. restic の保持グループ（`components/infrastructure/backup/base/`、`docs/BACKUP.md`）

DB のダンプのパスに Pod 名が入っており、Deployment の DB では Pod 名が変わるたびに保持のグループが分かれる。
まず本当にそうかを確かめ、そうならパスを安定した名前（Deployment 名。StatefulSet は Pod 名のまま）にする。
復元手順のパスも直す

### I. Cloud Build の検査、GitHub 側の設定の文書化、イメージの固定

1. `cloudbuild.yaml`: `COMMIT_SHA` が空なら失敗させる（`gcloud builds submit` を拒否）。
   main の先頭がすでに進んでいたら失敗させる（古いビルドが `platform` タグを巻き戻さない）
2. `docs/GKE_SETUP_GUIDE.md`: main のルールセット（PR 必須、承認、必須チェック、管理者も例外なし）と PAT の権限を、
   必ず設定することとして書く
3. pgvector と socat のイメージをダイジェストで固定する

### ユーザーの判断待ち

- Kyverno と ESO の Webhook を Spot の 1 台に 1 レプリカのままにするか（費用との兼ね合い）

## 直せないと判断したもの、直さないもの

- **rest-server の GCS 削除権限**: IAM では絞れない。rest-server は一時ファイルに書いてからリネームし、
  GCS FUSE のリネームはコピーと削除なので、削除権限を外すとバックアップが失敗する。
  守りは `--append-only` と 30 日のソフトデリート。文書を実態に合わせた
- **手動トンネルで ID が空のとき何も作られない**: ファイル冒頭に明記された意図どおりの挙動
- **Service の externalIPs を Kyverno で拒否**: GKE は既定で拒否するので足さない（昇格側で落とすだけ）
- **registry-mirror が kube-system を書き換える**: Kyverno の既定の resourceFilters で対象外

## 判断が要るので手を付けていないもの

- Kyverno と ESO の Webhook が Spot の 1 台に 1 レプリカ（費用との兼ね合い。ユーザーに確認中）
- チャートのイメージ（Kyverno、ESO、Reloader、Headlamp）はタグ固定のまま。ダイジェストで固定すると、
  チャートを上げたときに古いイメージのまま動く取り違えが起きるため、チャートのバージョン固定に任せている

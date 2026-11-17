# 敵対的レビューの引き継ぎメモ

このファイルは作業用の引き継ぎメモです。PR をマージする前に削除してください。

- ブランチ: `claude/beautiful-mayer-mn7xuh`
- PR: <https://github.com/waxsd100/k8s-platform/pull/32>（ドラフト）
- 依頼: リポジトリ全体を敵対的にレビューし、改善点を修正する。特にセキュリティを重視する。
  ファイルの読み書きは Haiku のサブエージェントに任せる
- 最終更新: 2026-11-17 12:00 UTC

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
9. 通知と設定: バックアップの Job の失敗をアラートにする（`alert_email`）。Cloudflare のゾーン設定を管理できるようにする（既定は無効）
10. `canine-system` からも Cloud SQL への通信を塞ぐ（`deny-cloudsql-egress`）。整合性チェックでこの CIDR も照合する
11. restic: DB のダンプのパスを安定した名前（Deployment 名。StatefulSet は Pod 名）にし、保持が DB ごとに効くようにする
12. Cloud Build: `COMMIT_SHA` が無いビルドを拒否し、main が先に進んでいたら中断する。
    pgvector と socat のイメージをダイジェストで固定。main のルールセットと PAT の条件を手順書に追加
13. 個人のメールと Cloudflare の ID を既定値から外し、`terraform.tfvars.example` を追加
14. バックアップの見張り: CronJob `backup-watchdog` が 6 時間ごとに他のバックアップを見て、止められている・
    長く成功していないときに失敗し、既存のアラートで届く
15. チャートのイメージ（Kyverno・ESO・Reloader・Headlamp の 8 つ）をダイジェストで固定。
    チャートの版と固定がずれたら整合性チェックが失敗する
16. Cloudflare のゾーン設定を既定で有効にした（API トークンに Zone Settings: Edit が必須）。
    `canine-system` に効くもの・効かないものを ARCHITECTURE.md に記載
17. Terraform（2 回目）: ESO の読み取りを許可リストに変更、Secret Manager の `DATA_READ` 監査ログ、
    `maintenance_policy`、内部ファイアウォールの送信元を限定、state バケットに `prevent_destroy`、文書の訂正
18. 残件レビュー対応・M5 仕上げ:
    - VAP `canine-cluster-boundary`（R5）: NetworkPolicy の直接変更と Role での書き込み権限、`canine-k8s-builder`・`canine-system` での Ingress 作成（本番ホスト横取り防止）、25 個の特権 API グループ、PVC/Volume（`manual`・`dataSource`・`volumeName`・`gcePersistentDisk`・`csi`・`ephemeral`・StatefulSet `volumeClaimTemplates`）、`kubernetes.io/metadata.name` 偽装・管理 Namespace 採用、ClusterRole 参照 RoleBinding の DELETE、Service `externalIPs` をすべて CEL 型安全に拒否。`canine-namespace-boundary` も対象 kind と `prod` / `prod-*` 操作を拡張し、`pin-apps-to-apps-pool` から `wax100.io/sandbox: "false"` の除外を削除
    - `promote.rb` / `addons.rb`: 不正な K8s List や非 Hash / 非配列フィールドに対する型安全な走査（`safe_dig` / `safe_array`）に統一
    - Terraform（M5）: `cloudflare_zero_trust_tunnel_cloudflared_config.main` にも `local.cloudflare_access_enabled` の precondition を追加、`database.tf` に `max_connections = "50"` と JST 月曜コメント修正、`network.tf` の Webhook 開放ポートに `10260` を追加、`gke.tf` で `WORKLOADS` ログ有効化＋`google_logging_project_exclusion`（無料枠 50 GiB/月維持）、古いコメントの修正
    - ドキュメント（M5）: `GKE_SETUP_GUIDE.md`（§1 表崩れ修正・§2 全 21 `.tf` 一覧・DeletingPolicy 追記）、`DEPLOYMENT_FLOW.md`、`CANINE_SETUP.md`（5 ルール Tunnel 表・3 か所ダイジェスト固定）、`ARCHITECTURE.md`、`README.md`、`CHEAP_GKE_ARCHITECTURE.md` を実装に同期

検証の状況:

- Terraform は `fmt -check` と `validate` が成功。`plan` は認証が無いので未実行
- Kyverno の 4・18 はレンダリングと Kyverno CLI（VAP 210 ケースを含む）で確認。実クラスタでは未確認
- 6 の hydrate の分割は PR 上で実際に動いた（`render` と `commit` を通って `_result.json` の自動コミットが載った）
- 7・18 の `promote.rb` / `addons.rb` はサンプル入力と 500 ケースのファジングで確認。8・18 の VAP は Kyverno CLI で確認。
  いずれも実クラスタと Kubernetes 本体の API サーバーでは未確認
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
- **apply の前に `terraform/terraform.tfvars` を作る**（`terraform.tfvars.example` を写して値を埋める）。
  2 つの ID が空のままだと Cloudflare のリソースが作られない（check の警告が出る）
- **Cloudflare の API トークンに「Zone / Zone Settings: Edit」を付ける**（既定で HSTS などを設定するため）。
  ゾーン全体に効くので、同じゾーンに HTTP だけのサイトがあるなら `cloudflare_manage_zone_security = false` にする。
  `security_header` の値の形は実際の API で確かめていない。最初の plan と apply で確認する
- チャートの版を上げるときは、同じ変更で `images:` の固定も直す（直さないと整合性チェックが失敗する）
- バックアップのアラートは実際のログで確かめていない。構築後に、わざと失敗する Job で一度届くことを確かめる
- DB のダンプのパスが変わった（`/work/db/<ns>/<名前>.sql`）。復元手順は `docs/BACKUP.md` を見る
- 本番の Namespace に Pod Security の baseline が効く。安全でない sysctl などを使うアプリは起動できない

## 作業中

なし。依頼された修正はすべてコミット済み。

## 直せないと判断したもの、直さないもの

- **rest-server の GCS 削除権限**: IAM では絞れない。rest-server は一時ファイルに書いてからリネームし、
  GCS FUSE のリネームはコピーと削除なので、削除権限を外すとバックアップが失敗する。
  守りは `--append-only` と 30 日のソフトデリート。文書を実態に合わせた
- **手動トンネルで ID が空のとき何も作られない**: ファイル冒頭に明記された意図どおりの挙動
- **Service の externalIPs を Canine SA 向けの VAP で拒否**: GKE は既定で拒否するので ClusterPolicy は足さない（Canine SA には 18 の VAP で拒否を追加し、昇格側でも落とす）
- **registry-mirror が kube-system を書き換える**: Kyverno の既定の resourceFilters で対象外

## ユーザーが決めたこと

- Kyverno と ESO の Webhook は、Spot の platform-pool 1 台に 1 レプリカのままにする（費用を優先。制約は ARCHITECTURE.md に書いてある）
- `canine_admin_emails`、`cloudflare_account_id`、`cloudflare_zone_id` の既定値は外し、`terraform.tfvars` で渡す

## コードでは対応できず、残っているもの

- **main のルールセットと PAT の条件**はリポジトリの設定で、コードからは確認も強制もできない。
  必ず設定することとして `docs/GKE_SETUP_GUIDE.md` の 3.1 に書いた。設定されているかは未確認
- **過去のコミットには、外した既定値（メールアドレスと 2 つの ID）が残っている。**
  消すには main の履歴の書き換えと強制 push が要る。取り返しがつかないので、ユーザーの指示があるまで行わない
- **rest-server の GCS 削除権限**は IAM では絞れない（上の「直せないと判断したもの」）
- バックアップの見張り（`backup-watchdog`）自身が止まった場合と、クラスタ全体の停止は検知できない
- `canine-system` は gVisor の対象外のまま。アプリ向けの強化は効き、Cloud SQL には届かない（ARCHITECTURE.md の 7 章）
- Kyverno と ESO の Webhook は Spot の 1 台に 1 レプリカのまま（ユーザーの判断）

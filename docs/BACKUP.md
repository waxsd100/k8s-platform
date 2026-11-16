# バックアップ

クラスタの中のデータは、すべて restic で 1 つのリポジトリ（restic 専用のバケット `gs://wax100-platform`）に毎日送ります。
Canine 本体の DB（Cloud SQL `wax100-db`）は別扱いで、Cloud SQL のバックアップと PITR で守ります（[GKE_SETUP_GUIDE.md](GKE_SETUP_GUIDE.md) の 8.1）。

- マニフェスト: `components/infrastructure/backup/base`（スクリプトは `scripts/`）
- バケット・鍵・権限: `terraform/storage.tf`・`terraform/backup.tf`
- 画面: Backrest（`https://backup.wax100.io`。Cloudflare Access の後ろ）

## 1. 何を取っているか

| Job               | 対象                                                                                                                                                                                                                 | いつ           | restic のスナップショット                                          |
| :---------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :------------- | :----------------------------------------------------------------- |
| `db-backup`       | DB のポート（containerPort `5432` = PostgreSQL、`3306` = MySQL / MariaDB）を宣言しているコンテナすべて。イメージは問わない（公式・Bitnami・`pgvector/pgvector` などの派生）（dev・本番。Namespace も台数も問わない） | 毎日 JST 03:30 | DB ごと。`/work/db/<ns>/<名前>.sql`、タグ `db`,`<ns>`              |
| `manifest-backup` | Canine が管理する dev のアプリ定義（Deployment・Service・ConfigMap など。Secret は含まない）                                                                                                                         | 毎日 JST 03:30 | 1 つ。`/work/manifests/<ns>.yaml`、タグ `manifests`                |
| `pvc-backup`      | 本番（`prod-*`）の PVC に保存されたファイル（アップロード・生成物・テーマなど）                                                                                                                                      | 毎日 JST 04:30 | PVC ごと。`/pvc/<ns>/<pvc>`、タグ `pvc`,`<ns>`。持ち主・権限も残る |

- **DB**: `kubectl exec` で DB コンテナの中のツール（`pg_dumpall --clean --if-exists` / `mysqldump` / `mariadb-dump`。いずれもサーバーの全 DB）で論理ダンプを取り、末尾の完了の印を確かめてから送ります。途中で切れたダンプは送りません。
  パスワードは DB コンテナの環境変数（`*_PASSWORD`）か、それが指すファイル（`*_PASSWORD_FILE`。Bitnami のチャートの既定）から、コンテナの中で読みます
  ダンプの名前（`/work/db/<ns>/<名前>.sql`）は、StatefulSet なら Pod 名、Deployment なら Deployment 名です。Deployment の Pod は更新やノードの入れ替えで Pod 名が変わるため、Pod 名を使うと同じ DB が別々に保存され、保持の規則も DB ごとに効きません。同じ Namespace で名前が重なる DB が複数あるとき（複数レプリカなど）は Pod 名を使い、ログに `WARN` を出します。
- **アプリ定義**: Config Sync 管理下（昇格済み = Git が正）の Namespace は対象外です
- **本番の PVC**: ディスクのスナップショットから一時ディスクを作って読みます。アプリの Pod には exec もマウントもしません。
  DB の Pod がマウントしている PVC は、上のダンプで取っているので除きます
- **対象から外す / 足す**: Pod・PVC に `wax100.io/backup: "false"` で外します。DB の PVC をファイルでも取りたいときは PVC に `"true"`
- **対象外**: 上以外の DB（MongoDB など）と、ポートを宣言していない DB のコンテナ（外すときは Pod に `wax100.io/backup: "false"`）、dev の PVC（Canine の Volume。Persistent Disk に置き換えているが、dev のデータは消えてよい前提）、Secret

## 2. 仕組み

```text
db-backup / manifest-backup ──restic──┐
pvc-backup ─スナップショット→一時ディスク→ pvc-backup-mover ──restic──┤
                                      ▼
                          rest-server（--append-only）──GCS FUSE──▶ gs://wax100-platform
                                      ▲
Backrest（backup.wax100.io）──restic──┘  見る・戻す・check だけ
restic-maintenance ──GCS FUSE──▶ gs://wax100-platform  forget / prune / check（毎週日曜 JST 12:00）
```

| 項目           | 内容                                                                                                                                                                                                                                                                                                                                                                                     |
| :------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 消せない       | 取る側の Job と Backrest は rest-server に**追記するだけ**（`--append-only`）。既存のスナップショットは消せない・上書きできない。バックアップの経路で消せるのは UI も exec も持たない `restic-maintenance` だけ。rest-server の GCS 権限には削除が含まれる（名前変更とロックの削除に要るため。IAM では外せない）。rest-server 自体が乗っ取られた場合に残る守りは、次の行のソフト削除だけ |
| 消されても     | バケットのソフト削除で 30 日は戻せる（Terraform の `bucket_soft_delete_days`）                                                                                                                                                                                                                                                                                                           |
| 保持           | 直近 30 日は日ごと、3 か月までは週ごと（`restic-maintenance` の `forget`）                                                                                                                                                                                                                                                                                                               |
| 暗号化         | restic が手元で暗号化してから送る。鍵は Secret Manager の `restic-repository-password`                                                                                                                                                                                                                                                                                                   |
| 権限の制限     | DB への exec は Kyverno の `db-backup-exec-scope` で DB のコンテナだけ。`pvc-backup` が作れる Job は `pvc-backup-job-scope` で restic で送るだけの形に縛る                                                                                                                                                                                                                               |
| 設定の置き場所 | rest-server の URL などは ConfigMap `restic-config`（`config.yaml`）、イメージの版は `kustomization.yaml` の `images` だけ                                                                                                                                                                                                                                                               |

> **restic の鍵（Secret Manager の `restic-repository-password`）を失うと、バックアップは二度と読めません。**
> 構築したら `gcloud secrets versions access latest --secret=restic-repository-password --project=wax100` で取り出し、
> パスワードマネージャーなどクラスタと GCP の外にも保管してください。Terraform では `prevent_destroy` を付けています。

DB と見なすポートは `scripts/targets.rb` の `DB_PORTS` と、Kyverno の `db-backup-exec-scope` の 2 か所にあります。
ずれると `hack/check-backup-consistency.sh`（CI の `cargo make validate`）が落ちます。

## 3. 構築直後にやること

### 3.1 手で 1 回ずつ流す

リポジトリは初回の Job が作ります。

```powershell
kubectl create job --from=cronjob/db-backup db-backup-manual -n infra
kubectl logs -n infra job/db-backup-manual -f

kubectl create job --from=cronjob/manifest-backup manifest-backup-manual -n infra
kubectl logs -n infra job/manifest-backup-manual -f

# 本番に PVC を持つアプリが無ければ「完了: 0 件」
kubectl get volumesnapshotclass pvc-backup
kubectl create job --from=cronjob/pvc-backup pvc-backup-manual -n infra
kubectl logs -n infra job/pvc-backup-manual -f

# GCS FUSE の上で forget / prune / check が通ること
kubectl create job --from=cronjob/restic-maintenance restic-maintenance-manual -n infra
kubectl logs -n infra job/restic-maintenance-manual -c restic -f
```

### 3.2 制限が効いていることを確かめる

```powershell
# DB 以外のコンテナには exec できないこと（拒否されれば正しい）
kubectl exec -n canine deploy/canine --as=system:serviceaccount:infra:db-backup -- true

# rest-server 経由では消せないこと（存在しない ID の削除に 403 が返れば正しい。追記専用でなければ 200 になる）
kubectl exec -n infra deploy/backrest -- sh -c 'curl -s -o /dev/null -w "%{http_code}\n" -u "backup:${RESTIC_REST_PASSWORD}" -X DELETE http://rest-server.infra.svc.cluster.local:8000/snapshots/0000000000000000000000000000000000000000000000000000000000000000'
```

### 3.3 Backrest の初期設定

Cloudflare Access を通ると Backrest の初期設定画面が出ます。設定は Backrest が PVC の `config.json` に持ち、Git では管理しません。

1. インスタンス名（例 `wax100`）と、Backrest 自身のログインユーザーを作る
2. **Add Repository** で次のとおり登録する（rest-server の認証は Pod の環境変数から restic に渡る）

   | 項目           | 値                                                                           |
   | :------------- | :--------------------------------------------------------------------------- |
   | Repository URI | `rest:http://rest-server.infra.svc.cluster.local:8000/`                      |
   | Password       | 空欄（必須と言われたら Secret Manager の `restic-repository-password` の値） |
   | Env Vars       | `RESTIC_PASSWORD_FILE=/etc/restic/password`                                  |
   | Prune Policy   | 無効（追記専用なので失敗する。prune は `restic-maintenance`）                |
   | Check Policy   | 任意（例: 毎月。読むだけなので追記専用でも動く）                             |
   | Auto Unlock    | オフ                                                                         |

3. プランは作らない（取るのは上の Job）。スナップショットはリポジトリの画面に出る

Backrest のフックは任意のコマンドを実行できます。Backrest の Pod には Kubernetes のトークンを持たせておらず、リポジトリにも追記専用でしか届きません。

## 4. ふだんの確認

1 つでも失敗すると Job が失敗になります（残りは続けて取ります）。Job が失敗すると Cloud Monitoring のアラートが発火し、Cloud Console の「インシデント」に出ます（`terraform/monitoring.tf`）。
メールで受け取るには、Terraform の変数 `alert_email` に通知先を指定して apply してください。空のままだとメールは届きません。

実行されなかったバックアップは、監視の `backup-watchdog` が見つけて知らせます。6 時間ごと（UTC 00:17・06:17・12:17・18:17 / JST 09:17・15:17・21:17・03:17）に 4 つの CronJob を見て、一時停止中・CronJob が無い・最後の成功が上限より古い（db-backup・manifest-backup は 26 時間、pvc-backup は 29 時間、restic-maintenance は 8 日。しきい値は `scripts/watchdog.sh` の表）のどれかなら、自分の Job を失敗させます。アラートの Job 名が `backup-watchdog-` で始まるときは、バックアップが取られていない状態です。`kubectl logs` の `NG` の行に、止まっている CronJob と理由が出ます。
**残る限界:** watchdog 自身が動かなくなったとき（CronJob の削除や一時停止、クラスタの停止）は通知されません。
また、このアラートは実際のログではまだ確かめていません。構築後に、わざと失敗する Job で一度届くことを確かめてください。
通知に頼りきらず、ときどき Backrest の画面か、次で確かめてください。

```powershell
kubectl get jobs -n infra
kubectl logs -n infra job/<job 名>
kubectl exec -n infra deploy/backrest -- restic -r rest:http://rest-server.infra.svc.cluster.local:8000/ -p /etc/restic/password snapshots
```

### 4.1 Headlamp から実行・一時停止する

Headlamp（`https://dashboard.wax100.io`）で **Workloads → CronJobs → Namespace `infra`** を開くと、
バックアップの 4 つの CronJob（`db-backup` / `manifest-backup` / `pvc-backup` / `restic-maintenance`）を操作できます。

| 操作       | ボタン        | 内容                                                                                                       |
| :--------- | :------------ | :--------------------------------------------------------------------------------------------------------- |
| 今すぐ取る | **Spawn Job** | CronJob と同じ中身の Job を 1 回動かす。結果は Jobs とそのログで見る                                       |
| 一時停止   | **Suspend**   | 次の定期実行から止める（動いている Job は止まらない）。Git に書いていない項目なので Config Sync は戻さない |
| 再開       | **Resume**    | 定期実行を戻す                                                                                             |

スケジュール・保持期間・対象の変更は Git（このリポジトリ）で行います。Headlamp からは変えられません
（Kyverno の `headlamp-backup-ops` が、CronJob と同じ中身ではない Job の作成と、`spec.suspend` 以外の変更を拒否します）。
**一時停止したままにしないこと。** 止めている間はバックアップが取られません（`backup-watchdog` が次の確認で失敗させて知らせます）。
`backup-watchdog` は Headlamp からは操作できません（Spawn Job も Suspend も拒否されます。`components/infrastructure/backup/base/watchdog.yaml` の説明）。

### 4.2 後片付けの警告

`pvc-backup` のログに `WARN: 消せませんでした` が出たら、一時ディスクかスナップショットが残っています（次の実行の最初に消します。課金はそれまで続きます）。

## 5. 戻し方

数ファイルなら、Backrest でスナップショットを開いてファイルを選び、**Restore**（Pod の `/restore` へ）してダウンロードします。
以下はコマンドで戻す方法です。ダンプは大きいので **Cloud Shell（bash）で実行**してください。

```bash
repo='rest:http://rest-server.infra.svc.cluster.local:8000/'
restic() { kubectl exec -n infra deploy/backrest -- restic -r "${repo}" -p /etc/restic/password "$@"; }
restic snapshots --tag db        # DB ごとの一覧（Paths の列がダンプ名）。manifests / pvc も同じ要領
```

過去の時点に戻すときは、以下の `latest` と `--path` の代わりに、一覧で見たスナップショット ID を指定します。

### 5.1 DB

戻す前にアプリを止めてください（`kubectl scale deploy --all --replicas=0 -n <ns>`。本番は Config Sync が戻すので、
先に `components/apps/<app>` で replicas を 0 にする PR を出す）。dev のダンプを本番に入れることもできます。

`<名前>` はダンプの名前（上の 1 のとおり。Deployment なら Deployment 名、StatefulSet なら Pod 名）、`<pod>` は戻し先で今動いている Pod（`kubectl exec` の先）です。名前は `restic snapshots --tag db` の Paths の列で確かめられます。

```bash
# PostgreSQL（--clean 付きのダンプなので、既存の DB を消してから作り直す）
restic dump --path /work/db/<ns>/<名前>.sql latest /work/db/<ns>/<名前>.sql \
  | kubectl exec -i -n <ns> <pod> -c postgres -- sh -c 'psql -v ON_ERROR_STOP=0 -U "${POSTGRES_USER:-postgres}" -d postgres'

# MySQL
restic dump --path /work/db/<ns>/<名前>.sql latest /work/db/<ns>/<名前>.sql \
  | kubectl exec -i -n <ns> <pod> -c mysql -- sh -c 'MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql -uroot'

# MariaDB
restic dump --path /work/db/<ns>/<名前>.sql latest /work/db/<ns>/<名前>.sql \
  | kubectl exec -i -n <ns> <pod> -c mariadb -- sh -c 'MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD}}" mariadb -uroot'
```

Bitnami のチャートはパスワードをファイルで渡すことが多いので、チャートの Secret から取り出して渡します
（Secret はふつう `<リリース名>-postgresql` などで、キーは下のとおり。コンテナ名はイメージ名と同じ）。

```bash
secret=<Secret 名>

# PostgreSQL（キー postgres-password = スーパーユーザー postgres のパスワード）
pw=$(kubectl get secret -n <ns> "${secret}" -o jsonpath='{.data.postgres-password}' | base64 -d)
restic dump --path /work/db/<ns>/<名前>.sql latest /work/db/<ns>/<名前>.sql \
  | kubectl exec -i -n <ns> <pod> -c postgresql -- env PGPASSWORD="${pw}" psql -v ON_ERROR_STOP=0 -U postgres -d postgres

# MySQL（キー mysql-root-password）/ MariaDB（キー mariadb-root-password。コマンドは mariadb）
pw=$(kubectl get secret -n <ns> "${secret}" -o jsonpath='{.data.mysql-root-password}' | base64 -d)
restic dump --path /work/db/<ns>/<名前>.sql latest /work/db/<ns>/<名前>.sql \
  | kubectl exec -i -n <ns> <pod> -c mysql -- env MYSQL_PWD="${pw}" mysql -uroot
```

- PostgreSQL の `ERROR: current user cannot be dropped` と `role "..." already exists` は `--clean` 付きのダンプで必ず出るもので、無視してかまいません
- **MySQL / MariaDB のダンプはユーザー表（`mysql.user`）も含みます。** 戻した先の root パスワードは、次の再起動（または `FLUSH PRIVILEGES`）で
  **ダンプ元のもの**に変わります。パスワードが違う DB に戻したら（dev のダンプを本番に入れるときなど）、Secret のパスワードをダンプ元に
  合わせるか、戻した直後に `ALTER USER 'root'@'%' IDENTIFIED BY '<Secret の値>'` で戻してください。そのままだとアプリの接続と次回のバックアップが失敗します
- この変更より前に取ったダンプは、`/work/db/<ns>/<Pod 名>.sql` のまま残っています。移し替えはせず、同じ保持の規則で消えていきます。戻すときは `restic snapshots --tag db` の Paths で Pod 名のパスを探し、そのパスを `--path` とファイル名の引数の両方に指定してください（例: `restic dump --path /work/db/<ns>/<Pod 名>.sql latest /work/db/<ns>/<Pod 名>.sql`）。

### 5.2 アプリ定義

```bash
restic dump latest --tag manifests /work/manifests/<ns>.yaml | kubectl apply -f -
```

**Canine の管理下には戻りません**（Canine の DB にはその記録が無い）。応急処置として使い、本復旧は `wax100-db` のリストアで行います。

### 5.3 本番の PVC

ディスクを丸ごと戻すときは、アプリを止めてから、アプリの Namespace で restic の Job を 1 回動かします
（rest-server は、ラベル `wax100.io/restic-restore: "true"` の Pod からの通信を受け付けます。ただし dev の Namespace（`caninemanaged` ラベル付き）と `default`・`dev-access`・`canine`・`canine-k8s-builder`・`canine-system`・`headlamp` からは受け付けません。`components/infrastructure/backup/base/networkpolicy.yaml`）。

```bash
ns=prod-<app>; pvc=<PVC 名>
image=$(kubectl get configmap restic-config -n infra -o jsonpath='{.data.MOVER_IMAGE}')

# 1. アプリを止める（本番は components/apps/<app> で replicas を 0 にする PR を出す）

# 2. 鍵を一時的にアプリの Namespace へコピーする（4 で消す）
kubectl create secret generic restic-restore -n "${ns}" \
  --from-literal=RESTIC_PASSWORD="$(kubectl get secret -n infra restic-client -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d)" \
  --from-literal=RESTIC_REST_PASSWORD="$(kubectl get secret -n infra restic-client -o jsonpath='{.data.RESTIC_REST_PASSWORD}' | base64 -d)"

# 3. 最新のスナップショットを PVC に書き戻す
kubectl apply -n "${ns}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: restic-restore
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: {wax100.io/restic-restore: "true"}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: restic
          image: ${image}
          command: [restic]
          args: [restore, latest, --host, pvc-backup, --path, /pvc/${ns}/${pvc}, --target, /]
          env:
            - {name: RESTIC_REPOSITORY, value: "rest:http://rest-server.infra.svc.cluster.local:8000/"}
            - {name: RESTIC_REST_USERNAME, value: backup}
          envFrom:
            - secretRef: {name: restic-restore}
          volumeMounts:
            - {name: data, mountPath: /pvc/${ns}/${pvc}}
      volumes:
        - {name: data, persistentVolumeClaim: {claimName: ${pvc}}}
EOF
kubectl logs -n "${ns}" job/restic-restore -f

# 4. 後片付けしてアプリを戻す
kubectl delete job restic-restore -n "${ns}"
kubectl delete secret restic-restore -n "${ns}"
```

スナップショットに無いファイルは消されずに残ります。まっさらにしたいときは `args` に `--delete` を足してください。

## 6. 旧方式（gzip を GCS に直接置く方式）からの切り替え

旧方式のバケット `wax100-db-backups` のダンプは、restic のリポジトリへは引き継ぎません（捨てます）。
ただし、新しい方式で DB のバックアップが取れることを確かめるまでは消さず、旧バケットのダンプを残したままにしてください。
旧バケットは Terraform の定義からは消してありますが、state に残っていると apply が消そうとし、中身があるので止まります。
そこで、apply の前に旧バケットを state から外します（バケット自体は残る）。

```powershell
cd terraform
terraform state list | Select-String "db_backups"   # 何も出なければ、次の行は不要
terraform state rm google_storage_bucket.db_backups
terraform apply
```

apply の後、3.1 の手順で restic 側の 1 回目を流してください（`db-backup-manual` のログで成功を確かめる）。
それが確かめられてから、旧バケットを空にして消します。

```powershell
gcloud storage rm -r gs://wax100-db-backups --project=wax100
```

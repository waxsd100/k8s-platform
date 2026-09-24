# =============================================================================
# バックアップ（restic リポジトリ）: DB のダンプ・アプリ定義・本番の PVC のファイル
#
# 流れ（components/infrastructure/backup、手順は docs/BACKUP.md）:
#
#   db-backup / manifest-backup / pvc-backup ──restic──▶ rest-server (--append-only) ──GCS FUSE──▶ gs://wax100-platform/restic/
#   Backrest（UI）             ──restic──▶ rest-server（参照・リストア・check だけ）
#   restic-maintenance         ──GCS FUSE──▶ gs://wax100-platform/restic/（forget / prune。UI なし）
#
# バケットは GKE 共通の 1 つ（storage.tf の google_storage_bucket.main）。restic は
# その中の restic/ をマネージドフォルダにして、権限もこのフォルダにだけ付ける。
#
# 消せる経路を UI も exec 権限も持たない restic-maintenance と rest-server だけに絞る。
# 取る側（DB への exec やスナップショットの権限を持つ）と Backrest（UI を持つ）は rest-server の追記専用の
# 経路しか持たないので、どちらを乗っ取られても既存のスナップショットは消せない。
# それでも消されたときのために、バケットのソフト削除で var.bucket_soft_delete_days 日は戻せる
# （ソフト削除の短縮・無効化には storage.buckets.update が要り、クラスタには渡していない）。
#
# restic のパック（data/）は何日も前のものを参照し続けるので、年齢で消すライフサイクルは
# 付けない。古いスナップショットは restic-maintenance の forget / prune が消す。
# =============================================================================

resource "google_storage_managed_folder" "restic" {
  bucket = google_storage_bucket.main.name
  name   = "restic/"
}

# GCS FUSE で restic/ をマウントする 2 つの ServiceAccount。
# 読み書きと削除が要る（rest-server はロックファイルを消す。restic-maintenance は prune する）。
# マネージドフォルダに付けるので、同じバケットの restic/ 以外には届かない。
# Workload Identity Federation for GKE の直接プリンシパル（secrets.tf の ESO と同じ方式）。
resource "google_storage_managed_folder_iam_member" "restic_object_user" {
  for_each = toset(["restic-rest-server", "restic-maintenance"])

  bucket         = google_storage_managed_folder.restic.bucket
  managed_folder = google_storage_managed_folder.restic.name
  role           = "roles/storage.objectUser"
  member = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.project.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/infra/sa/${each.key}",
  ])
}

# --- restic の鍵と rest-server の認証（Terraform が生成して Secret Manager に置く） ---

# リポジトリの暗号鍵。失うとバックアップは二度と読めない。
# Terraform の state を失っても作り直されないよう、destroy を拒否する。
# 念のため、構築後に Secret Manager から取り出してオフラインにも保管すること。
resource "random_password" "restic_repository" {
  length  = 48
  special = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret" "restic_repository_password" {
  secret_id = "restic-repository-password"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_secret_manager_secret_version" "restic_repository_password" {
  secret      = google_secret_manager_secret.restic_repository_password.id
  secret_data = random_password.restic_repository.result
}

# rest-server の Basic 認証（ユーザー名 backup）。htpasswd は ESO がこの値から作る。
resource "random_password" "restic_rest_server" {
  length  = 32
  special = false

  depends_on = [google_project_service.enabled_apis]
}

resource "google_secret_manager_secret" "restic_rest_server_password" {
  secret_id = "restic-rest-server-password"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_secret_manager_secret_version" "restic_rest_server_password" {
  secret      = google_secret_manager_secret.restic_rest_server_password.id
  secret_data = random_password.restic_rest_server.result
}

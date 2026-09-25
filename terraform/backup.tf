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

# GCS FUSE で restic/ をマウントする 2 つの ServiceAccount
# （Workload Identity Federation for GKE の直接プリンシパル。secrets.tf の ESO と同じ方式）。
locals {
  restic_gcsfuse_members = {
    for ksa in ["restic-rest-server", "restic-maintenance"] : ksa => join("", [
      "principal://iam.googleapis.com/projects/${data.google_project.project.number}",
      "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
      "/subject/ns/infra/sa/${ksa}",
    ])
  }
}

# 読み書きと削除が要る（rest-server はロックファイルを消す。restic-maintenance は prune する）。
# マネージドフォルダに付けるので、同じバケットの restic/ 以外のオブジェクトには届かない。
resource "google_storage_managed_folder_iam_member" "restic_object_user" {
  for_each = local.restic_gcsfuse_members

  bucket         = google_storage_managed_folder.restic.bucket
  managed_folder = google_storage_managed_folder.restic.name
  role           = "roles/storage.objectUser"
  member         = each.value
}

# バケット全体には「一覧」だけを付ける。GCS FUSE のサイドカーがマウント前に接頭辞なしで
# バケットへのアクセスを確かめる（GetStorageLayout = バケットの storage.objects.list）ため。
# GKE 1.34.1-gke.3899001 以降は自動で有効になり、GKE のドライバ（v1.22）では
# skipCSIBucketAccessCheck でもマウントオプションでも止められない。
# 見えるのはオブジェクト名とメタデータだけで、中身は読めない・書けない・消せない。
resource "google_project_iam_custom_role" "gcs_object_lister" {
  role_id     = "gcsObjectLister"
  title       = "GCS object lister"
  description = "storage.objects.list only (GCS FUSE sidecar bucket access check)"
  permissions = ["storage.objects.list"]
}

resource "google_storage_bucket_iam_member" "restic_object_lister" {
  for_each = local.restic_gcsfuse_members

  bucket = google_storage_bucket.main.name
  role   = google_project_iam_custom_role.gcs_object_lister.id
  member = each.value
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

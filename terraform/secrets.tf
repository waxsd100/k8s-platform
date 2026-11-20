# =============================================================================
# Secret Manager の「器」と、ESO の読み取り権限
# =============================================================================
#
# 中身の出どころ:
#   cloudflare-api-token          手動（Terraform 自身が読むため鶏と卵）
#   cloudflared-tunnel-token      Terraform が書く (cloudflare-tunnel.tf)
#   vela-promote-github-token     手動（Fine-grained PAT）
#   restic-repository-password / restic-rest-server-password  Terraform が生成 (backup.tf)
#
# 保存場所は var.region (asia-northeast1) だけに固定する（user_managed）。
# auto にすると Google が複数のリージョンへ複製し、保存場所を選べない。

resource "google_secret_manager_secret" "cloudflare_api_token" {
  secret_id = "cloudflare-api-token"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

# NOTE: cloudflare-zone-id の Secret はここにあったが削除した。
#       Terraform はこの値を Secret Manager からは読まず、変数
#       var.cloudflare_zone_id だけを入力にしている。Secret に入れても
#       どこからも参照されず、「手順書どおりに入れたのに Cloudflare の
#       リソースが 1 つも作られない」という無言の失敗を招いていた。
#       Zone ID は機密ではないので変数で渡す。

# cloudflared (Cloudflare Tunnel) のトークン
# cloudflare_manage_tunnel = true（既定）なら cloudflare-tunnel.tf が
# トンネルを作り、この Secret に版を自動で追加する。手でコピーする必要はない。
resource "google_secret_manager_secret" "cloudflared_tunnel_token" {
  secret_id = "cloudflared-tunnel-token"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

# 昇格 PR を立てるための GitHub トークン
# 値は Fine-grained PAT（k8s-platform の Contents / Pull requests: Read and write）を
# 手動で登録する
resource "google_secret_manager_secret" "vela_promote_github_token" {
  secret_id = "vela-promote-github-token"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled_apis]
}

# =============================================================================
# ESO (External Secrets Operator) の読み取り権限
# =============================================================================

locals {
  # Workload Identity Federation for GKE の直接プリンシパル（ESO）
  eso_principal = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.project.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/external-secrets/sa/external-secrets",
  ])

  # ESO が読んでよい基盤の Secret。ExternalSecret（components/infrastructure/*/base/external-secret.yaml）が
  # remoteRef.key で参照するものと一致させる。基盤の新しい Secret を ExternalSecret で使うときは、ここに足す。
  # cloudflare-api-token は入れない（Terraform 専用。入れないことで ESO からは読めない）。
  #
  # NOTE: 静的キーの map で各 Secret リソースの secret_id を参照することで、
  #       新規構築時の作成順序を保証しつつ for_each キーを plan 時に確定させる。
  eso_platform_secrets = {
    "cloudflared-tunnel-token"    = google_secret_manager_secret.cloudflared_tunnel_token.secret_id
    "vela-promote-github-token"   = google_secret_manager_secret.vela_promote_github_token.secret_id
    "restic-repository-password"  = google_secret_manager_secret.restic_repository_password.secret_id
    "restic-rest-server-password" = google_secret_manager_secret.restic_rest_server_password.secret_id
  }
}

# ESO に付ける基盤 Secret ごとの読み取り権限（Secret 単位のリソース IAM）。
# 以前はプロジェクト IAM の condition に || で並べていたが、IAM 条件の論理演算子上限（12 個）に
# 近づくのを避け、基盤 Secret は個別の Secret IAM バインディングとして付与する。
#
# Workload Identity Federation for GKE の「直接プリンシパル」方式で、
# Kubernetes ServiceAccount に直接ロールを付ける。GSA の作成も
# iam.gke.io/gcp-service-account アノテーションも不要。
#
# NOTE: かつて member を
#         serviceAccount:<project>.svc.id.goog[external-secrets/external-secrets]
#       と書いていたが、この形式は **GSA のポリシーに
#       roles/iam.workloadIdentityUser を付けるとき専用**で、
#       プロジェクト・リソースレベルのバインディングでは無効。この誤りがあると
#       ESO は Secret Manager を読めず、すべての ExternalSecret が
#       PERMISSION_DENIED になり、cloudflared やバックアップ・昇格 Job が起動しない。
#       出典: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
resource "google_secret_manager_secret_iam_member" "eso_platform_secret_accessor" {
  for_each = local.eso_platform_secrets

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = local.eso_principal
}

# 昇格した本番アプリの Secret（名前は prod-<app>_<名前>、手動作成）だけを
# プロジェクトレベルの IAM 条件で ESO に許可する（論理演算子 0 個なので上限を気にせず拡張できる）。
# cloudflare-api-token は prod- で始まらず個別付与も無いため読めない。このトークンは Terraform が
# Cloudflare を操作するためだけのもので、クラスタ内では使わない。ESO が読めると、ExternalSecret を
# 書ける者や侵害されたワークロードが DNS / Tunnel / Access の編集権限を取り出し、
# 管理 UI（VelaUX / Headlamp / Backrest）の Access 保護を外せてしまう。
#
# NOTE: 以前は「手動で作った TLS 証明書系の Secret にも読ませる」ため、拒否リスト（cloudflare-api-token だけ除外）
#       にしていた。その TLS 証明書の Secret 名はリポジトリにもドキュメントにも無いので、許可リストには入れていない。
#       読ませる必要が出たら、名前を決めて local.eso_platform_secrets に足す。
resource "google_project_iam_member" "eso_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = local.eso_principal

  # resource.name はプロジェクト番号で表記する（ID では一致しない）。
  condition {
    title       = "eso-prod-prefix-secrets"
    description = "ESO may read only prod- application secrets at project level"
    expression  = "resource.name.startsWith(\"projects/${data.google_project.project.number}/secrets/prod-\")"
  }

  depends_on = [google_project_service.enabled_apis]
}

# Secret Manager の読み取り（DATA_READ）を監査ログに残す。Secret の読み取りは数が少ないので、全件記録しても量は小さい。
# ほかのサービスの監査ログ設定は変えていない。
resource "google_project_iam_audit_config" "secretmanager_data_read" {
  project = var.project_id
  service = "secretmanager.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }

  depends_on = [google_project_service.enabled_apis]
}

# Cloud Storage の読み取り（DATA_READ）を監査ログに残す。
# Terraform state バケット（wax100-tfstate、平文の秘密を含む）への読み取りや、
# 想定外のプリンシパルによるバックアップバケット読み取りを検知できるようにする。
resource "google_project_iam_audit_config" "storage_data_read" {
  project = var.project_id
  service = "storage.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }

  depends_on = [google_project_service.enabled_apis]
}

# restic-rest-server / restic-maintenance は Workload Identity Federation の直接プリンシパル
# （principal://...）で GCS FUSE 経由の読み取りを行う。IAM の audit_log_config.exempted_members は
# user: / serviceAccount: / group: 等の Google ID 向けであり federated principal:// は
# 適用時エラー（INVALID_ARGUMENT）になりうるため、Cloud Logging の除外フィルタで
# restic 用バケットへの定常読み取りだけを取り込みから除外する。
# これにより wax100-tfstate への読み取りや、restic 以外のプリンシパルによる読み取りはすべて残る。
resource "google_logging_project_exclusion" "exclude_restic_gcs_data_read" {
  name        = "exclude-restic-gcs-data-read"
  project     = var.project_id
  description = "storage.googleapis.com の DATA_READ 監査ログのうち、restic の GCS FUSE 定常読み取りだけを除外する（wax100-tfstate 等の監査は維持）"

  filter = <<-EOT
    logName="projects/${var.project_id}/logs/cloudaudit.googleapis.com%2Fdata_access"
    protoPayload.serviceName="storage.googleapis.com"
    resource.type="gcs_bucket"
    resource.labels.bucket_name="${google_storage_bucket.main.name}"
    (
      protoPayload.authenticationInfo.principalSubject="principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/infra/sa/restic-rest-server"
      OR protoPayload.authenticationInfo.principalSubject="principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/infra/sa/restic-maintenance"
    )
  EOT

  depends_on = [google_project_service.enabled_apis]
}

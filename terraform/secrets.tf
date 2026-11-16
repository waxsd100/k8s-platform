# =============================================================================
# Secret Manager の「器」と、ESO の読み取り権限
# =============================================================================
#
# 中身の出どころ:
#   cloudflare-api-token          手動（Terraform 自身が読むため鶏と卵）
#   cloudflared-tunnel-token      Terraform が書く (cloudflare-tunnel.tf)
#   canine-*-github-token         手動（Fine-grained PAT）
#   canine-db-password / canine-secret-key-base  Terraform が生成 (canine.tf)
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
resource "google_secret_manager_secret" "canine_promote_github_token" {
  secret_id = "canine-promote-github-token"
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
  # ESO が読んでよい基盤の Secret の ID。ExternalSecret（components/infrastructure/*/base/external-secret.yaml）が
  # remoteRef.key で参照するものと一致させる。基盤の新しい Secret を ExternalSecret で使うときは、ここに足す。
  # cloudflare-api-token は入れない（Terraform 専用。入れないことで ESO からは読めない）。
  eso_platform_secret_ids = [
    "canine-db-password",
    "canine-secret-key-base",
    "cloudflared-tunnel-token",
    "canine-promote-github-token",
    "restic-repository-password",
    "restic-rest-server-password",
  ]
}

# ESO に付ける Secret Manager の読み取り権限。プロジェクト全体に付けたうえで、IAM 条件で
# 読める Secret を許可リストに絞っている。読めるのは次の 2 種類だけ。
#   - local.eso_platform_secret_ids の基盤 Secret
#   - ID が prod- で始まる Secret（昇格した本番アプリの秘密。手で作る。名前は prod-<app>_<名前>）
# 一覧にない Secret（cloudflare-api-token を含む）は読めない。
#
# NOTE: 以前は「手動で作った TLS 証明書系の Secret にも読ませる」ため、拒否リスト（cloudflare-api-token だけ除外）
#       にしていた。その TLS 証明書の Secret 名はリポジトリにもドキュメントにも無いので、許可リストには入れていない。
#       読ませる必要が出たら、名前を決めて local.eso_platform_secret_ids に足す。
#
# Workload Identity Federation for GKE の「直接プリンシパル」方式で、
# Kubernetes ServiceAccount に直接ロールを付ける。GSA の作成も
# iam.gke.io/gcp-service-account アノテーションも不要。
#
# NOTE: かつて member を
#         serviceAccount:<project>.svc.id.goog[external-secrets/external-secrets]
#       と書いていたが、この形式は **GSA のポリシーに
#       roles/iam.workloadIdentityUser を付けるとき専用**で、
#       プロジェクトレベルのバインディングでは無効。この誤りがあると
#       ESO は Secret Manager を読めず、すべての ExternalSecret が
#       PERMISSION_DENIED になり、Canine も cloudflared も起動しない。
#       出典: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
resource "google_project_iam_member" "eso_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.project.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/external-secrets/sa/external-secrets",
  ])

  # 読めるのは一覧にある基盤 Secret と prod- の本番 Secret だけ（許可リスト）。
  # cloudflare-api-token は一覧に無いので読めない。このトークンは Terraform が Cloudflare を操作するためだけのもので、
  # クラスタ内では使わない。ESO が読めると、ExternalSecret を書ける者（= Canine の UI を持つ者）が
  # DNS / Tunnel / Access の編集権限を取り出し、Canine UI の Access 保護を外せてしまう。
  # resource.name はプロジェクト番号で表記する（ID では一致しない）。
  # 基盤の Secret は .../versions/ まで付けて照合する。末尾の /versions/ は、ID が長い別の ID の
  # 接頭辞になっているものを誤って通さないため（例: canine-db-password と canine-db-password-old）。
  condition {
    title       = "eso-allowlisted-secrets"
    description = "ESO may read only the listed platform secrets and prod- application secrets"
    expression = join(" || ", concat(
      [for id in local.eso_platform_secret_ids : "resource.name.startsWith(\"projects/${data.google_project.project.number}/secrets/${id}/versions/\")"],
      ["resource.name.startsWith(\"projects/${data.google_project.project.number}/secrets/prod-\")"],
    ))
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

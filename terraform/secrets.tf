# =============================================================================
# Secret Manager の「器」と、ESO の読み取り権限
# =============================================================================
#
# 中身の出どころ:
#   cloudflare-api-token          手動（Terraform 自身が読むため鶏と卵）
#   cloudflared-tunnel-token      Terraform が書く (cloudflare-tunnel.tf)
#   canine-*-github-token         手動（Fine-grained PAT）
#   canine-db-password / canine-secret-key-base  Terraform が生成 (canine.tf)
#   restic-repository-password / restic-rest-server-password  Terraform が生成 (db-backup.tf)
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

# プロジェクト全体のシークレット読み取り権限（cloudflare-api-token を除く）
# (※gcloud等で手動作成したTLS証明書系のシークレットにもアクセスさせるため個別からプロジェクトレベルへ変更)
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

  # cloudflare-api-token だけは読ませない。
  # このトークンは Terraform が Cloudflare を操作するためのもので、クラスタ内では使わない。
  # ESO が読めると、ExternalSecret を書ける者（= Canine の UI を持つ者）が
  # DNS / Tunnel / Access の編集権限を取り出し、Canine UI の Access 保護を外せてしまう。
  # resource.name はプロジェクト番号で表記する（ID では一致しない）。
  condition {
    title       = "not-terraform-only-secrets"
    description = "ESO must not read the Cloudflare API token used only by Terraform"
    expression = join(" && ", [
      "resource.name != \"projects/${data.google_project.project.number}/secrets/cloudflare-api-token\"",
      "!resource.name.startsWith(\"projects/${data.google_project.project.number}/secrets/cloudflare-api-token/\")",
    ])
  }

  depends_on = [google_project_service.enabled_apis]
}

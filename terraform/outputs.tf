output "cluster_name" {
  description = "The name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "db_connection_name" {
  description = "Connection name of the shared Cloud SQL instance (for Cloud SQL Auth Proxy)"
  value       = google_sql_database_instance.main.connection_name
}

output "bucket" {
  description = "The single GCS bucket used by workloads in the cluster (restic repository under restic/)"
  value       = google_storage_bucket.main.name
}

output "readonly_viewer_email" {
  description = "閲覧専用 SA（Claude Code のクラウド環境から使う。鍵の作り方は docs/GKE_SETUP_GUIDE.md の 8.11）"
  value       = var.readonly_viewer_enabled ? google_service_account.readonly_viewer[0].email : null
}

output "cluster_name" {
  description = "The name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "db_connection_name" {
  description = "Connection name of the shared Cloud SQL instance (for Cloud SQL Auth Proxy)"
  value       = google_sql_database_instance.main.connection_name
}

output "db_backup_bucket" {
  description = "GCS bucket holding daily dumps of in-cluster databases"
  value       = google_storage_bucket.db_backups.name
}

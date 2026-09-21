output "cluster_name" {
  description = "The name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "db_connection_name" {
  description = "Connection name of the shared Cloud SQL instance (for Cloud SQL Auth Proxy)"
  value       = google_sql_database_instance.main.connection_name
}

output "mysql_connection_name" {
  description = "Connection name of the Cloud SQL for MySQL instance (null when mysql_app_databases is empty)"
  value       = one(google_sql_database_instance.mysql[*].connection_name)
}

output "cluster_name" {
  description = "The name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "canine_cloudsql_connection_name" {
  description = "The connection name for the Canine Cloud SQL instance"
  value       = google_sql_database_instance.canine_db.connection_name
}

output "cluster_name" {
  description = "The name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "prod_static_ip" {
  description = "The Global Static IP for Production Ingress / Cloudflare"
  value       = google_compute_global_address.prod_static_ip.address
}

output "edge_gateway_ip" {
  description = "The Ephemeral External IP of the Edge Gateway VM (Staging / Dev)"
  value       = google_compute_instance.edge_gateway.network_interface[0].access_config[0].nat_ip
}

output "cloudsql_connection_name" {
  description = "The connection name for the Cloud SQL instance"
  value       = google_sql_database_instance.blog_db.connection_name
}

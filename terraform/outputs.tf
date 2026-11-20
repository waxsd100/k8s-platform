output "cluster_name" {
  description = "The name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "velaux_url" {
  description = "Public URL of the VelaUX control plane UI (null while Cloudflare Tunnel is disabled)"
  value       = local.cloudflare_tunnel_enabled ? "https://${var.velaux_hostname}" : null
}

output "bucket" {
  description = "The single GCS bucket used by workloads in the cluster (dedicated restic repository at bucket root)"
  value       = google_storage_bucket.main.name
}

output "readonly_viewer_email" {
  description = "閲覧専用 SA（Claude Code のクラウド環境から使う。鍵の作り方は docs/GKE_SETUP_GUIDE.md の 8.11）"
  value       = var.readonly_viewer_enabled ? google_service_account.readonly_viewer[0].email : null
}

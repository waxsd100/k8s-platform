# スクリプトの存在するディレクトリに移動
Set-Location -Path $PSScriptRoot

$imports = @(
    "google_compute_network.vpc_network projects/wax100/global/networks/wax100-vpc",
    "google_compute_subnetwork.subnet_main projects/wax100/regions/asia-northeast1/subnetworks/wax100-subnet",
    "google_compute_subnetwork.subnet_lb projects/wax100/regions/asia-northeast1/subnetworks/wax100-subnet-lb",
    "google_compute_router.router projects/wax100/regions/asia-northeast1/routers/wax100-router",
    "google_compute_router_nat.nat projects/wax100/regions/asia-northeast1/routers/wax100-router/nats/wax100-nat",
    "google_compute_global_address.prod_static_ip projects/wax100/global/addresses/prod-wax100-blog-ip",
    "google_compute_route.nat_route projects/wax100/global/routes/nat-route",
    "google_compute_instance.edge_gateway projects/wax100/zones/asia-northeast1-a/instances/edge-gateway",
    "google_container_cluster.primary projects/wax100/locations/asia-northeast1-a/clusters/wax100-platform",
    "google_container_node_pool.system_pool projects/wax100/locations/asia-northeast1-a/clusters/wax100-platform/nodePools/system-pool",
    "google_container_node_pool.dev_pool projects/wax100/locations/asia-northeast1-a/clusters/wax100-platform/nodePools/dev-pool",
    "google_container_node_pool.stag_pool projects/wax100/locations/asia-northeast1-a/clusters/wax100-platform/nodePools/stag-pool",
    "google_container_node_pool.prod_pool projects/wax100/locations/asia-northeast1-a/clusters/wax100-platform/nodePools/prod-pool",
    "google_artifact_registry_repository.config_sync_repo projects/wax100/locations/asia-northeast1/repositories/config-sync-repo",
    "google_secret_manager_secret.cloudflare_api_token projects/wax100/secrets/cloudflare-api-token",
    "google_secret_manager_secret.cloudflare_zone_id projects/wax100/secrets/cloudflare-zone-id",
    "google_secret_manager_secret.dashboard_csrf_key projects/wax100/secrets/dashboard-csrf-key",
    "google_gke_hub_membership.membership projects/wax100/locations/asia-northeast1/memberships/wax100-platform",
    "google_gke_hub_feature.configmanagement projects/wax100/locations/global/features/configmanagement",
    "google_compute_firewall.vpc_allow_http projects/wax100/global/firewalls/wax100-vpc-allow-http",
    "google_compute_firewall.vpc_allow_https projects/wax100/global/firewalls/wax100-vpc-allow-https",
    "google_compute_firewall.vpc_allow_health_checks projects/wax100/global/firewalls/wax100-vpc-allow-health-check",
    "google_compute_firewall.vpc_allow_ssh projects/wax100/global/firewalls/wax100-allow-ssh",
    "google_cloudbuild_trigger.manifest_sync projects/wax100/locations/asia-northeast1/triggers/fc1ab040-d11e-4d6d-ab7e-abf9ad584fe6",
    "google_cloudbuild_trigger.wax100_blog_sync projects/wax100/locations/asia-northeast1/triggers/e4ad819f-45db-479c-beab-d28d4966dbb1",
    "google_cloudbuild_trigger.wax100_blog_release_ci projects/wax100/locations/asia-northeast1/triggers/2998d5c0-4768-464a-a797-7fce82d7ef19",
    "google_compute_global_address.private_ip_range projects/wax100/global/addresses/cloudsql-private-ip",
    "google_service_networking_connection.private_vpc_connection projects/wax100/global/networks/wax100-vpc:servicenetworking.googleapis.com",
    "google_sql_database_instance.blog_db projects/wax100/instances/wax100-db",
    "google_sql_database.ghost projects/wax100/instances/wax100-db/databases/ghost",
    "google_sql_user.ghost wax100/wax100-db/ghost"
)

# setup Env for terraform installed via winget
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

Write-Host "Checking current terraform state..."
$existingResources = terraform state list

foreach ($import in $imports) {
    $parts = $import -split ' '
    $resourceName = $parts[0]
    $resourceId = $parts[1]

    if ($existingResources -contains $resourceName) {
        Write-Host "Skipping $resourceName (already managed)" -ForegroundColor DarkGray
    } else {
        Write-Host "Importing $resourceName" -ForegroundColor Cyan
        terraform import $resourceName $resourceId
    }
}

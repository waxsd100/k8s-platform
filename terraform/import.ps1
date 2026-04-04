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
    "google_container_node_pool.app_pool projects/wax100/locations/asia-northeast1-a/clusters/wax100-platform/nodePools/app-pool",
    "google_container_node_pool.prod_pool projects/wax100/locations/asia-northeast1-a/clusters/wax100-platform/nodePools/prod-pool",
    "google_artifact_registry_repository.config_sync_repo projects/wax100/locations/asia-northeast1/repositories/config-sync-repo",
    "google_secret_manager_secret.cloudflare_api_token projects/wax100/secrets/cloudflare-api-token",
    "google_gke_hub_membership.membership projects/wax100/locations/asia-northeast1/memberships/wax100-platform",
    "google_gke_hub_feature.configmanagement projects/wax100/locations/global/features/configmanagement",
    "google_compute_firewall.vpc_allow_http projects/wax100/global/firewalls/wax100-vpc-allow-http",
    "google_compute_firewall.vpc_allow_https projects/wax100/global/firewalls/wax100-vpc-allow-https",
    "google_compute_firewall.vpc_allow_health_checks projects/wax100/global/firewalls/wax100-vpc-allow-health-check",
    "google_compute_firewall.vpc_allow_ssh projects/wax100/global/firewalls/wax100-allow-ssh"
)

# setup Env for terraform installed via winget
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

foreach ($import in $imports) {
    Write-Host "Importing $import"
    $parts = $import -split ' '
    terraform import $parts[0] $parts[1]
}

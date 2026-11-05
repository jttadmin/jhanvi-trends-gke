output "env" {
  value = local.env
}

output "project_id" {
  value = local.project_id
}

output "cluster_name" {
  value = module.platform.cluster_name
}

output "get_credentials" {
  value = module.platform.get_credentials
}

output "kubectl_context_rename" {
  description = "Give this cluster a short kubectl context name"
  value       = "kubectl config rename-context gke_${local.project_id}_${module.platform.zone}_${module.platform.cluster_name} gke-${local.env}"
}

output "ingress_ip" {
  value = module.platform.ingress_ip
}

output "dns_records" {
  value = module.platform.dns_records
}

output "grafana_url" {
  value = module.platform.grafana_url
}

output "grafana_admin_password" {
  value     = module.platform.grafana_admin_password
  sensitive = true
}

output "prometheus_url" {
  value = module.platform.prometheus_url
}

output "prometheus_basic_auth_password" {
  value     = module.platform.prometheus_basic_auth_password
  sensitive = true
}

output "argocd_admin_password_cmd" {
  value = module.platform.argocd_admin_password_cmd
}

output "otel_endpoint_for_apps" {
  value = module.platform.otel_endpoint_for_apps
}

output "observability_buckets" {
  value = module.platform.observability_buckets
}

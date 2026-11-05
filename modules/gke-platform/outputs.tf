output "cluster_name" {
  value = google_container_cluster.this.name
}

output "get_credentials" {
  description = "Run this to point kubectl at the new cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${var.zone} --project ${var.project_id}"
}

output "ingress_ip" {
  description = "Create GoDaddy A records for shop / argocd pointing here (one time)"
  value       = google_compute_address.ingress.address
}

output "dns_records" {
  value = {
    (var.store_host)      = google_compute_address.ingress.address
    (var.argocd_host)     = google_compute_address.ingress.address
    (var.grafana_host)    = google_compute_address.ingress.address
    (var.prometheus_host) = google_compute_address.ingress.address
  }
}

output "argocd_admin_password_cmd" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "grafana_url" {
  value = "https://${var.grafana_host}"
}

output "grafana_admin_password" {
  description = "terraform output -raw grafana_admin_password"
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "otel_endpoint_for_apps" {
  description = "Set OTEL_EXPORTER_OTLP_ENDPOINT to this in every service"
  value = {
    grpc = "http://${local.otel_gw_svc}:4317"
    http = "http://${local.otel_gw_svc}:4318"
  }
}

output "observability_buckets" {
  value = {
    loki  = google_storage_bucket.loki.name
    tempo = google_storage_bucket.tempo.name
  }
}

output "prometheus_url" {
  value = "https://${var.prometheus_host}  (user: admin)"
}

output "prometheus_basic_auth_password" {
  description = "terraform output -raw prometheus_basic_auth_password"
  value       = random_password.prometheus_basic_auth.result
  sensitive   = true
}

# ---------- Used by the env roots to configure the kubernetes/helm providers ----------
output "cluster_endpoint" {
  value = google_container_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  value = google_container_cluster.this.master_auth[0].cluster_ca_certificate
}

output "zone" {
  value = var.zone
}

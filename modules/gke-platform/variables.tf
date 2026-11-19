# ---------- Project / location ----------
variable "project_id" {
  description = "GCP project ID for this environment"
  type        = string
}

variable "region" {
  description = "GCP region (asia-south1 = Mumbai, closest to Bengaluru)"
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = "Zone for the zonal GKE cluster (zonal keeps the control-plane fee inside the GKE free tier)"
  type        = string
  default     = "asia-south1-a"
}

variable "cluster_name" {
  type    = string
  default = "jhanvi-trends-gke"
}

variable "deletion_protection" {
  description = "Set true once the cluster is serving real traffic"
  type        = bool
  default     = false
}

# ---------- Network ----------
variable "subnet_cidr" {
  type    = string
  default = "10.10.0.0/20"
}

variable "pods_cidr" {
  type    = string
  default = "10.20.0.0/14"
}

variable "services_cidr" {
  type    = string
  default = "10.24.0.0/20"
}

variable "master_cidr" {
  description = "/28 reserved for the GKE control plane (private nodes)"
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_cidrs" {
  description = "Who can reach the Kubernetes API (your home/office IP, CI runners). Empty list = open to all."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

# ---------- Node pools ----------
variable "stateful_machine_type" {
  description = "On-demand nodes for Postgres, MongoDB, Redis, Kafka, LGTM"
  type        = string
  default     = "e2-standard-4"
}

variable "stateful_min_nodes" {
  type    = number
  default = 1
}

variable "stateful_max_nodes" {
  description = "Postgres, MongoDB, Redis, Kafka + the observability stack share this pool"
  type        = number
  default     = 3
}

variable "apps_machine_type" {
  description = "Spot nodes for the stateless microservices"
  type        = string
  default     = "e2-standard-4"
}

variable "apps_min_nodes" {
  type    = number
  default = 1
}

variable "apps_max_nodes" {
  type    = number
  default = 4
}

variable "node_disk_type" {
  description = "Boot disk type for GKE nodes. pd-standard counts against DISKS_TOTAL_GB (2048) instead of the small SSD_TOTAL_GB quota; PVCs still use pd-balanced (standard-rwo)."
  type        = string
  default     = "pd-standard"
}

variable "node_disk_size_gb" {
  type    = number
  default = 50
}

variable "apps_use_spot" {
  description = "Spot VMs are ~60-90% cheaper but can be preempted; fine for stateless services"
  type        = bool
  default     = true
}

# ---------- Ingress / DNS ----------
variable "store_host" {
  type    = string
  default = "shop.bhumaji.com"
}

variable "argocd_host" {
  type    = string
  default = "argocd.bhumaji.com"
}

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt expiry notices"
  type        = string
}

# ---------- Argo CD / GitOps ----------
variable "gitops_repo_url" {
  type    = string
  default = "https://github.com/jttadmin/jhanvi-trends-gke.git"
}

variable "gitops_repo_username" {
  type    = string
  default = "jttadmin"
}

variable "gitops_repo_token" {
  description = "GitHub fine-grained PAT with read access to the repo (private repo)"
  type        = string
  sensitive   = true
}

variable "gitops_target_revision" {
  type    = string
  default = "main"
}

variable "gitops_apps_path" {
  description = "Folder in the repo that holds your Argo CD Application manifests (app-of-apps)"
  type        = string
  default     = "argocd/envs/dev"
}

variable "argocd_github_dispatch_token" {
  description = <<-EOT
    GitHub fine-grained PAT with Contents: read and write on the GitOps repo. Argo CD uses it to send a
    repository_dispatch "argocd-deployed" event when an app is synced, healthy and smoke-tested, which
    starts the promotion to the next environment (.github/workflows/promote.yaml).
    null = no notifications; promote by hand from the Actions tab.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

# ---------- Chart versions (null = latest; pin them once things work) ----------
variable "traefik_chart_version" {
  type    = string
  default = null
}

variable "cert_manager_chart_version" {
  type    = string
  default = null
}

variable "argocd_chart_version" {
  type    = string
  default = null
}

# ---------- Observability ----------
variable "grafana_host" {
  type    = string
  default = "grafana.bhumaji.com"
}

variable "app_namespaces" {
  description = "Namespaces of the Jhanvi Trends services (used by alert rules)"
  type        = list(string)
  default     = ["jhanvi-trends"]
}

variable "metrics_retention_days" {
  type    = number
  default = 15
}

variable "prometheus_disk_gb" {
  type    = number
  default = 50
}

variable "logs_retention_days" {
  type    = number
  default = 7
}

variable "traces_retention_days" {
  type    = number
  default = 7
}

variable "alert_slack_webhook_url" {
  description = "Slack incoming-webhook URL for Alertmanager. Leave null to keep alerts in Grafana/Alertmanager UI only."
  type        = string
  default     = null
  sensitive   = true
}

variable "alert_slack_channel" {
  type    = string
  default = "#jhanvi-alerts"
}

variable "kube_prometheus_stack_chart_version" {
  type    = string
  default = null
}

variable "loki_chart_version" {
  type    = string
  default = null
}

variable "tempo_chart_version" {
  type    = string
  default = null
}

variable "otel_collector_chart_version" {
  type    = string
  default = null
}

variable "stateful_use_spot" {
  description = "Practice/dev: run databases and LGTM on Spot too (PDs survive preemption, pods just restart)"
  type        = bool
  default     = false
}

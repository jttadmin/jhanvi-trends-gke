# prod: real production (later). Create the project first: scripts/bootstrap-project.sh
# Before applying, move dev to dev.bhumaji.com so the hostnames are free.

locals {
  env        = "prod"
  project_id = "jhanvi-trends-prd-2611"
  region     = "asia-south1"
  domain     = "bhumaji.com"
}

module "platform" {
  source = "../../modules/gke-platform"

  project_id = local.project_id
  region     = local.region
  zone       = "${local.region}-a"

  # ---- hostnames (GoDaddy A records -> ingress_ip output) ----
  store_host      = "shop.${local.domain}"
  argocd_host     = "argocd.${local.domain}"
  grafana_host    = "grafana.${local.domain}"
  prometheus_host = "prom.${local.domain}"

  letsencrypt_email = "srinivas.bdn@gmail.com"

  # ---- GitOps: which folder of jttadmin/jhanvi-trends-gke this cluster's Argo CD syncs ----
  gitops_apps_path       = "argocd/envs/prod"
  gitops_target_revision = "main"
  gitops_repo_token      = var.gitops_repo_token

  # ---- production sizing: on-demand data tier, can't be deleted by accident ----
  deletion_protection = true
  stateful_use_spot   = false # databases + LGTM on regular VMs
  stateful_min_nodes  = 1
  stateful_max_nodes  = 3
  apps_machine_type   = "e2-standard-4"
  apps_use_spot       = true # stateless services stay on Spot
  apps_min_nodes      = 1
  apps_max_nodes      = 4

  # ---- observability ----
  prometheus_disk_gb      = 50
  metrics_retention_days  = 15
  logs_retention_days     = 14
  traces_retention_days   = 7
  alert_slack_webhook_url = var.alert_slack_webhook_url
  alert_slack_channel     = "#jhanvi-alerts-prod"
}

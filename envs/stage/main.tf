# stage: pre-release copy of prod, practice-sized. Create the project first: scripts/bootstrap-project.sh

locals {
  env        = "stage"
  project_id = "jhanvi-trends-stage-2611"
  region     = "asia-south1"
  domain     = "stage.bhumaji.com"
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

  # ---- GitOps: which folder of jttadmin/Jhanvi-Trends this cluster's Argo CD syncs ----
  gitops_apps_path       = "argocd/envs/stage"
  gitops_target_revision = "main"
  gitops_repo_token      = var.gitops_repo_token

  # ---- practice sizing: everything on Spot, scales to zero ----
  stateful_use_spot  = true
  stateful_min_nodes = 0
  stateful_max_nodes = 2
  apps_machine_type  = "e2-standard-2"
  apps_min_nodes     = 0
  apps_max_nodes     = 2

  # ---- observability ----
  prometheus_disk_gb      = 20
  metrics_retention_days  = 3
  logs_retention_days     = 3
  traces_retention_days   = 3
  alert_slack_webhook_url = var.alert_slack_webhook_url
  alert_slack_channel     = "#jhanvi-alerts-stage"
}

# Secrets only. Set them in your shell / CI, never in a file:
#   export TF_VAR_gitops_repo_token=github_pat_xxx
#   export TF_VAR_alert_slack_webhook_url=https://hooks.slack.com/services/...   (optional)

variable "gitops_repo_token" {
  description = "GitHub fine-grained PAT with read access to jttadmin/jhanvi-trends-gke"
  type        = string
  sensitive   = true
}

variable "alert_slack_webhook_url" {
  description = "Slack incoming webhook for Alertmanager (optional)"
  type        = string
  default     = null
  sensitive   = true
}

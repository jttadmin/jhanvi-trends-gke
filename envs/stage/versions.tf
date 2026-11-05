terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.20, < 8.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # One state bucket per environment, in that environment's own project
  # (created by scripts/bootstrap-project.sh).
  backend "gcs" {
    bucket = "jhanvi-trends-stage-2611-tfstate"
    prefix = "jhanvi-trends/gke"
  }
}

provider "google" {
  project = local.project_id
  region  = local.region
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.platform.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.platform.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = "https://${module.platform.cluster_endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.platform.cluster_ca_certificate)
  }
}

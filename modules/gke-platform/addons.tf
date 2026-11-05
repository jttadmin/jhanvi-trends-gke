# Terraform owns the platform: Traefik, cert-manager, Argo CD and the
# observability stack (observability.tf). Your microservices, Postgres,
# MongoDB, Redis and Kafka keep flowing from the app repo through Argo CD.

# ---------- Traefik (ingress) on the static IP ----------
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  namespace        = "traefik"
  create_namespace = true

  values = [yamlencode({
    service = {
      spec = {
        type                  = "LoadBalancer"
        loadBalancerIP        = google_compute_address.ingress.address
        externalTrafficPolicy = "Local" # keeps real client IPs for your logs
      }
    }
    ingressClass = {
      enabled        = true
      isDefaultClass = true
    }
    ports = {
      web = {
        allowACMEByPass = true # let cert-manager's HTTP-01 challenge through before the redirect
        http = {
          redirections = {
            entryPoint = {
              to        = "websecure"
              scheme    = "https"
              permanent = true
            }
          }
        }
      }
    }
    nodeSelector = { workload = "stateful" } # keep ingress off Spot nodes

    # ---- observability ----
    metrics = {
      prometheus = {
        service        = { enabled = true }
        serviceMonitor = { enabled = true }
      }
    }
    log       = { format = "json" }
    accessLog = { enabled = true, format = "json" }
    tracing = {
      otlp = {
        enabled = true
        grpc = {
          enabled  = true
          endpoint = "${local.otel_gw_svc}:4317"
          insecure = true
        }
      }
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

# ---------- cert-manager ----------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  values = [yamlencode({
    crds = { enabled = true }
    prometheus = {
      enabled        = true
      servicemonitor = { enabled = true }
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

# ---------- Argo CD ----------
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    global = {
      domain = var.argocd_host
    }
    configs = {
      params = {
        "server.insecure" = true # TLS terminates at Traefik
      }
    }
    controller = {
      metrics = { enabled = true, serviceMonitor = { enabled = true } }
    }
    repoServer = {
      metrics = { enabled = true, serviceMonitor = { enabled = true } }
    }
    applicationSet = {
      metrics = { enabled = true, serviceMonitor = { enabled = true } }
    }
    server = {
      metrics = { enabled = true, serviceMonitor = { enabled = true } }
      ingress = {
        enabled          = true
        ingressClassName = "traefik"
        annotations = {
          "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
        }
        tls = true
      }
    }
  })]

  depends_on = [helm_release.traefik]
}

# ---------- Private repo credentials for Argo CD ----------
resource "kubernetes_secret_v1" "gitops_repo" {
  metadata {
    name      = "jhanvi-trends-repo"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.gitops_repo_url
    username = var.gitops_repo_username
    password = var.gitops_repo_token
  }

  depends_on = [helm_release.argocd]
}

# ---------- ClusterIssuer + app-of-apps ----------
# Shipped as a tiny local chart so Terraform doesn't need the CRDs at plan time.
resource "helm_release" "bootstrap" {
  name      = "jhanvi-bootstrap"
  chart     = "${path.module}/charts/bootstrap"
  namespace = "argocd"

  values = [yamlencode({
    letsencryptEmail = var.letsencrypt_email
    gitops = {
      repoURL        = var.gitops_repo_url
      targetRevision = var.gitops_target_revision
      path           = var.gitops_apps_path
    }
  })]

  depends_on = [
    helm_release.cert_manager,
    helm_release.argocd,
    kubernetes_secret_v1.gitops_repo,
  ]
}

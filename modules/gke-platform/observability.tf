# =====================================================================
# Observability: Grafana LGTM + OpenTelemetry
#
#   Apps ──OTLP──▶ otel-gateway ──┬─ traces  ─▶ Tempo   (GCS)
#                                 ├─ metrics ─▶ Prometheus (OTLP receiver)
#                                 └─ logs    ─▶ Loki    (GCS)
#   Pod stdout ──▶ otel-agent (DaemonSet, filelog) ─▶ Loki
#   Prometheus also scrapes nodes, kube-state-metrics, Traefik, Argo CD,
#   cert-manager and any ServiceMonitor/PodMonitor in any namespace.
#   Grafana (grafana.bhumaji.com) ties them together: logs ⇄ traces ⇄ metrics.
#
# Metrics backend is Prometheus (from kube-prometheus-stack) instead of Mimir:
# for one small cluster it's far lighter; Mimir can be added later via
# Prometheus remote_write without touching the apps.
# =====================================================================

variable "prometheus_host" {
  description = "Public hostname for the Prometheus UI (behind Traefik basic auth)"
  type        = string
  default     = "prom.bhumaji.com"
}

locals {
  obs_ns        = "observability"
  obs_node      = { workload = "stateful" }
  prom_svc      = "http://kps-prometheus.${local.obs_ns}.svc:9090"
  loki_svc      = "http://loki.${local.obs_ns}.svc:3100"
  tempo_svc     = "tempo.${local.obs_ns}.svc"
  otel_gw_svc   = "otel-gateway.${local.obs_ns}.svc"
  slack_enabled = var.alert_slack_webhook_url != null && var.alert_slack_webhook_url != ""

  alertmanager_config = {
    global = local.slack_enabled ? { slack_api_url = var.alert_slack_webhook_url } : {}
    route = {
      receiver        = local.slack_enabled ? "slack" : "null"
      group_by        = ["alertname", "namespace"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
      routes = [
        { receiver = "null", matchers = ["alertname = \"Watchdog\""] },
        { receiver = "null", matchers = ["alertname = \"InfoInhibitor\""] },
      ]
    }
    receivers = concat(
      [{ name = "null" }],
      local.slack_enabled ? [{
        name = "slack"
        slack_configs = [{
          channel       = var.alert_slack_channel
          send_resolved = true
          title         = "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}"
          text          = "{{ range .Alerts }}*{{ .Labels.severity }}* {{ .Annotations.summary }}\n{{ .Annotations.description }}\n{{ end }}"
        }]
      }] : []
    )
    inhibit_rules = [{
      source_matchers = ["severity = critical"]
      target_matchers = ["severity = warning"]
      equal           = ["alertname", "namespace"]
    }]
  }
}

resource "kubernetes_namespace_v1" "observability" {
  metadata {
    name = local.obs_ns
  }
  depends_on = [google_container_node_pool.stateful]
}

# ---------- GCS buckets for Loki chunks and Tempo traces ----------
resource "google_storage_bucket" "loki" {
  name                        = "${var.project_id}-${var.cluster_name}-loki"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = !var.deletion_protection
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition { age = var.logs_retention_days + 2 }
    action { type = "Delete" }
  }
  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket" "tempo" {
  name                        = "${var.project_id}-${var.cluster_name}-tempo"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = !var.deletion_protection
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition { age = var.traces_retention_days + 2 }
    action { type = "Delete" }
  }
  depends_on = [google_project_service.apis]
}

# ---------- Workload Identity: KSA -> GSA -> bucket (no JSON keys) ----------
resource "google_service_account" "obs" {
  for_each     = toset(["loki", "tempo"])
  account_id   = "${var.cluster_name}-${each.key}"
  display_name = "${each.key} on ${var.cluster_name}"
}

resource "google_storage_bucket_iam_member" "obs" {
  for_each = {
    loki  = google_storage_bucket.loki.name
    tempo = google_storage_bucket.tempo.name
  }
  bucket = each.value
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.obs[each.key].email}"
}

# objectAdmin doesn't include storage.buckets.get, which Tempo/Loki call at startup
resource "google_storage_bucket_iam_member" "obs_bucket_read" {
  for_each = {
    loki  = google_storage_bucket.loki.name
    tempo = google_storage_bucket.tempo.name
  }
  bucket = each.value
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.obs[each.key].email}"
}

resource "google_service_account_iam_member" "obs_wi" {
  for_each           = google_service_account.obs
  service_account_id = each.value.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.obs_ns}/${each.key}]"
  depends_on         = [google_container_cluster.this]
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

# ---------- Basic auth for prom.bhumaji.com (Prometheus has no login of its own) ----------
resource "random_password" "prometheus_basic_auth" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "prometheus_basic_auth" {
  metadata {
    name      = "prometheus-basic-auth"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = {
    users = "admin:${bcrypt(random_password.prometheus_basic_auth.result)}"
  }
  # bcrypt() gives a new salt on every run; only write the secret once
  lifecycle {
    ignore_changes = [data]
  }
}

# ---------- Prometheus + Alertmanager + Grafana + exporters ----------
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace_v1.observability.metadata[0].name
  timeout    = 900

  values = [yamlencode({
    fullnameOverride = "kps"

    # GKE manages the control plane; these targets aren't reachable.
    # kube-proxy doesn't exist with Dataplane V2.
    kubeEtcd              = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeProxy             = { enabled = false }

    prometheusOperator = { nodeSelector = local.obs_node }
    kube-state-metrics = {
      nodeSelector          = local.obs_node
      metricLabelsAllowlist = ["nodes=[workload]"]
    }

    prometheus = {
      ingress = {
        enabled          = true
        ingressClassName = "traefik"
        annotations = {
          "cert-manager.io/cluster-issuer"                   = "letsencrypt-prod"
          "traefik.ingress.kubernetes.io/router.middlewares" = "${local.obs_ns}-prom-auth@kubernetescrd"
        }
        hosts    = [var.prometheus_host]
        paths    = ["/"]
        pathType = "Prefix"
        tls      = [{ secretName = "prometheus-tls", hosts = [var.prometheus_host] }]
      }
      prometheusSpec = {
        nodeSelector  = local.obs_node
        externalUrl   = "https://${var.prometheus_host}"
        retention     = "${var.metrics_retention_days}d"
        retentionSize = "${var.prometheus_disk_gb - 5}GB"

        # Accept OTLP metrics from the gateway and remote_write from Tempo
        enableOTLPReceiver        = true
        enableRemoteWriteReceiver = true
        enableFeatures            = ["exemplar-storage"]

        # Pick up ServiceMonitors/PodMonitors/rules from every namespace and chart
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        probeSelectorNilUsesHelmValues          = false

        resources = {
          requests = { cpu = "250m", memory = "1Gi" }
          limits   = { memory = "3Gi" }
        }
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "standard-rwo"
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = "${var.prometheus_disk_gb}Gi" } }
            }
          }
        }
      }
    }

    alertmanager = {
      config = local.alertmanager_config
      alertmanagerSpec = {
        nodeSelector = local.obs_node
        storage = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "standard-rwo"
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = "2Gi" } }
            }
          }
        }
      }
    }

    grafana = {
      fullnameOverride = "grafana"
      adminPassword    = random_password.grafana_admin.result
      nodeSelector     = local.obs_node
      persistence = {
        enabled          = true
        storageClassName = "standard-rwo"
        size             = "5Gi"
      }
      "grafana.ini" = {
        server = { root_url = "https://${var.grafana_host}" }
        users  = { allow_sign_up = false }
      }
      ingress = {
        enabled          = true
        ingressClassName = "traefik"
        annotations      = { "cert-manager.io/cluster-issuer" = "letsencrypt-prod" }
        hosts            = [var.grafana_host]
        tls              = [{ secretName = "grafana-tls", hosts = [var.grafana_host] }]
      }

      # Apps can ship their own dashboards as ConfigMaps labelled grafana_dashboard=1
      sidecar = {
        dashboards = {
          enabled          = true
          searchNamespace  = "ALL"
          folderAnnotation = "grafana_folder"
          provider         = { foldersFromFilesStructure = true }
        }
        datasources = { exemplarTraceIdDestinations = { datasourceUid = "tempo", traceIdLabelName = "trace_id" } }
      }

      additionalDataSources = [
        {
          name      = "Loki"
          uid       = "loki"
          type      = "loki"
          access    = "proxy"
          url       = local.loki_svc
          isDefault = false
          jsonData = {
            derivedFields = [
              { name = "TraceID", matcherType = "label", matcherRegex = "trace_id", datasourceUid = "tempo", url = "$${__value.raw}", urlDisplayLabel = "View trace" },
              { name = "TraceID (log line)", matcherRegex = "\"?trace_?[iI][dD]\"?[:=]\"?(\\w+)", datasourceUid = "tempo", url = "$${__value.raw}" },
            ]
          }
        },
        {
          name   = "Tempo"
          uid    = "tempo"
          type   = "tempo"
          access = "proxy"
          url    = "http://${local.tempo_svc}:3200"
          jsonData = {
            tracesToLogsV2 = {
              datasourceUid      = "loki"
              spanStartTimeShift = "-5m"
              spanEndTimeShift   = "5m"
              filterByTraceID    = true
              tags               = [{ key = "service.name", value = "service_name" }]
            }
            tracesToMetrics = {
              datasourceUid = "prometheus"
              tags          = [{ key = "service.name", value = "service" }]
            }
            serviceMap       = { datasourceUid = "prometheus" }
            nodeGraph        = { enabled = true }
            lokiSearch       = { datasourceUid = "loki" }
            search           = { hide = false }
            streamingEnabled = { search = true }
          }
        },
      ]

      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1
          providers = [{
            name            = "platform"
            folder          = "Platform"
            type            = "file"
            disableDeletion = false
            options         = { path = "/var/lib/grafana/dashboards/platform" }
          }]
        }
      }
      dashboards = {
        platform = {
          traefik      = { gnetId = 17346, revision = 9, datasource = "Prometheus" }
          argocd       = { gnetId = 14584, revision = 1, datasource = "Prometheus" }
          cert-manager = { gnetId = 20842, revision = 3, datasource = "Prometheus" }
          loki-logs    = { gnetId = 13639, revision = 2, datasource = "Loki" }
        }
      }
    }
  })]

  depends_on = [google_container_node_pool.stateful, google_container_node_pool.apps]
}

# ---------- Loki (single binary, chunks in GCS) ----------
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version
  namespace  = local.obs_ns
  timeout    = 600

  values = [yamlencode({
    deploymentMode = "SingleBinary"

    serviceAccount = {
      create      = true
      name        = "loki"
      annotations = { "iam.gke.io/gcp-service-account" = google_service_account.obs["loki"].email }
    }

    loki = {
      auth_enabled = false
      commonConfig = { replication_factor = 1 }
      schemaConfig = {
        configs = [{
          from         = "2024-04-01"
          store        = "tsdb"
          object_store = "gcs"
          schema       = "v13"
          index        = { prefix = "loki_index_", period = "24h" }
        }]
      }
      storage = {
        type = "gcs"
        bucketNames = {
          chunks = google_storage_bucket.loki.name
          ruler  = google_storage_bucket.loki.name
          admin  = google_storage_bucket.loki.name
        }
      }
      limits_config = {
        retention_period          = "${var.logs_retention_days * 24}h"
        allow_structured_metadata = true # required for OTLP logs
        volume_enabled            = true
        ingestion_rate_mb         = 10
        ingestion_burst_size_mb   = 20
      }
      compactor = {
        retention_enabled    = true
        delete_request_store = "gcs"
      }
      pattern_ingester = { enabled = true }
    }

    singleBinary = {
      replicas     = 1
      nodeSelector = local.obs_node
      persistence  = { enabled = true, size = "10Gi", storageClass = "standard-rwo" }
      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
    }

    # Simple-scalable / distributed components off
    read    = { replicas = 0 }
    write   = { replicas = 0 }
    backend = { replicas = 0 }

    gateway      = { enabled = false }
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }
    minio        = { enabled = false }
    monitoring   = { serviceMonitor = { enabled = true } }
  })]

  depends_on = [
    helm_release.kube_prometheus_stack,
    google_service_account_iam_member.obs_wi,
    google_storage_bucket_iam_member.obs,
    google_storage_bucket_iam_member.obs_bucket_read,
  ]
}

# ---------- Tempo (monolithic, traces in GCS, span metrics -> Prometheus) ----------
resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana-community.github.io/helm-charts" # moved here Jan 2026
  chart      = "tempo"
  version    = var.tempo_chart_version
  namespace  = local.obs_ns
  timeout    = 600

  values = [yamlencode({
    serviceAccount = {
      create      = true
      name        = "tempo"
      annotations = { "iam.gke.io/gcp-service-account" = google_service_account.obs["tempo"].email }
    }
    nodeSelector   = local.obs_node
    persistence    = { enabled = true, size = "10Gi", storageClassName = "standard-rwo" }
    serviceMonitor = { enabled = true }

    tempo = {
      reportingEnabled = false # anonymous usage stats to Grafana Labs; also needs bucket metadata access
      retention        = "${var.traces_retention_days * 24}h"
      storage = {
        trace = {
          backend = "gcs"
          gcs     = { bucket_name = google_storage_bucket.tempo.name }
          wal     = { path = "/var/tempo/wal" }
        }
      }
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
      }
      # Service graph + RED metrics per service, written into Prometheus
      metricsGenerator = {
        enabled        = true
        remoteWriteUrl = "${local.prom_svc}/api/v1/write"
      }
      overrides = {
        defaults = {
          # local-blocks was removed in Tempo 3.0
          metrics_generator = { processors = ["service-graphs", "span-metrics"] }
        }
      }
      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
    }
  })]

  depends_on = [
    helm_release.kube_prometheus_stack,
    google_service_account_iam_member.obs_wi,
    google_storage_bucket_iam_member.obs,
    google_storage_bucket_iam_member.obs_bucket_read,
  ]
}

# ---------- OTel gateway: the one endpoint your services send OTLP to ----------
resource "helm_release" "otel_gateway" {
  name       = "otel-gateway"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = var.otel_collector_chart_version
  namespace  = local.obs_ns

  values = [yamlencode({
    fullnameOverride = "otel-gateway"
    mode             = "deployment"
    replicaCount     = 2
    image            = { repository = "otel/opentelemetry-collector-contrib" }
    nodeSelector     = local.obs_node
    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { memory = "1Gi" }
    }

    presets = {
      kubernetesAttributes = { enabled = true } # adds k8s.namespace/pod/deployment to every signal
    }

    ports = {
      jaeger-compact = { enabled = false }
      jaeger-thrift  = { enabled = false }
      jaeger-grpc    = { enabled = false }
      zipkin         = { enabled = false }
      metrics        = { enabled = true }
    }

    serviceMonitor = { enabled = true }

    config = {
      receivers = {
        jaeger     = null
        zipkin     = null
        prometheus = null
        otlp = {
          protocols = {
            grpc = { endpoint = "$${env:MY_POD_IP}:4317" }
            http = { endpoint = "$${env:MY_POD_IP}:4318" }
          }
        }
      }
      processors = {
        memory_limiter = { check_interval = "5s", limit_percentage = 80, spike_limit_percentage = 25 }
        batch          = { send_batch_size = 8192, timeout = "5s" }
        # Drop health-check noise before it costs storage
        "filter/healthchecks" = {
          error_mode = "ignore"
          traces = {
            span = ["attributes[\"url.path\"] == \"/health\"", "attributes[\"url.path\"] == \"/actuator/health\"", "attributes[\"http.target\"] == \"/health\""]
          }
        }
      }
      exporters = {
        debug           = null
        "otlp/tempo"    = { endpoint = "${local.tempo_svc}:4317", tls = { insecure = true } }
        "otlphttp/prom" = { endpoint = "${local.prom_svc}/api/v1/otlp", tls = { insecure = true } }
        "otlphttp/loki" = { endpoint = "${local.loki_svc}/otlp", tls = { insecure = true } }
      }
      service = {
        pipelines = {
          traces = {
            receivers  = ["otlp"]
            processors = ["memory_limiter", "filter/healthchecks", "batch"]
            exporters  = ["otlp/tempo"]
          }
          metrics = {
            receivers  = ["otlp"]
            processors = ["memory_limiter", "batch"]
            exporters  = ["otlphttp/prom"]
          }
          logs = {
            receivers  = ["otlp"]
            processors = ["memory_limiter", "batch"]
            exporters  = ["otlphttp/loki"]
          }
        }
      }
    }
  })]

  depends_on = [helm_release.loki, helm_release.tempo]
}

# ---------- OTel agent: tails every pod's stdout on every node -> Loki ----------
resource "helm_release" "otel_agent" {
  name       = "otel-agent"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = var.otel_collector_chart_version
  namespace  = local.obs_ns

  values = [yamlencode({
    fullnameOverride = "otel-agent"
    mode             = "daemonset"
    image            = { repository = "otel/opentelemetry-collector-contrib" }
    # Must run on every node (stateful + Spot apps)
    tolerations = [{ operator = "Exists" }]
    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "512Mi" }
    }

    presets = {
      logsCollection       = { enabled = true, includeCollectorLogs = false }
      kubernetesAttributes = { enabled = true }
    }

    ports = {
      otlp           = { enabled = false }
      otlp-http      = { enabled = false }
      jaeger-compact = { enabled = false }
      jaeger-thrift  = { enabled = false }
      jaeger-grpc    = { enabled = false }
      zipkin         = { enabled = false }
    }

    config = {
      receivers = {
        jaeger     = null
        zipkin     = null
        prometheus = null
        otlp       = null
      }
      processors = {
        memory_limiter = { check_interval = "5s", limit_percentage = 80, spike_limit_percentage = 25 }
        batch          = { send_batch_size = 4096, timeout = "5s" }
        # Promote a few k8s attributes to Loki index labels
        "resource/loki" = {
          attributes = [{
            action = "insert"
            key    = "loki.resource.labels"
            value  = "k8s.namespace.name, k8s.pod.name, k8s.container.name, k8s.deployment.name, service.name"
          }]
        }
      }
      exporters = {
        debug           = null
        "otlphttp/loki" = { endpoint = "${local.loki_svc}/otlp", tls = { insecure = true } }
      }
      service = {
        pipelines = {
          traces  = null
          metrics = null
          logs = {
            receivers  = ["filelog"]
            processors = ["memory_limiter", "resource/loki", "batch"]
            exporters  = ["otlphttp/loki"]
          }
        }
      }
    }
  })]

  depends_on = [helm_release.loki]
}

# ---------- Jhanvi Trends alert rules (PrometheusRule CRs) ----------
resource "helm_release" "observability_extras" {
  name      = "jhanvi-observability"
  chart     = "${path.module}/charts/observability-extras"
  namespace = local.obs_ns

  values = [yamlencode({
    appNamespaces = var.app_namespaces
  })]

  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.traefik,
    kubernetes_secret_v1.prometheus_basic_auth,
  ]
}

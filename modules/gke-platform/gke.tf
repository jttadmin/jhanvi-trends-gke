# ---------- Node service account (least privilege) ----------
resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE nodes for ${var.cluster_name}"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# ---------- Cluster ----------
resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone # zonal cluster

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.gke.id

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = var.deletion_protection

  release_channel {
    channel = "REGULAR"
  }

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Dataplane V2 (eBPF) — gives you NetworkPolicy enforcement out of the box
  datapath_provider = "ADVANCED_DATAPATH"

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # keep public API endpoint so kubectl/GitHub Actions work
    master_ipv4_cidr_block  = var.master_cidr
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_cidrs) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_cidrs
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    horizontal_pod_autoscaling {
      disabled = false # needed for your 70% CPU/memory HPAs (metrics-server is built in)
    }
    http_load_balancing {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true # replaces local-path; default StorageClass is "standard-rwo"
    }
  }

  # You run Grafana LGTM + OpenTelemetry yourself, so keep Google's
  # logging/monitoring to system components only (cheaper).
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }

  # 02:00 IST daily
  maintenance_policy {
    daily_maintenance_window {
      start_time = "20:30"
    }
  }

  depends_on = [google_project_service.apis]
}

# ---------- Node pool: stateful (on-demand) ----------
# Postgres, MongoDB, Redis, Kafka and the LGTM stack go here.
# In those Helm values add:  nodeSelector: { workload: stateful }
resource "google_container_node_pool" "stateful" {
  name     = "stateful"
  cluster  = google_container_cluster.this.id
  location = var.zone

  initial_node_count = var.stateful_min_nodes

  autoscaling {
    min_node_count = var.stateful_min_nodes
    max_node_count = var.stateful_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.stateful_machine_type
    spot            = var.stateful_use_spot
    disk_type       = var.node_disk_type
    disk_size_gb    = var.node_disk_size_gb
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      workload = "stateful"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

# ---------- Node pool: apps (Spot) ----------
# Stateless microservices. Add:  nodeSelector: { workload: apps }
resource "google_container_node_pool" "apps" {
  name     = "apps"
  cluster  = google_container_cluster.this.id
  location = var.zone

  initial_node_count = var.apps_min_nodes

  autoscaling {
    min_node_count = var.apps_min_nodes
    max_node_count = var.apps_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.apps_machine_type
    spot            = var.apps_use_spot
    disk_type       = var.node_disk_type
    disk_size_gb    = var.node_disk_size_gb
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      workload = "apps"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

# =====================================================================
# Kept data: survives scripts/destroy.sh, re-attached by scripts/up.sh
#
#   Named persistent disks  ──▶  pre-bound PersistentVolumes (Retain)
#                                 ──▶ the exact PVC names the StatefulSets /
#                                     Helm charts create, so they bind to the
#                                     kept disk instead of a fresh empty one.
#
#   destroy.sh removes the disks (and the Loki/Tempo buckets) from state before
#   `terraform destroy`; up.sh imports them again. `destroy.sh <env> --purge`
#   deletes them for good.
#
#   prevent_destroy is a safety net: a plain `terraform destroy` with a kept disk
#   still in state fails instead of deleting your data.
# =====================================================================

variable "keep_data" {
  description = "Keep Prometheus/Grafana/Alertmanager/Postgres/MongoDB data on named disks across destroy/up"
  type        = bool
  default     = true
}

variable "kept_disk_type" {
  description = "Disk type for kept volumes (pd-standard is cheapest while the cluster is down)"
  type        = string
  default     = "pd-standard"
}

locals {
  app_ns = "jhanvi-trends"

  # key = disk suffix, pvc = the claim name the workload creates (from `kubectl get pvc -A`)
  kept_volumes_all = {
    prometheus   = { namespace = local.obs_ns, pvc = "prometheus-kps-prometheus-db-prometheus-kps-prometheus-0", size_gb = var.prometheus_disk_gb }
    alertmanager = { namespace = local.obs_ns, pvc = "alertmanager-kps-alertmanager-db-alertmanager-kps-alertmanager-0", size_gb = 2 }
    grafana      = { namespace = local.obs_ns, pvc = "grafana", size_gb = 5 }
    postgres     = { namespace = local.app_ns, pvc = "data-postgres-0", size_gb = 5 }
    mongodb      = { namespace = local.app_ns, pvc = "data-mongodb-0", size_gb = 5 }
    # Optional, uncomment to keep them too:
    # kafka      = { namespace = local.app_ns, pvc = "data-kafka-0", size_gb = 5 }
    # redis      = { namespace = local.app_ns, pvc = "data-redis-0", size_gb = 1 }
  }
  kept_volumes = var.keep_data ? local.kept_volumes_all : {}

  kept_zone = google_container_cluster.this.location
}

resource "google_compute_disk" "kept" {
  for_each = local.kept_volumes

  name   = "${var.cluster_name}-kept-${each.key}"
  type   = var.kept_disk_type
  zone   = local.kept_zone
  size   = each.value.size_gb
  labels = { "jt-kept" = "true", "jt-key" = each.key }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [size, snapshot] # grow by hand; a disk restored from a snapshot (docs/BACKUP-RESTORE.md) is not replaced
  }
  depends_on = [google_project_service.apis]
}

resource "kubernetes_persistent_volume_v1" "kept" {
  for_each = local.kept_volumes

  metadata {
    name   = "kept-${each.key}"
    labels = { "jt-kept" = "true" }
  }
  spec {
    capacity                         = { storage = "${each.value.size_gb}Gi" }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain" # deleting the PVC never deletes the disk
    storage_class_name               = "standard-rwo"

    # Pre-bind: only this exact PVC may use this volume
    claim_ref {
      namespace = each.value.namespace
      name      = each.value.pvc
    }

    persistent_volume_source {
      csi {
        driver        = "pd.csi.storage.gke.io"
        volume_handle = google_compute_disk.kept[each.key].id # projects/<p>/zones/<z>/disks/<name>
        fs_type       = "ext4"
      }
    }

    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "topology.gke.io/zone"
            operator = "In"
            values   = [local.kept_zone]
          }
        }
      }
    }
  }

  depends_on = [google_container_node_pool.stateful]
}

output "kept_disks" {
  description = "Disks that survive destroy (delete with: scripts/destroy.sh <env> --purge)"
  value       = { for k, d in google_compute_disk.kept : k => d.name }
}

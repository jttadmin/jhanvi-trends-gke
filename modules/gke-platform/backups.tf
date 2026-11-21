# =====================================================================
# Backups: two independent layers, so one mistake can't take out both.
#
#   1. Disk snapshots (crash-consistent, whole volume): a daily snapshot
#      schedule attached to the kept Postgres / MongoDB / Grafana disks.
#      Restore = create a disk from a snapshot, point the kept PV at it.
#
#   2. Logical dumps (pg_dumpall / mongodump), written nightly by CronJobs in
#      the store chart (templates/backups.yaml) to a GCS bucket, through
#      Workload Identity (KSA jhanvi-trends/db-backup -> GSA below). Portable:
#      restorable into any Postgres/Mongo, including Cloud SQL later.
#
# The bucket is "kept" like the Loki/Tempo buckets: destroy.sh takes it out of
# state, up.sh re-adopts it, destroy.sh --purge deletes it.
# =====================================================================

variable "enable_snapshot_schedule" {
  description = "Daily disk snapshots on/off (off in dev to save cost; nightly dumps still run)"
  type        = bool
  default     = true
}

variable "snapshot_disks" {
  description = "Kept disks (keys of the kept volumes) that get a daily snapshot"
  type        = list(string)
  default     = ["postgres", "mongodb", "grafana"]
}

variable "snapshot_retention_days" {
  description = "How long daily disk snapshots are kept"
  type        = number
  default     = 7
}

variable "backup_retention_days" {
  description = "How long nightly database dumps are kept in the backup bucket"
  type        = number
  default     = 14
}

resource "google_compute_resource_policy" "daily_snapshots" {
  count  = var.enable_snapshot_schedule ? 1 : 0
  name   = "${var.cluster_name}-daily-snapshots"
  region = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "21:00" # UTC = 02:30 IST, quiet hours
      }
    }
    retention_policy {
      max_retention_days    = var.snapshot_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS" # snapshots outlive a purged disk until they expire
    }
    snapshot_properties {
      labels            = { "jt-snapshot" = "true" }
      storage_locations = [var.region]
      guest_flush       = false
    }
  }
  depends_on = [google_project_service.apis]
}

resource "google_compute_disk_resource_policy_attachment" "daily_snapshots" {
  for_each = var.enable_snapshot_schedule ? { for k in var.snapshot_disks : k => k if contains(keys(local.kept_volumes), k) } : {}

  name = google_compute_resource_policy.daily_snapshots[0].name
  disk = google_compute_disk.kept[each.key].name
  zone = local.kept_zone
}

resource "google_storage_bucket" "backups" {
  name                        = "${var.project_id}-${var.cluster_name}-backups"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = !var.deletion_protection
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition { age = var.backup_retention_days }
    action { type = "Delete" }
  }
  # Dumps are written once and never rewritten: soft delete protects against an accidental `rm`.
  soft_delete_policy {
    retention_duration_seconds = 7 * 24 * 3600
  }
  # kept across destroy.sh (removed from state first); --purge deletes it with gcloud
  lifecycle { prevent_destroy = true }
  depends_on = [google_project_service.apis]
}

resource "google_service_account" "db_backup" {
  account_id   = "${var.cluster_name}-db-backup"
  display_name = "Database dumps on ${var.cluster_name}"
}

# Create-only: the job can write new dumps but cannot read, overwrite or delete old ones,
# so a compromised backup pod can't destroy the backup history.
resource "google_storage_bucket_iam_member" "db_backup_writer" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.db_backup.email}"
}

resource "google_service_account_iam_member" "db_backup_wi" {
  service_account_id = google_service_account.db_backup.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.app_ns}/db-backup]"
  depends_on         = [google_container_cluster.this]
}

output "backups" {
  description = "Where backups go, and the identity the backup CronJobs use"
  value = {
    bucket            = google_storage_bucket.backups.name
    service_account   = google_service_account.db_backup.email
    snapshot_policy   = var.enable_snapshot_schedule ? google_compute_resource_policy.daily_snapshots[0].name : "off"
    snapshot_disks    = [for k, _ in google_compute_disk_resource_policy_attachment.daily_snapshots : k]
    dump_retention    = "${var.backup_retention_days} days"
    snapshot_retained = "${var.snapshot_retention_days} days"
  }
}

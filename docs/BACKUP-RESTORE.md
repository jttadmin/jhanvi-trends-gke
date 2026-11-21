# Backup and restore

Two independent layers. Losing one never loses the other.

| | Disk snapshots | Logical dumps |
|---|---|---|
| What | Whole persistent disks: Postgres, MongoDB, Grafana | `pg_dumpall` + `mongodump` |
| When | Daily 21:00 UTC (02:30 IST), **off in dev** (`enable_snapshot_schedule = false`) | Daily 20:30 UTC (02:00 IST) |
| Kept | 7 days (prod 14) | 14 days (prod 30), plus 7 days of soft delete |
| Where | Compute Engine snapshots, same region | GCS bucket `<project>-jhanvi-trends-gke-backups` |
| Made by | Terraform snapshot schedule (`modules/gke-platform/backups.tf`) | CronJobs in the store chart (`templates/backups.yaml`) |
| Best for | Fast full restore of a volume | Restoring into a new or different database (e.g. Cloud SQL), a single database |

The backup job's Google service account can only **create** objects. It can't read, overwrite or delete earlier dumps, so a compromised pod can't wipe the history.

## Setup (once per environment)

1. Apply Terraform (`cd envs/<env> && terraform apply`), then check `terraform output backups`.
2. The chart's `values-<env>.yaml` already has the matching `backups.bucket` and `backups.gcpServiceAccount`. They follow the naming in Terraform, so only change them if you renamed the project or cluster.
3. Test now instead of waiting for the night:
   ```bash
   k create job --from=cronjob/postgres-backup pg-manual
   k create job --from=cronjob/mongodb-backup  mongo-manual
   k logs job/pg-manual -c upload      # uploaded gs://.../postgres/2026-...sql.gz
   gcloud storage ls gs://<project>-jhanvi-trends-gke-backups/postgres/
   ```

## Restore a logical dump

```bash
B=gs://<project>-jhanvi-trends-gke-backups
gcloud storage ls $B/postgres/ | tail -3        # pick one
gcloud storage cp $B/postgres/<file>.sql.gz .
k scale deploy user-service inventory-service order-service --replicas=0   # stop writers (HPA scales them back)
gunzip -c <file>.sql.gz | k exec -i postgres-0 -c postgres -- psql -U jhanvitrends -d postgres
k rollout restart deploy user-service inventory-service order-service

gcloud storage cp $B/mongodb/<file>.archive.gz .
k scale deploy catalog-service --replicas=0
k exec -i mongodb-0 -c mongodb -- sh -c 'mongorestore --uri "mongodb://jhanvitrends:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/?authSource=admin" --archive --gzip --drop' < <file>.archive.gz
k rollout restart deploy catalog-service
```
The Postgres dump is made with `--clean --if-exists`, so it drops and recreates objects. Restore it into the database it came from.

## Restore a disk snapshot (whole volume)

```bash
gcloud compute snapshots list --filter="labels.jt-snapshot=true" --project <project>
# 1. stop the database:          k scale statefulset postgres --replicas=0
# 2. replace the kept disk:      delete jhanvi-trends-gke-kept-postgres, then
gcloud compute disks create jhanvi-trends-gke-kept-postgres --source-snapshot <snapshot> \
  --zone asia-south1-a --type pd-standard --labels jt-kept=true,jt-key=postgres --project <project>
# 3. start it again:             k scale statefulset postgres --replicas=1
```
The PersistentVolume `kept-postgres` points at the disk by name, so a disk recreated from a snapshot under the same name is picked up without changing Kubernetes objects. Terraform still manages the disk (same name, same labels), so `terraform plan` shows no change.

## Practise it

A backup you haven't restored isn't a backup. Once a month in dev: restore last night's Postgres dump into a scratch database (`createdb restore_test`, replace `-d postgres` with `-d restore_test`), count rows in `orders`, then drop it.

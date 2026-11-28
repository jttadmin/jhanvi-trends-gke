# Open decisions

Three improvements that are deliberately **not** implemented yet, because each one costs money or changes how the project works. Each has options and a recommendation. When you decide, record the choice here (date + reason) and open the matching PR.

## 1. Highly available databases for prod

**Today:** PostgreSQL, MongoDB, Valkey and Kafka each run as one pod on one persistent disk. Backups exist (daily disk snapshots and nightly dumps), but a node or zone failure means minutes to hours of downtime, and recovery from a dump loses up to a day of data.

| Option | What you get | Cost and effort |
|---|---|---|
| A. Managed services: **Cloud SQL** (Postgres, regional HA), **Memorystore** (Valkey), **MongoDB Atlas** or Firestore | Automatic failover, point-in-time recovery, patching done for you | A monthly charge per instance that continues **even while the cluster is paused**; private networking setup (Private Service Access); app changes are config only (hostnames, passwords) |
| B. Operators in the cluster: **CloudNativePG**, **Percona MongoDB Operator**, **Strimzi** (Kafka) | 3-replica clusters with failover and WAL archiving to GCS, still in Kubernetes | Free software, but 3x the database pods and disks; more to operate and upgrade |
| C. Keep single replicas (current) | Simple and cheapest | Downtime on node loss; RPO up to 24 h (dumps) |

**Recommendation:** keep C for dev and stage. When prod becomes real, use A for Postgres, because Cloud SQL regional HA plus point-in-time recovery is the biggest risk reduction for the least operational work. Use B (Strimzi) for Kafka if it must stay in-cluster. The nightly dumps already work as the migration path, because `pg_dumpall` restores straight into Cloud SQL.

## 2. Two repositories with two copies of the app

**Today:** `jhanvi-trends-gke` and `jhanvi-trends-kubeadm` each have a full copy of the 8 services, the chart and CI, and both push to the same Docker Hub images. They have already drifted: the code-quality work (linters, unit tests, CodeQL, signing) exists only in the GKE repo.

| Option | What it means |
|---|---|
| A. **One app repo, two infra repos** | `jhanvi-trends` holds the services, chart and CI (builds and signs images once). Each platform repo holds only Terraform/scripts plus the Argo CD ApplicationSet pointing at the app chart. Industry-standard split. |
| B. **GKE repo becomes the single source**, kubeadm repo becomes infra-only | Same as A without creating a new repo: the kubeadm cluster's Argo CD syncs the chart from `jhanvi-trends-gke`. |
| C. Keep two copies | Every fix twice; drift keeps growing. |

**Recommendation:** B. It's the smallest move. The kubeadm repo keeps `scripts/gce-cluster.sh`, the kubeadm platform values and its Argo CD app; the app code and CI live only in the GKE repo.

## 3. Progressive delivery (canary releases)

**Today:** each Argo CD sync replaces pods with a rolling update. A bad release reaches 100% of traffic, then the post-deploy tests catch it and block promotion, but dev is already broken until someone reverts.

| Option | What it means |
|---|---|
| A. **Argo Rollouts** with Traefik traffic splitting and a Prometheus **AnalysisTemplate** (error ratio, p95) | 10% → 50% → 100% with automatic rollback when metrics degrade. Deployments become `Rollout` objects; the HPA targets the Rollout. |
| B. Argo Rollouts **blue-green** for the frontend only | Simpler: preview, run the smoke test against the preview Service, then switch. |
| C. Keep rolling updates + post-deploy test gate (current) | Good enough while only dev runs automatically. |

**Recommendation:** C until stage/prod exist; then A for the frontend and order-service first (the user-facing and money paths). The SLO burn-rate rules added in the chart already give the metrics an AnalysisTemplate needs.

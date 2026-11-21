# jhanvi-trends-gke

The Jhanvi Trends store on **GKE**: the app (services, Helm chart, CI) and the Terraform that builds the cluster, with one reusable module and three environments, each in its own GCP project.

Each cluster's Argo CD syncs its own folder of **this repo** (`argocd/envs/<env>/`). The kubeadm-on-GCE version of the store, with its own full copy of the app, lives in [`jttadmin/jhanvi-trends-kubeadm`](https://github.com/jttadmin/jhanvi-trends-kubeadm); the two repos don't depend on each other. App fixes need to be made in both if you want both setups to get them. Both push to the same Docker Hub images (`jhanviadmin/jhanvi-trends-<service>`), tagged by commit SHA, so neither overwrites the other's deployed tag.

## Layout

```
modules/gke-platform/        everything one environment needs
  network.tf                 VPC, subnet + pod/service ranges, Cloud NAT, static ingress IP
  gke.tf                     zonal private GKE, node SA, "stateful" + "apps" node pools
  addons.tf                  Traefik, cert-manager, Argo CD, repo secret, app-of-apps
  observability.tf           Prometheus/Alertmanager/Grafana, Loki, Tempo, OTel gateway + agent
  charts/                    bootstrap (ClusterIssuers, root app), observability-extras (alerts)
envs/
  dev/                       the cluster running today (moved.tf adopts it into the module)
  stage/                     ready to apply later
  prod/                      ready to apply later, production sizing
scripts/bootstrap-project.sh one-time project + state bucket setup per env
examples/                    instrumentation example for services
services/                    the 8 microservices + loadgen (Dockerfile per service)
deploy/charts/jhanvi-trends/ store Helm chart: values.yaml + values-gke.yaml + values-<env>.yaml (image tags)
argocd/envs/<env>/           AppProject + Application per environment (synced by that cluster's root app)
docs/APP.md                  app secret, checks
.github/workflows/
  terraform.yml              envs/** and modules/** only: plan on PR, dev auto-applies, stage/prod need approval
  ci.yaml                    services/** and the chart: test, build, scan, push images, bump dev tags
  promote.yaml               opens a PR copying image tags dev -> stage or stage -> prod (automatic after a healthy deploy, or manual)
```

## Environments

| | dev | stage | prod |
|---|---|---|---|
| Status | **running** | not created yet | not created yet |
| GCP project | `jhanvi-trends-prod-2611`¹ | `jhanvi-trends-stage-2611` | `jhanvi-trends-prd-2611` |
| Hostnames | `*.bhumaji.com` (for now)² | `*.stage.bhumaji.com` | `*.bhumaji.com` |
| Argo CD syncs | `argocd/envs/dev` | `argocd/envs/stage` | `argocd/envs/prod` |
| Image tags | `values-dev.yaml`, bumped by CI | `values-stage.yaml`, promote PR | `values-prod.yaml`, promote PR |
| Nodes | all Spot, scale to 0 | all Spot, scale to 0 | on-demand data tier, Spot apps |
| Retention (metrics / logs / traces) | 3 / 3 / 3 days | 3 / 3 / 3 days | 15 / 14 / 7 days |
| Deletion protection | off | off | **on** |
| Apply from CI | automatic | after approval | after approval |

¹ Dev lives in the project created first. GCP project IDs can't be renamed, but you can change the display name:
`gcloud projects update jhanvi-trends-prod-2611 --name="Jhanvi Trends dev"`

² **Before creating prod**, free up the hostnames by moving dev. In `envs/dev/main.tf`, set `domain = "dev.bhumaji.com"`, apply, and add `*.dev` A records in GoDaddy.

What's the same and what's different between environments is all in `envs/<env>/main.tf`. The module holds the logic, and each environment only holds its settings.

## Day-to-day

```bash
cd envs/dev
export TF_VAR_gitops_repo_token=github_pat_xxx
terraform init
terraform plan
terraform apply

$(terraform output -raw get_credentials)
$(terraform output -raw kubectl_context_rename)     # context becomes "gke-dev"
kubectl --context gke-dev get nodes -L workload
```

### Pause / resume (keep everything, pay only for disks and IP)

```bash
P=$(terraform output -raw project_id); C=$(terraform output -raw cluster_name)
for p in apps stateful; do gcloud container clusters resize $C --node-pool $p --num-nodes 0 --zone asia-south1-a --project $P -q; done
for p in stateful apps; do gcloud container clusters resize $C --node-pool $p --num-nodes 1 --zone asia-south1-a --project $P -q; done
```

### Destroy and rebuild, keeping the same IP (no DNS changes)

```bash
terraform state rm module.platform.google_compute_address.ingress
terraform destroy
gcloud compute disks list --filter="-users:*" --project $P      # delete any leftover PVC disks

terraform import module.platform.google_compute_address.ingress \
  projects/$P/regions/asia-south1/addresses/jhanvi-trends-gke-ingress-ip
terraform apply
```

Let's Encrypt allows only 5 identical certificates per week, so keep full rebuilds to 5 or fewer per week per environment.

## Bringing up stage or prod

```bash
scripts/bootstrap-project.sh stage      # project, billing, APIs, state bucket, quota check
cd envs/stage && terraform init && terraform plan && terraform apply
terraform output dns_records            # add these A records in GoDaddy
```

The cluster's Argo CD syncs `argocd/envs/stage`, which deploys the chart with `values-stage.yaml`. See [Promoting a release](#promoting-a-release).

**Cost:** GKE's free tier covers one zonal cluster's control plane per billing account. Each extra cluster adds about $2.40/day for its control plane, on top of its nodes.

## Promoting a release

Build once, promote the same image: CI builds each image once, tagged with the commit SHA, and only Git changes after that.

```
push to main ─▶ ci.yaml: test, build, scan ─▶ bumps values-dev.yaml ─▶ dev Argo CD syncs
   dev synced ─▶ PostSync smoke test passes ─▶ Argo CD notification ─▶ promote.yaml ─▶ PR: dev tags → values-stage.yaml
 merge (auto if AUTO_MERGE_STAGE=true) ─▶ stage syncs ─▶ smoke test ─▶ notification ─▶ PR: stage tags → values-prod.yaml
 code-owner approval + merge ─▶ prod syncs (outside the Friday-Monday freeze window)
```

- **Smoke test:** every sync ends with a PostSync Job (`templates/smoke-test.yaml`) that checks each service's readiness endpoint and the store API inside the cluster. If it fails, the sync is marked Failed and nothing gets promoted. Logs: `kubectl -n jhanvi-trends logs job/smoke-test`.
- **Automatic promotion:** when an environment is synced, Healthy and smoke-tested, its Argo CD sends a `repository_dispatch` (`argocd-deployed`) to this repo, once per Git revision. `promote.yaml` reads the tags from *that exact commit*, so only what passed is promoted, even if `main` has moved on. Tags never move backwards.
- **One open PR per target** (`promote/stage`, `promote/prod`): a newer promotion updates the open PR instead of opening another.
- **Manual promotion** still works: Actions ▸ promote ▸ Run workflow (`to=stage|prod`, optional `services: cart-service,order-service`).
- Merging the PR *is* the deployment. Prod PRs never merge themselves; `.github/CODEOWNERS` makes them need an owner's approval.
- **Rollback:** revert the PR (or the CI bump commit for dev). Don't use Argo CD's Rollback button: auto-sync would undo it on the next reconcile.
- Prod has a sync window: no automated syncs from Friday 18:00 to Monday 06:00 IST. An admin can still sync by hand for an emergency fix.

One-time setup:
1. Settings → Actions → General → enable *Allow GitHub Actions to create and approve pull requests*.
2. Create a fine-grained PAT with **Contents: read and write** on this repo only, save it as the repo secret `ARGOCD_DISPATCH_TOKEN`, and let `terraform.yml` apply (or `export TF_VAR_argocd_github_dispatch_token=...` locally). Without it nothing breaks: promotion is just manual.
3. Optional: repo variable `AUTO_MERGE_STAGE=true` to merge dev → stage PRs automatically.
4. To enforce the prod approval: a branch ruleset on `main` with *Require a pull request* + *Require review from Code Owners*, and **GitHub Actions** in its bypass list so CI can still push the dev tag bumps.

## Verifying images

Every image pushed from `main` is signed with **cosign keyless signing**: GitHub Actions' OIDC identity, a short-lived Sigstore certificate, and an entry in the public Rekor transparency log. No signing keys exist to leak. Each image also has a signed **SPDX SBOM** attestation (Syft). To check an image before you deploy it:

```bash
IMG=docker.io/jhanviadmin/jhanvi-trends-frontend:<git sha>
ID='https://github.com/jttadmin/jhanvi-trends-gke/.github/workflows/ci.yaml@refs/heads/main'
ISSUER=https://token.actions.githubusercontent.com
cosign verify --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMG"
cosign verify-attestation --type spdxjson --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMG" \
  | jq -r '.payload | @base64d | fromjson | .predicate.packages | length'   # number of packages in the SBOM
```
Pull-request builds produce the SBOM as a build artifact only. They aren't pushed or signed.

## Observability (every environment)

```
Services ──OTLP :4318──▶ otel-gateway ──┬─ traces  ─▶ Tempo  ─(span metrics)─▶ Prometheus
                                        ├─ metrics ─▶ Prometheus (OTLP receiver)
                                        └─ logs    ─▶ Loki
Pod stdout (every node) ─▶ otel-agent ─▶ Loki
Traefik ─▶ metrics, JSON access logs, edge spans
Grafana https://grafana.<domain>   Prometheus https://prom.<domain> (basic auth)
```

- **Storage:** Loki and Tempo store data in per-environment GCS buckets via Workload Identity, so there are no JSON keys.
- **Alerts:** kube-prometheus-stack defaults, plus store rules in `modules/gke-platform/charts/observability-extras`.
- **Instrumenting services:** see `examples/app-instrumentation.yaml`. Set `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-gateway.observability.svc:4318`.

## CI setup (GitHub Actions + Workload Identity Federation)

Do this per environment, once its project exists:

```bash
ENV=dev; PROJECT=jhanvi-trends-prod-2611; REPO=jttadmin/jhanvi-trends-gke
gcloud iam service-accounts create tf-ci --project $PROJECT
gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:tf-ci@$PROJECT.iam.gserviceaccount.com" --role=roles/owner
gcloud iam workload-identity-pools create github --location=global --project $PROJECT
gcloud iam workload-identity-pools providers create-oidc github --location=global --workload-identity-pool=github --project $PROJECT \
  --issuer-uri=https://token.actions.githubusercontent.com \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='$REPO'"
POOL=$(gcloud iam workload-identity-pools describe github --location=global --project $PROJECT --format='value(name)')
gcloud iam service-accounts add-iam-policy-binding tf-ci@$PROJECT.iam.gserviceaccount.com --project $PROJECT \
  --role=roles/iam.workloadIdentityUser --member="principalSet://iam.googleapis.com/$POOL/attribute.repository/$REPO"
echo "GCP_WIF_PROVIDER_${ENV^^} = $POOL/providers/github"
echo "GCP_TF_SERVICE_ACCOUNT_${ENV^^} = tf-ci@$PROJECT.iam.gserviceaccount.com"
```

Tighten `roles/owner` later to `container.admin`, `compute.networkAdmin`, `iam.serviceAccountAdmin`, `resourcemanager.projectIamAdmin`, `storage.admin` and `serviceusage.serviceUsageAdmin`.

Then, in the GitHub repo under **Settings → Secrets and variables → Actions**:

| Type | Name |
|---|---|
| Variable | `ENABLED_ENVS` = `["dev"]` (later `["dev","stage","prod"]`) |
| Variable | `GCP_WIF_PROVIDER_DEV`, `GCP_TF_SERVICE_ACCOUNT_DEV` (and `_STAGE`, `_PROD` later) |
| Secret | `GITOPS_REPO_TOKEN`, `ALERT_SLACK_WEBHOOK_URL` (optional) |

Under **Settings → Environments**, create `dev`, `stage` and `prod`, and add yourself as a required reviewer on `stage` and `prod`.

> If you set `master_authorized_cidrs`, GitHub-hosted runners (random IPs) can't reach the cluster API for the Helm releases. Either leave it open, or use a self-hosted runner.

## How the store chart differs from the kubeadm version

These are already set in `deploy/charts/jhanvi-trends/values-gke.yaml`:

1. **StorageClass:** replace `local-path` with `standard-rwo`, or omit it.
2. **Node placement:**
   - Postgres, MongoDB, Redis and Kafka: `nodeSelector: { workload: stateful }`
   - Microservices: `nodeSelector: { workload: apps }`
3. **Spot nodes:** add a PodDisruptionBudget for the services.
4. **Ingress:** keep `ingressClassName: traefik` and `cert-manager.io/cluster-issuer: letsencrypt-prod`.
5. **Platform apps:** don't deploy Argo CD, Traefik, cert-manager or LGTM from the app repo. The infra repo owns them.
6. **Load balancers:** use Ingress, not `Service type: LoadBalancer`, so each environment keeps one IP and one LB.

# The store app on GKE

Terraform in this repo builds the GKE cluster, Traefik, cert-manager, Argo CD and the observability stack (Prometheus, Grafana, Loki, Tempo and the OTel gateway). Argo CD then syncs `argocd/envs/<env>/` from this same repo: an AppProject (only the `jhanvi-trends` namespace, no cluster-scoped objects) and an Application that deploys the store chart (`deploy/charts/jhanvi-trends`) with `values.yaml` + `values-gke.yaml` + `values-<env>.yaml`.

CI (`.github/workflows/ci.yaml`) builds the services that changed, pushes `jhanviadmin/jhanvi-trends-<service>:<commit>` and bumps the tags in `values-dev.yaml`; dev's Argo CD rolls them out. Stage and prod get new tags only through the promote workflow (see the README). It needs the repo secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.

## One-time: app secret

Run this before the first sync. Without it, pods wait in `CreateContainerConfigError` and then start on their own once the secret exists.

```bash
kubectl --context gke-dev create namespace jhanvi-trends --dry-run=client -o yaml | kubectl --context gke-dev apply -f -
rand() { openssl rand -base64 "${1:-24}" | tr -d '/+=' | cut -c1-"${1:-24}"; }
kubectl --context gke-dev -n jhanvi-trends create secret generic jhanvi-trends-secrets \
  --from-literal=POSTGRES_PASSWORD="$(rand)" \
  --from-literal=MONGODB_PASSWORD="$(rand)" \
  --from-literal=JWT_SECRET="$(rand 48)"
```

Keep the secret once the data stores have data. Postgres and MongoDB only read the password on first start.

## Check it

```bash
kubectl --context gke-dev -n argocd get applications
kubectl --context gke-dev -n jhanvi-trends get pods -o wide
kubectl --context gke-dev -n jhanvi-trends get pvc
kubectl --context gke-dev -n jhanvi-trends get certificate
```

The store is at https://shop.bhumaji.com. Its dashboards are in Grafana under the **Jhanvi Trends** folder.

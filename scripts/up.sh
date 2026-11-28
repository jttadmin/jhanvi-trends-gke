#!/usr/bin/env bash
# Create (or repair) an environment end to end.
#
#   scripts/up.sh dev
#
#   GitHub read-only token for Argo CD: either export TF_VAR_gitops_repo_token,
#   or save it once in ~/.config/jhanvi-trends/<env>.env (chmod 600):
#     export TF_VAR_gitops_repo_token='github_pat_...'
#
#   Optional, to set your own logins automatically at the end:
#   export GRAFANA_PASSWORD=... PROMETHEUS_PASSWORD=... ARGOCD_PASSWORD=...
#
# Works from any starting point: nothing built, half destroyed, or already running.
# Safe to re-run.
source "$(dirname "$0")/lib.sh"

load_env "${1:-}"

# Load the saved GitHub token so it never has to be exported by hand
TOKEN_FILE="$HOME/.config/jhanvi-trends/$ENV.env"
if [[ -z "${TF_VAR_gitops_repo_token:-}" && -f "$TOKEN_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$TOKEN_FILE"
fi

require_tools
start_log
need_token
warn_if_not_detached

tf_init
clear_stale_lock

# ---------- 1. re-adopt everything kept outside state (IP, data disks, Loki/Tempo buckets) ----------
# Import blocks, not `terraform import`: the CLI import evaluates the whole config with
# unknown values and can fail on unrelated expressions; an import block is part of the
# normal plan, so it either works or fails loudly.
write_kept_imports

# ---------- 2. cluster + node pools first (the Helm/Kubernetes providers need them) ----------
log "creating network, cluster and node pools (~10 min if new)"
tf apply -auto-approve \
  -target=module.platform.google_compute_router_nat.nat \
  -target=module.platform.google_compute_address.ingress \
  -target=module.platform.google_project_iam_member.nodes \
  -target=module.platform.google_container_node_pool.stateful \
  -target=module.platform.google_container_node_pool.apps \
  || die "cluster apply failed: see $LOG_FILE"
ok "cluster ready"
kube_creds
K="kubectl --context $CTX"

# ---------- 2b. kept data disks -> PVs, before any chart or Argo CD app creates its PVCs ----------
log "attaching kept data disks (Prometheus, Grafana, Alertmanager, Postgres, MongoDB)"
tf apply -auto-approve \
  -target=module.platform.google_compute_disk.kept \
  -target=module.platform.kubernetes_persistent_volume_v1.kept \
  || die "kept-disk apply failed: see $LOG_FILE"
ok "kept volumes ready: $($K get pv -l jt-kept=true --no-headers 2>/dev/null | grep -c . || true) PV(s)"

# ---------- 2c. kept TLS certificates, before cert-manager starts ----------
# Terraform-managed namespaces are created by Terraform first (pre-creating them with
# kubectl would make the next apply fail); any other namespace is created by tls_restore.
mapfile -t NS_TARGETS < <(grep -hoE 'resource "kubernetes_namespace(_v1)?" "[A-Za-z0-9_-]+"' "$ROOT"/modules/gke-platform/*.tf \
  | awk -F'"' '{print "-target=module.platform." $2 "." $4}')
if (( ${#NS_TARGETS[@]} > 0 )); then
  tf apply -auto-approve "${NS_TARGETS[@]}" >/dev/null || die "namespace apply failed: see $LOG_FILE"
fi
tls_restore

# PVCs pointing at disks that no longer exist (from a half-finished destroy) block their pods forever
$K get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.csi.volumeHandle}{" "}{.spec.claimRef.namespace}{" "}{.spec.claimRef.name}{"\n"}{end}' 2>/dev/null \
  | while read -r pv handle ns pvc; do
      [[ -z "$handle" ]] && continue
      disk="${handle##*/}"; dzone="$(echo "$handle" | sed -nE 's#.*/zones/([^/]+)/.*#\1#p')"
      if ! gcloud compute disks describe "$disk" --zone "${dzone:-$ZONE}" --project "$PROJECT" >/dev/null 2>&1; then
        warn "volume $ns/$pvc points at a deleted disk: resetting it"
        $K -n "$ns" delete pvc "$pvc" --wait=false >/dev/null 2>&1 || true
        $K -n "$ns" patch pvc "$pvc" -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        $K delete pv "$pv" --wait=false >/dev/null 2>&1 || true
        $K patch pv "$pv" -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        $K -n "$ns" delete pod -l "app.kubernetes.io/instance" --field-selector=status.phase!=Running >/dev/null 2>&1 || true
      fi
    done || true

# ---------- 3. everything else, with self-repair between attempts ----------
for attempt in 1 2 3; do
  log "terraform apply: platform + observability (attempt $attempt)"
  if tf apply -auto-approve; then ok "terraform apply complete"; rm -f "$IMPORT_FILE"; break; fi
  [[ $attempt == 3 ]] && die "apply failed 3 times: see $LOG_FILE"

  warn "apply failed: repairing and retrying"
  clear_stale_lock
  # a Helm release that failed/timed out can't be reinstalled under the same name
  helm --kube-context "$CTX" list -A --failed --pending -o json 2>/dev/null \
    | python3 -c 'import json,sys; [print(r["namespace"], r["name"]) for r in json.load(sys.stdin)]' \
    | while read -r ns name; do warn "uninstalling broken Helm release $ns/$name"; helm --kube-context "$CTX" -n "$ns" uninstall "$name" >/dev/null || true; done || true
  # "already exists" in GCP but not in state -> adopt kept resources again
  write_kept_imports || true
  sleep 60   # also lets fresh IAM bindings propagate (Tempo/Loki bucket access)
done

# ---------- 4. app secret (Argo CD deploys the store; it needs this to start) ----------
# The kept Postgres/MongoDB disks were initialised with these passwords, so the secret
# itself is kept too: a copy lives in Secret Manager and is restored after a rebuild.
$K create namespace jhanvi-trends --dry-run=client -o yaml | $K apply -f - >/dev/null
gcloud services enable secretmanager.googleapis.com --project "$PROJECT" >/dev/null 2>&1 || true
tmp_env="$(umask 077; mktemp)"; trap 'rm -f "$tmp_env"' EXIT

save_secret_to_sm() {   # reads dotenv from $tmp_env
  if sm_secret_exists; then
    gcloud secrets versions add "$APP_SECRET_SM" --project "$PROJECT" --data-file="$tmp_env" >/dev/null
  else
    gcloud secrets create "$APP_SECRET_SM" --project "$PROJECT" --replication-policy=automatic \
      --labels=jt-kept=true --data-file="$tmp_env" >/dev/null
  fi
}

if $K -n jhanvi-trends get secret jhanvi-trends-secrets >/dev/null 2>&1; then
  ok "app secret exists"
  if ! sm_secret_exists; then   # first run with kept data: back up the current passwords
    $K -n jhanvi-trends get secret jhanvi-trends-secrets -o json \
      | python3 -c 'import json,sys,base64; [print(f"{k}={base64.b64decode(v).decode()}") for k,v in json.load(sys.stdin)["data"].items()]' > "$tmp_env"
    save_secret_to_sm && ok "app secret backed up to Secret Manager ($APP_SECRET_SM)"
  fi
elif sm_secret_exists; then
  gcloud secrets versions access latest --secret="$APP_SECRET_SM" --project "$PROJECT" > "$tmp_env"
  $K -n jhanvi-trends create secret generic jhanvi-trends-secrets --from-env-file="$tmp_env" >/dev/null
  ok "app secret restored from Secret Manager (matches the kept database disks)"
else
  if $K -n jhanvi-trends get pvc --no-headers 2>/dev/null | grep -qE '^(data-)?(postgres|mongodb)' \
     && ! $K get pv -l jt-kept=true --no-headers 2>/dev/null | grep -q .; then
    warn "app secret missing but database volumes exist: their old passwords won't match a new secret"
    warn "fix: kubectl --context $CTX -n jhanvi-trends delete pvc -l app.kubernetes.io/name=postgres (and mongodb), then re-run"
  fi
  rand() { openssl rand -base64 48 | tr -d '/+=' | cut -c1-"$1"; }
  printf 'POSTGRES_PASSWORD=%s\nMONGODB_PASSWORD=%s\nJWT_SECRET=%s\n' "$(rand 24)" "$(rand 24)" "$(rand 48)" > "$tmp_env"
  $K -n jhanvi-trends create secret generic jhanvi-trends-secrets --from-env-file="$tmp_env" >/dev/null
  save_secret_to_sm
  ok "app secret created (and saved to Secret Manager)"
fi
rm -f "$tmp_env"

# ---------- 5. wait for Argo CD and the store ----------
$K -n argocd annotate application jhanvi-trends argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
SHOP="$(terraform output -json dns_records | python3 -c 'import json,sys; print([k for k in json.load(sys.stdin) if k.startswith("shop.")][0])')"
log "waiting for https://$SHOP to become healthy (up to 15 min)"
for i in $(seq 1 90); do
  h="$($K -n argocd get application jhanvi-trends -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$SHOP" || true)"
  printf '\r    argo: %-20s  shop: HTTP %s   ' "${h:-pending}" "${code:-000}"
  [[ "$h" == "Synced/Healthy" && "$code" == 200 ]] && { echo; ok "store is live"; break; }
  sleep 10
done
echo

# keep a copy of the (possibly new) certificates, in case the cluster dies before destroy.sh
tls_backup || warn "TLS backup failed (destroy.sh will try again)"

# ---------- 6. your own logins ----------
if [[ -n "${GRAFANA_PASSWORD:-}${PROMETHEUS_PASSWORD:-}${ARGOCD_PASSWORD:-}" ]]; then
  CTX="$CTX" "$ROOT/scripts/set-passwords.sh" "$ENV"
fi
# Grafana keeps its database on a kept disk, so it remembers the admin password from before
# the destroy. Without GRAFANA_PASSWORD, reset it to this run's terraform output so the
# password printed below is always the one that works.
if [[ -z "${GRAFANA_PASSWORD:-}" ]]; then
  $K -n observability rollout status deploy/grafana --timeout=300s >/dev/null 2>&1 || true
  gpw="$(terraform output -raw grafana_admin_password 2>/dev/null || true)"
  if [[ -n "$gpw" ]] && $K -n observability exec deploy/grafana -c grafana -- \
       sh -c 'grafana cli admin reset-admin-password "$1" 2>/dev/null || grafana-cli admin reset-admin-password "$1"' _ "$gpw" >/dev/null 2>&1; then
    ok "grafana admin password synced with terraform output"
  else
    warn "could not sync the grafana admin password; set GRAFANA_PASSWORD in ~/.config/jhanvi-trends/$ENV.env"
  fi
  unset gpw
fi

# ---------- 7. summary ----------
echo
log "$ENV is up"
terraform output -json dns_records | python3 -c 'import json,sys; [print(f"    https://{h}") for h in json.load(sys.stdin)]'
echo "    nodes: $($K get nodes --no-headers | grep -c .)   not-running pods: $($K get pods -A --no-headers | grep -vcE 'Running|Completed' || true)"
[[ -z "${GRAFANA_PASSWORD:-}" ]] && echo "    grafana admin password:    terraform -chdir=envs/$ENV output -raw grafana_admin_password"
[[ -z "${PROMETHEUS_PASSWORD:-}" ]] && echo "    prometheus admin password: terraform -chdir=envs/$ENV output -raw prometheus_basic_auth_password"
[[ -z "${ARGOCD_PASSWORD:-}" ]] && echo "    argocd admin password:     $K -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "    kept data disks:           $(kept_disks | awk '{print $3}' | paste -sd' ' -)"
echo "    stop when done:            scripts/destroy.sh $ENV   (keeps data; add --purge to delete it)"

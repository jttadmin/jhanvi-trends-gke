#!/usr/bin/env bash
# Create (or repair) an environment end to end.
#
#   export TF_VAR_gitops_repo_token=github_pat_...      # read-only token for Argo CD
#   scripts/up.sh dev
#
#   Optional, to set your own logins automatically at the end:
#   export GRAFANA_PASSWORD=... PROMETHEUS_PASSWORD=... ARGOCD_PASSWORD=...
#
# Works from any starting point: nothing built, half destroyed, or already running.
# Safe to re-run.
source "$(dirname "$0")/lib.sh"

load_env "${1:-}"
require_tools
start_log
need_token
warn_if_not_detached

tf_init
clear_stale_lock

# ---------- 1. re-adopt the kept static IP ----------
if ip_exists && ! in_state "$IP_ADDR"; then
  terraform import -input=false "$IP_ADDR" "$IP_ID" >/dev/null && ok "re-adopted static IP $(gcloud compute addresses describe "$IP_NAME" --region "$REGION" --project "$PROJECT" --format='value(address)')"
fi

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
  if tf apply -auto-approve; then ok "terraform apply complete"; break; fi
  [[ $attempt == 3 ]] && die "apply failed 3 times: see $LOG_FILE"

  warn "apply failed: repairing and retrying"
  clear_stale_lock
  # a Helm release that failed/timed out can't be reinstalled under the same name
  helm --kube-context "$CTX" list -A --failed --pending -o json 2>/dev/null \
    | python3 -c 'import json,sys; [print(r["namespace"], r["name"]) for r in json.load(sys.stdin)]' \
    | while read -r ns name; do warn "uninstalling broken Helm release $ns/$name"; helm --kube-context "$CTX" -n "$ns" uninstall "$name" >/dev/null || true; done || true
  # "already exists" in GCP but not in state -> import the IP again (the only resource kept outside state)
  ip_exists && ! in_state "$IP_ADDR" && terraform import -input=false "$IP_ADDR" "$IP_ID" >/dev/null || true
  sleep 60   # also lets fresh IAM bindings propagate (Tempo/Loki bucket access)
done

# ---------- 4. app secret (Argo CD deploys the store; it needs this to start) ----------
$K create namespace jhanvi-trends --dry-run=client -o yaml | $K apply -f - >/dev/null
if ! $K -n jhanvi-trends get secret jhanvi-trends-secrets >/dev/null 2>&1; then
  if $K -n jhanvi-trends get pvc --no-headers 2>/dev/null | grep -qE '^(data-)?(postgres|mongodb)'; then
    warn "app secret missing but database volumes exist: their old passwords won't match a new secret"
    warn "fix: kubectl --context $CTX -n jhanvi-trends delete pvc -l app.kubernetes.io/name=postgres (and mongodb), then re-run"
  fi
  rand() { openssl rand -base64 48 | tr -d '/+=' | cut -c1-"$1"; }
  $K -n jhanvi-trends create secret generic jhanvi-trends-secrets \
    --from-literal=POSTGRES_PASSWORD="$(rand 24)" \
    --from-literal=MONGODB_PASSWORD="$(rand 24)" \
    --from-literal=JWT_SECRET="$(rand 48)" >/dev/null
  ok "app secret created"
else
  ok "app secret exists"
fi

# ---------- 5. wait for Argo CD and the store ----------
$K -n argocd annotate application jhanvi-trends-root argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
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

# ---------- 6. your own logins ----------
if [[ -n "${GRAFANA_PASSWORD:-}${PROMETHEUS_PASSWORD:-}${ARGOCD_PASSWORD:-}" ]]; then
  CTX="$CTX" "$ROOT/scripts/set-passwords.sh" "$ENV"
fi

# ---------- 7. summary ----------
echo
log "$ENV is up"
terraform output -json dns_records | python3 -c 'import json,sys; [print(f"    https://{h}") for h in json.load(sys.stdin)]'
echo "    nodes: $($K get nodes --no-headers | grep -c .)   not-running pods: $($K get pods -A --no-headers | grep -vcE 'Running|Completed' || true)"
[[ -z "${GRAFANA_PASSWORD:-}" ]] && echo "    grafana admin password:    terraform -chdir=envs/$ENV output -raw grafana_admin_password"
[[ -z "${PROMETHEUS_PASSWORD:-}" ]] && echo "    prometheus admin password: terraform -chdir=envs/$ENV output -raw prometheus_basic_auth_password"
[[ -z "${ARGOCD_PASSWORD:-}" ]] && echo "    argocd admin password:     $K -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "    stop when done:            scripts/destroy.sh $ENV"

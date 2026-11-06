#!/usr/bin/env bash
# Bring a paused environment back (~5 min). Restores autoscaling exactly as defined in
# envs/<env>/main.tf, restarts Argo CD sync, and waits until the store answers.
#
#   scripts/resume.sh dev
#
# No Terraform involved. Safe to re-run (also fine on an environment that's already up).
source "$(dirname "$0")/lib.sh"

load_env "${1:-}"
for t in gcloud kubectl; do command -v "$t" >/dev/null || die "missing tool: $t"; done
start_log
cluster_exists || die "cluster $CLUSTER doesn't exist (it was destroyed): use scripts/up.sh $ENV"

# autoscaling limits from envs/<env>/main.tf, falling back to the module defaults
setting() { local v; v="$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" "$ENV_DIR/main.tf" | head -1)"; echo "${v:-$2}"; }
declare -A MIN=([stateful]="$(setting stateful_min_nodes 1)" [apps]="$(setting apps_min_nodes 1)")
declare -A MAX=([stateful]="$(setting stateful_max_nodes 2)" [apps]="$(setting apps_max_nodes 4)")
GC="--cluster $CLUSTER --zone $ZONE --project $PROJECT"

# ---------- 1. data tier first, then apps ----------
for p in stateful apps; do
  start="${MIN[$p]}"; (( start < 1 )) && start=1
  gcloud container clusters resize "$CLUSTER" --node-pool "$p" --num-nodes "$start" --zone "$ZONE" --project "$PROJECT" -q >/dev/null
  gcloud container node-pools update "$p" $GC --enable-autoscaling \
    --min-nodes "${MIN[$p]}" --max-nodes "${MAX[$p]}" -q >/dev/null
  ok "$p: $start node(s) starting, autoscaling ${MIN[$p]}-${MAX[$p]}"
done

kube_creds
K="kubectl --context $CTX"

log "waiting for nodes"
for i in $(seq 1 30); do
  ready="$($K get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | grep -c . || true)"
  [[ "$ready" -ge 2 ]] && break; sleep 10
done
ok "$ready node(s) Ready"

# ---------- 2. let nodes take pods again, and restart Argo CD sync ----------
for n in $($K get nodes -o name); do $K uncordon "$n" >/dev/null 2>&1 || true; done
$K -n argocd scale statefulset argocd-application-controller --replicas=1 >/dev/null 2>&1 \
  && ok "Argo CD sync resumed"
$K -n argocd annotate application jhanvi-trends-root argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

# ---------- 3. wait for the store ----------
SHOP="shop.$(sed -nE 's/^[[:space:]]*domain[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ENV_DIR/main.tf" | head -1)"
log "waiting for https://$SHOP (up to 10 min; order-service is the slowest)"
for i in $(seq 1 60); do
  h="$($K -n argocd get application jhanvi-trends -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$SHOP" || true)"
  printf '\r    argo: %-20s  shop: HTTP %s   ' "${h:-pending}" "${code:-000}"
  [[ "$h" == "Synced/Healthy" && "$code" == 200 ]] && break
  sleep 10
done
echo

echo
not_running="$($K get pods -A --no-headers 2>/dev/null | grep -vcE 'Running|Completed' || true)"
echo "    nodes: $($K get nodes --no-headers | grep -c .)   pods not running yet: $not_running"
if [[ "$code" == 200 ]]; then
  ok "$ENV is back: https://$SHOP"
else
  warn "store not answering yet: check with  kubectl --context $CTX -n jhanvi-trends get pods"
fi
echo "    pause again: scripts/pause.sh $ENV"

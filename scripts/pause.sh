#!/usr/bin/env bash
# Stop every node VM but keep the environment: cluster, data disks, passwords,
# certificates, static IP. While paused it costs ~₹85/day (LB rule + disks + IP).
#
#   scripts/pause.sh dev
#   scripts/resume.sh dev      # back in ~5 min
#
# No Terraform involved (no state, lock or token needed). Safe to re-run.
#
# Why not just "resize to 0":
#   - the cluster autoscaler adds nodes straight back for the evicted (Pending) pods
#     -> autoscaling is switched off first
#   - the frontend's PodDisruptionBudget blocks a normal drain for up to an hour
#     -> nodes are drained with --disable-eviction (pods still shut down gracefully)
#   - Argo CD would try to "heal" what we stop -> its controller is paused too
source "$(dirname "$0")/lib.sh"

load_env "${1:-}"
for t in gcloud kubectl; do command -v "$t" >/dev/null || die "missing tool: $t"; done
start_log
cluster_exists || die "cluster $CLUSTER doesn't exist: nothing to pause (use scripts/up.sh $ENV)"

POOLS="$(gcloud container node-pools list --cluster "$CLUSTER" --zone "$ZONE" --project "$PROJECT" --format='value(name)')"
GC="--cluster $CLUSTER --zone $ZONE --project $PROJECT"

# ---------- 1. no autoscaler: otherwise it re-creates nodes for the Pending pods ----------
for p in $POOLS; do
  gcloud container node-pools update "$p" $GC --no-enable-autoscaling -q >/dev/null
done
ok "autoscaling off: $(echo $POOLS)"

# ---------- 2. graceful drain ----------
if [[ "$(vm_count)" != 0 ]]; then
  kube_creds
  K="kubectl --context $CTX"
  $K -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null 2>&1 \
    && ok "Argo CD sync paused"

  log "draining nodes (pods get up to 60s to shut down cleanly; databases flush to disk)"
  # apps first, databases last, so services stop writing before the data stores go down
  for n in $($K get nodes -l workload=apps -o name) $($K get nodes -l workload!=apps -o name); do
    $K cordon "$n" >/dev/null
    $K drain "$n" --ignore-daemonsets --delete-emptydir-data --disable-eviction --force \
      --grace-period=60 --timeout=5m >/dev/null 2>&1 || warn "drain of $n timed out: continuing"
    echo "    drained ${n#node/}"
  done
fi

# ---------- 3. node pools to 0 ----------
for p in $POOLS; do
  gcloud container clusters resize "$CLUSTER" --node-pool "$p" --num-nodes 0 --zone "$ZONE" --project "$PROJECT" -q >/dev/null
done
ok "node pools resized to 0"

# ---------- 4. verify the VMs are really gone ----------
for i in $(seq 1 30); do [[ "$(vm_count)" == 0 ]] && break; sleep 10; done
if [[ "$(vm_count)" != 0 ]]; then
  warn "$(vm_count) VM(s) still present after 5 min: forcing the instance groups to 0"
  for p in $POOLS; do
    for url in $(gcloud container node-pools describe "$p" $GC --format='value(instanceGroupUrls)' | tr ';' ' '); do
      gcloud compute instance-groups managed resize "${url##*/}" --size 0 --zone "$ZONE" --project "$PROJECT" -q >/dev/null || true
    done
  done
  for i in $(seq 1 18); do [[ "$(vm_count)" == 0 ]] && break; sleep 10; done
fi

echo
if [[ "$(vm_count)" == 0 ]]; then
  ok "$ENV is paused: 0 VMs running. Data, passwords and IP kept. Resume: scripts/resume.sh $ENV"
else
  gcloud compute instances list --project "$PROJECT" --filter="name~^gke-${CLUSTER}-" --format="table(name,status)"
  die "$(vm_count) VM(s) still running: re-run scripts/pause.sh $ENV"
fi

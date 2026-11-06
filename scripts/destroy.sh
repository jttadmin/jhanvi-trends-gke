#!/usr/bin/env bash
# Tear an environment down completely and safely.
#
#   scripts/destroy.sh dev                 # keeps the static IP (DNS stays valid), ~₹20/day
#   scripts/destroy.sh dev --release-ip    # deletes the IP too (DNS must be updated on next up)
#   ASSUME_YES=1 scripts/destroy.sh dev    # no prompts
#
# Safe to re-run: every step checks what's left and skips what's already gone.
#
# Order matters, and this is what went wrong when doing it by hand:
#   1. clear a stale lock (from a killed run) instead of failing
#   2. while the cluster is still alive: delete Argo CD apps, LoadBalancer Services and
#      PVCs, so Kubernetes removes the load balancer and data disks itself
#   3. terraform destroy (retried); if the cluster is already gone, drop the
#      Kubernetes/Helm resources from state first, since there's nothing to connect to
#   4. only once no cluster VMs remain: delete orphaned PVC disks and LB leftovers
#   5. verify 0 VMs, 0 disks, 0 LB rules, and say so loudly
source "$(dirname "$0")/lib.sh"

RELEASE_IP=0
for a in "${@:2}"; do [[ "$a" == --release-ip ]] && RELEASE_IP=1; done

load_env "${1:-}"
require_tools
start_log
need_token optional
warn_if_not_detached
confirm "Destroy EVERYTHING in '$ENV' ($PROJECT)? Store data, metrics, logs, traces are deleted." || exit 1

tf_init
clear_stale_lock

# ---------- 1. keep the IP out of the destroy ----------
if [[ $RELEASE_IP == 0 ]] && in_state "$IP_ADDR"; then
  terraform state rm "$IP_ADDR" >/dev/null && ok "static IP removed from state (will be kept)"
fi

# ---------- 2. in-cluster cleanup while the cluster still exists ----------
if cluster_exists; then
  log "cluster is up: cleaning Kubernetes-owned cloud resources first"
  kube_creds
  K="kubectl --context $CTX"

  # Stop Argo CD from recreating anything we delete
  if $K get ns argocd >/dev/null 2>&1; then
    $K -n argocd scale deploy,statefulset --all --replicas=0 >/dev/null 2>&1 || true
    $K -n argocd delete applications --all --wait=false >/dev/null 2>&1 || true
    for app in $($K -n argocd get applications -o name 2>/dev/null); do
      $K -n argocd patch "$app" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done
    ok "Argo CD stopped"
  fi

  # App workloads (Argo CD-managed, not in Terraform state)
  for ns in $($K get ns -o name | sed 's#namespace/##' | grep -vE '^(kube-.*|default|gke-.*|gmp-.*)$'); do
    $K -n "$ns" scale deploy,statefulset --all --replicas=0 >/dev/null 2>&1 || true
  done
  ok "workloads scaled to 0"

  # LoadBalancer Services -> lets GKE delete the forwarding rule, target pool, firewall rules
  $K get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    | while read -r ns name; do [[ -n "$ns" ]] && $K -n "$ns" delete svc "$name" --wait=false >/dev/null; done || true
  ok "LoadBalancer services deleted"

  # PVCs -> lets the CSI driver delete the disks (reclaimPolicy: Delete)
  log "deleting PVCs (Kubernetes waits for their pods to stop, then deletes the disks)"
  $K delete pvc -A --all --wait=false >/dev/null 2>&1 || true
  for i in $(seq 1 36); do
    n="$($K get pv --no-headers 2>/dev/null | grep -c . || true)"
    [[ "$n" == 0 ]] && break; sleep 5
  done
  [[ "${n:-0}" == 0 ]] && ok "all PVs/disks released" || warn "$n PV(s) still present: their disks are cleaned up in step 4"

  for i in $(seq 1 24); do
    fr="$(gcloud compute forwarding-rules list --project "$PROJECT" --format='value(name)' | grep -c . || true)"
    [[ "$fr" == 0 ]] && break; sleep 5
  done
  [[ "${fr:-0}" == 0 ]] && ok "load balancer removed" || warn "load balancer still deleting: cleaned up in step 4"
else
  log "cluster already gone: dropping Kubernetes/Helm resources from state"
  terraform state list 2>/dev/null | grep -E '\.(helm_release|kubernetes_[a-z0-9_]+)\.' \
    | while read -r r; do terraform state rm "$r" >/dev/null && echo "    state rm $r"; done || true
fi

# ---------- 3. terraform destroy, with retries ----------
for attempt in 1 2 3; do
  log "terraform destroy (attempt $attempt)"
  if tf destroy -auto-approve; then ok "terraform destroy complete"; break; fi
  [[ $attempt == 3 ]] && die "terraform destroy failed 3 times: see $LOG_FILE, then re-run this script"
  warn "destroy failed, retrying in 30s"
  clear_stale_lock; sleep 30
  if ! cluster_exists; then
    terraform state list 2>/dev/null | grep -E '\.(helm_release|kubernetes_[a-z0-9_]+)\.' \
      | while read -r r; do terraform state rm "$r" >/dev/null; done || true
  fi
done

# ---------- 4. leftovers (only once no cluster VMs exist) ----------
for i in $(seq 1 30); do [[ "$(vm_count)" == 0 ]] && break; sleep 10; done
if [[ "$(vm_count)" != 0 ]]; then
  warn "cluster VMs still shutting down: skipping disk cleanup (re-run in a few minutes)"
else
  # PVC disks the CSI driver didn't get to (never boot disks, never attached disks)
  gcloud compute disks list --project "$PROJECT" --filter="name~^pvc- AND -users:*" --format="value(name,zone.basename())" \
    | while read -r d z; do gcloud compute disks delete "$d" --zone "$z" --project "$PROJECT" -q >/dev/null && echo "    deleted disk $d"; done || true

  # LB pieces left by a Service deleted too late (GKE names them a<hash> / k8s-*)
  gcloud compute forwarding-rules list --project "$PROJECT" --format="value(name,region.basename())" \
    | while read -r n r; do gcloud compute forwarding-rules delete "$n" --region "$r" --project "$PROJECT" -q >/dev/null && echo "    deleted forwarding rule $n"; done || true
  gcloud compute target-pools list --project "$PROJECT" --format="value(name,region.basename())" \
    | while read -r n r; do gcloud compute target-pools delete "$n" --region "$r" --project "$PROJECT" -q >/dev/null && echo "    deleted target pool $n"; done || true
  gcloud compute http-health-checks list --project "$PROJECT" --filter="name~^k8s-" --format="value(name)" 2>/dev/null \
    | while read -r n; do gcloud compute http-health-checks delete "$n" --project "$PROJECT" -q >/dev/null && echo "    deleted health check $n"; done || true
  gcloud compute firewall-rules list --project "$PROJECT" --filter="name~^(k8s-|gke-${CLUSTER}-)" --format="value(name)" \
    | while read -r n; do gcloud compute firewall-rules delete "$n" --project "$PROJECT" -q >/dev/null && echo "    deleted firewall rule $n"; done || true

  # if leftover firewall rules blocked the VPC delete, finish it now
  if [[ -n "$(terraform state list 2>/dev/null)" ]]; then
    log "finishing terraform destroy"
    tf destroy -auto-approve || warn "some resources remain: re-run this script"
  fi
fi

# ---------- 5. release the IP if asked ----------
if [[ $RELEASE_IP == 1 ]] && ip_exists; then
  gcloud compute addresses delete "$IP_NAME" --region "$REGION" --project "$PROJECT" -q >/dev/null && ok "static IP released"
fi

# ---------- 6. verify ----------
echo
log "verification"
vms="$(vm_count)"
disks="$(gcloud compute disks list --project "$PROJECT" --format='value(name)' | grep -c . || true)"
lbs="$(gcloud compute forwarding-rules list --project "$PROJECT" --format='value(name)' | grep -c . || true)"
state="$(terraform state list 2>/dev/null | grep -c . || true)"
ip="$(gcloud compute addresses list --project "$PROJECT" --format='value(address,status)' | head -1)"
printf '    VMs: %s   disks: %s   LB rules: %s   terraform state items: %s\n' "$vms" "$disks" "$lbs" "$state"
printf '    static IP: %s\n' "${ip:-none}"

if [[ "$vms" == 0 && "$disks" == 0 && "$lbs" == 0 && "$state" == 0 ]]; then
  ok "$ENV is fully destroyed: nothing is running or billing except the reserved IP${ip:+ ($ip)}"
else
  warn "NOT fully destroyed: re-run 'scripts/destroy.sh $ENV' (it continues where it stopped)"
  exit 1
fi

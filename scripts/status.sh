#!/usr/bin/env bash
# One-screen status of an environment: running / paused / destroyed, and what's billing.
#
#   scripts/status.sh dev
source "$(dirname "$0")/lib.sh"
set +e

load_env "${1:-}" >/dev/null
vms="$(vm_count)"
disks="$(gcloud compute disks list --project "$PROJECT" --format='value(name)' | grep -c .)"
lbs="$(gcloud compute forwarding-rules list --project "$PROJECT" --format='value(name)' | grep -c .)"
ip="$(gcloud compute addresses list --project "$PROJECT" --format='value(address)' | head -1)"

if ! cluster_exists; then
  state="DESTROYED"; cost="~₹0/day (IP reserved: ~₹20/day)"
elif [[ "$vms" == 0 ]]; then
  state="PAUSED"; cost="~₹85/day"
else
  state="RUNNING"; cost="~₹300/day"
fi

printf '%s%s: %s%s   (%s)\n' "$c_bld" "$ENV" "$state" "$c_off" "$cost"
printf '    VMs: %s   disks: %s   LB rules: %s   IP: %s\n' "$vms" "$disks" "$lbs" "${ip:-none}"

if [[ "$state" != DESTROYED ]]; then
  gcloud container node-pools list --cluster "$CLUSTER" --zone "$ZONE" --project "$PROJECT" \
    --format="table[box](name,config.machineType,autoscaling.enabled:label=AUTOSCALE,autoscaling.minNodeCount:label=MIN,autoscaling.maxNodeCount:label=MAX)"
fi
if [[ "$state" == RUNNING ]]; then
  kubectl config get-contexts "$CTX" >/dev/null 2>&1 || kube_creds >/dev/null
  kubectl --context "$CTX" get nodes -L workload
  kubectl --context "$CTX" -n argocd get applications 2>/dev/null
  echo "    pods not running: $(kubectl --context "$CTX" get pods -A --no-headers 2>/dev/null | grep -vcE 'Running|Completed')"
  SHOP="shop.$(sed -nE 's/^[[:space:]]*domain[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ENV_DIR/main.tf" | head -1)"
  echo "    https://$SHOP → HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$SHOP")"
fi

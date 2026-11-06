#!/usr/bin/env bash
# Set your own admin passwords for Grafana, Prometheus (basic auth) and Argo CD.
#
#   scripts/set-passwords.sh dev           # prompts (input hidden)
#   GRAFANA_PASSWORD=.. PROMETHEUS_PASSWORD=.. ARGOCD_PASSWORD=.. scripts/set-passwords.sh dev
#
# Only the ones you give are changed. The user is "admin" on all three.
source "$(dirname "$0")/lib.sh"

load_env "${1:-}"
command -v htpasswd >/dev/null || { log "installing htpasswd (apache2-utils)"; sudo apt-get install -y apache2-utils >/dev/null; }
CTX="${CTX:-gke-$ENV}"
kubectl config get-contexts "$CTX" >/dev/null 2>&1 || kube_creds
K="kubectl --context $CTX"

ask() { local v="$1"; if [[ -z "${!v:-}" && -t 0 ]]; then read -rsp "$2 (empty = keep): " "$v"; echo; fi; }
ask GRAFANA_PASSWORD    "New Grafana password"
ask PROMETHEUS_PASSWORD "New Prometheus password"
ask ARGOCD_PASSWORD     "New Argo CD password"

if [[ -n "${GRAFANA_PASSWORD:-}" ]]; then
  $K -n observability exec deploy/grafana -c grafana -- grafana cli admin reset-admin-password "$GRAFANA_PASSWORD" >/dev/null
  ok "Grafana password set"
fi

if [[ -n "${PROMETHEUS_PASSWORD:-}" ]]; then
  $K -n observability create secret generic prometheus-basic-auth \
    --from-literal=users="$(htpasswd -nbB admin "$PROMETHEUS_PASSWORD")" --dry-run=client -o yaml | $K apply -f - >/dev/null
  ok "Prometheus password set"
fi

if [[ -n "${ARGOCD_PASSWORD:-}" ]]; then
  hash="$(htpasswd -nbBC 10 "" "$ARGOCD_PASSWORD" | tr -d ':\n' | sed 's/^\$2y/$2a/')"
  $K -n argocd patch secret argocd-secret -p \
    "{\"stringData\": {\"admin.password\": \"$hash\", \"admin.passwordMtime\": \"$(date -u +%FT%TZ)\"}}" >/dev/null
  $K -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null
  ok "Argo CD password set"
fi

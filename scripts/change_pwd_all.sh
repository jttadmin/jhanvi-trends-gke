command -v htpasswd >/dev/null || sudo apt-get install -y apache2-utils >/dev/null

read -rsp "New Grafana password: "    GPW; echo
read -rsp "New Prometheus password: " PPW; echo
read -rsp "New Argo CD password: "    APW; echo

# Grafana
kubectl --context gke-dev -n observability exec deploy/grafana -c grafana -- grafana cli admin reset-admin-password "$GPW"

# Prometheus (prom.bhumaji.com)
kubectl --context gke-dev -n observability create secret generic prometheus-basic-auth \
  --from-literal=users="$(htpasswd -nbB admin "$PPW")" --dry-run=client -o yaml | kubectl --context gke-dev apply -f -

# Argo CD
HASH=$(htpasswd -nbBC 10 "" "$APW" | tr -d ':\n' | sed 's/^\$2y/$2a/')
kubectl --context gke-dev -n argocd patch secret argocd-secret -p \
  "{\"stringData\": {\"admin.password\": \"$HASH\", \"admin.passwordMtime\": \"$(date -u +%FT%TZ)\"}}"
kubectl --context gke-dev -n argocd delete secret argocd-initial-admin-secret --ignore-not-found

unset GPW PPW APW HASH
echo "Done. User is 'admin' on all three."

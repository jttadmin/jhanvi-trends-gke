# Shared helpers for up.sh / destroy.sh / set-passwords.sh. Source, don't run.
# shellcheck shell=bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_bld=$'\e[1m'; c_off=$'\e[0m'
log()  { printf '%s==>%s %s\n' "$c_bld" "$c_off" "$*"; }
ok()   { printf '%s ✔ %s%s\n' "$c_grn" "$*" "$c_off"; }
warn() { printf '%s ! %s%s\n' "$c_ylw" "$*" "$c_off" >&2; }
die()  { printf '%s ✘ %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }

# ---------- environment ----------
load_env() {
  ENV="${1:-}"
  [[ -n "$ENV" ]] || die "usage: $0 <dev|stage|prod>"
  ENV_DIR="$ROOT/envs/$ENV"
  [[ -f "$ENV_DIR/main.tf" ]] || die "no such environment: $ENV_DIR"

  PROJECT="$(sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ENV_DIR/main.tf" | head -1)"
  REGION="$(sed -nE 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ENV_DIR/main.tf" | head -1)"
  STATE_BUCKET="$(sed -nE 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ENV_DIR/versions.tf" | head -1)"
  STATE_PREFIX="$(sed -nE 's/^[[:space:]]*prefix[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$ENV_DIR/versions.tf" | head -1)"
  [[ -n "$PROJECT" && -n "$REGION" && -n "$STATE_BUCKET" ]] || die "could not read project/region/bucket from $ENV_DIR"

  ZONE="${REGION}-a"
  CLUSTER="jhanvi-trends-gke"
  IP_NAME="${CLUSTER}-ingress-ip"
  IP_ADDR="module.platform.google_compute_address.ingress"
  IP_ID="projects/$PROJECT/regions/$REGION/addresses/$IP_NAME"
  CTX="gke-$ENV"

  # Kept data (survives destroy.sh; see modules/gke-platform/persistence.tf)
  KEPT_BUCKETS=("${PROJECT}-${CLUSTER}-loki" "${PROJECT}-${CLUSTER}-tempo")
  KEPT_BUCKET_ADDRS=("module.platform.google_storage_bucket.loki" "module.platform.google_storage_bucket.tempo")
  APP_SECRET_SM="jhanvi-trends-app-secrets"    # Secret Manager copy of the app's DB passwords / JWT secret
  IMPORT_FILE="$ENV_DIR/imports.auto.tf"
  LOG_FILE="$ROOT/.logs/${ENV}-$(date +%Y%m%d-%H%M%S)-$(basename "$0" .sh).log"
  mkdir -p "$ROOT/.logs"

  cd "$ENV_DIR"
  log "env=$ENV  project=$PROJECT  cluster=$CLUSTER ($ZONE)"
}

require_tools() {
  local t; for t in terraform gcloud kubectl helm; do command -v "$t" >/dev/null || die "missing tool: $t"; done
  gcloud auth application-default print-access-token >/dev/null 2>&1 \
    || die "no application-default credentials: run 'gcloud auth application-default login'"
}

# Everything after this line is also written to the log file.
start_log() { exec > >(tee -a "$LOG_FILE") 2>&1; log "log: $LOG_FILE"; }

# A dropped SSH session killed last night's destroy halfway. Warn if not in tmux/screen.
warn_if_not_detached() {
  if [[ -z "${TMUX:-}${STY:-}" && -t 0 ]]; then
    warn "not inside tmux/screen: if your SSH session drops, this run stops halfway."
    warn "safer:  tmux new -s infra   then run the script again inside it."
    [[ "${ASSUME_YES:-}" == 1 ]] || { read -r -p "Continue anyway? [y/N] " a; [[ "$a" == y ]] || exit 1; }
  fi
}

confirm() {
  [[ "${ASSUME_YES:-}" == 1 ]] && return 0
  read -r -p "$1 [y/N] " a; [[ "$a" == y ]]
}

# ---------- terraform state ----------
tf() { terraform "$@" -input=false -lock-timeout=60s; }

tf_init() { terraform init -input=false -upgrade=false >/dev/null || die "terraform init failed"; ok "terraform init"; }

# Remove a lock left by a run that was killed (Ctrl+C, SSH drop). Never touches a lock
# held by a terraform process that is still running on this machine.
clear_stale_lock() {
  local lock="gs://${STATE_BUCKET}/${STATE_PREFIX}/default.tflock" info id
  info="$(gcloud storage cat "$lock" 2>/dev/null)" || { ok "no state lock"; return 0; }
  id="$(printf '%s' "$info" | sed -nE 's/.*"ID":[[:space:]]*"([^"]+)".*/\1/p')"
  if pgrep -x terraform >/dev/null; then
    die "state is locked (ID $id) and a terraform process is running here: let it finish, or stop it first"
  fi
  warn "removing stale state lock $id"
  printf '%s\n' "$info" | sed 's/^/    /'
  terraform force-unlock -force "$id" >/dev/null || gcloud storage rm "$lock" --quiet
  ok "stale lock removed"
}

in_state() { terraform state list 2>/dev/null | grep -qxF "$1"; }

# ---------- GCP lookups ----------
cluster_exists() { gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1; }
ip_exists()      { gcloud compute addresses describe "$IP_NAME" --region "$REGION" --project "$PROJECT" >/dev/null 2>&1; }
vm_count()       { gcloud compute instances list --project "$PROJECT" --filter="name~^gke-${CLUSTER}-" --format="value(name)" | grep -c . || true; }

# ---------- kept data: disks, buckets, app secret ----------
# "name zone key" for every kept disk that exists in GCP
kept_disks()    { gcloud compute disks list --project "$PROJECT" --filter="labels.jt-kept=true" --format="value(name,zone.basename(),labels.jt-key)" 2>/dev/null || true; }
bucket_exists() { gcloud storage buckets describe "gs://$1" --project "$PROJECT" >/dev/null 2>&1; }
sm_secret_exists() { gcloud secrets describe "$APP_SECRET_SM" --project "$PROJECT" >/dev/null 2>&1; }

# Terraform addresses kept outside `terraform destroy`
kept_state_addrs() {
  terraform state list 2>/dev/null | grep -E '^module\.platform\.(google_compute_disk\.kept\[|google_storage_bucket\.(loki|tempo)$)' || true
}

# Write import blocks for everything kept in GCP but missing from state (IP, buckets, disks).
# Terraform adopts them during the normal apply; nothing is recreated.
write_kept_imports() {
  local st n=0 name zone key i
  st="$(terraform state list 2>/dev/null || true)"
  has() { grep -qxF "$1" <<<"$st"; }
  : > "$IMPORT_FILE.tmp"
  emit() { printf 'import {\n  to = %s\n  id = "%s"\n}\n\n' "$1" "$2" >> "$IMPORT_FILE.tmp"; n=$((n+1)); }

  if ip_exists && ! has "$IP_ADDR"; then emit "$IP_ADDR" "$IP_ID"; fi
  for i in "${!KEPT_BUCKETS[@]}"; do
    if ! has "${KEPT_BUCKET_ADDRS[$i]}" && bucket_exists "${KEPT_BUCKETS[$i]}"; then
      emit "${KEPT_BUCKET_ADDRS[$i]}" "${KEPT_BUCKETS[$i]}"
    fi
  done
  while read -r name zone key; do
    [[ -z "$name" ]] && continue
    local addr="module.platform.google_compute_disk.kept[\"$key\"]"
    has "$addr" || emit "$addr" "projects/$PROJECT/zones/$zone/disks/$name"
  done < <(kept_disks)

  if (( n > 0 )); then
    { echo "# generated by scripts/up.sh: re-adopts data kept outside state. Safe to delete."; echo; cat "$IMPORT_FILE.tmp"; } > "$IMPORT_FILE"
    ok "re-adopting $n kept resource(s): $(grep -c 'google_compute_disk' "$IMPORT_FILE" || true) disk(s), buckets/IP as needed"
  else
    rm -f "$IMPORT_FILE"
  fi
  rm -f "$IMPORT_FILE.tmp"
}

# ---------- kept TLS certificates (Let's Encrypt allows 5 duplicate certs per week) ----------
# Every cert-manager TLS secret is copied to Secret Manager (one secret each, labelled
# jt-tls=true) and put back on a fresh cluster before cert-manager runs, so a rebuild
# reuses the certificate instead of requesting a new one. Needs $K (kubectl --context).
tls_backup() {
  local dir f id n=0
  gcloud services enable secretmanager.googleapis.com --project "$PROJECT" >/dev/null 2>&1 || true
  dir="$(umask 077; mktemp -d)"
  $K get secrets -A -o json 2>/dev/null | python3 -c '
import json, os, sys
out = sys.argv[1]
for s in json.load(sys.stdin)["items"]:
    m, a = s["metadata"], s["metadata"].get("annotations") or {}
    if s.get("type") != "kubernetes.io/tls" or "cert-manager.io/certificate-name" not in a:
        continue
    if not (s.get("data") or {}).get("tls.crt"):
        continue  # not issued yet
    obj = {"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls",
           "metadata": {"name": m["name"], "namespace": m["namespace"],
                        "labels": m.get("labels") or {},
                        "annotations": {k: v for k, v in a.items() if k.startswith("cert-manager.io/")}},
           "data": s["data"]}
    fn = (m["namespace"] + "--" + m["name"]).replace(".", "_")
    with open(os.path.join(out, fn + ".json"), "w") as fh:
        json.dump(obj, fh, sort_keys=True)
' "$dir" || { rm -rf "$dir"; warn "TLS backup: could not read secrets"; return 0; }

  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    id="jt-tls--$(basename "$f" .json)"
    if gcloud secrets describe "$id" --project "$PROJECT" >/dev/null 2>&1; then
      if ! cmp -s "$f" <(gcloud secrets versions access latest --secret="$id" --project "$PROJECT" 2>/dev/null); then
        gcloud secrets versions add "$id" --project "$PROJECT" --data-file="$f" >/dev/null
        # keep only the newest version (each enabled version is billed)
        gcloud secrets versions list "$id" --project "$PROJECT" --filter="state=ENABLED" \
            --sort-by=~createTime --format="value(name.basename())" | tail -n +2 \
          | while read -r v; do gcloud secrets versions destroy "$v" --secret="$id" --project "$PROJECT" --quiet >/dev/null 2>&1 || true; done
      fi
    else
      gcloud secrets create "$id" --project "$PROJECT" --replication-policy=automatic \
        --labels=jt-kept=true,jt-tls=true --data-file="$f" >/dev/null
    fi
    n=$((n+1))
  done
  rm -rf "$dir"
  ok "TLS certificates backed up to Secret Manager: $n"
}

tls_restore() {
  local tmp id ns name n=0
  tmp="$(umask 077; mktemp)"
  while read -r id; do
    [[ -z "$id" ]] && continue
    gcloud secrets versions access latest --secret="$id" --project "$PROJECT" > "$tmp" 2>/dev/null || continue
    read -r ns name < <(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["metadata"]; print(m["namespace"], m["name"])' "$tmp")
    $K get namespace "$ns" >/dev/null 2>&1 || $K create namespace "$ns" >/dev/null
    $K -n "$ns" get secret "$name" >/dev/null 2>&1 && continue   # never overwrite a live cert
    $K apply -f "$tmp" >/dev/null && n=$((n+1))
  done < <(gcloud secrets list --project "$PROJECT" --filter="labels.jt-tls=true" --format="value(name.basename())" 2>/dev/null || true)
  rm -f "$tmp"
  if (( n > 0 )); then ok "restored $n TLS certificate(s): no new Let's Encrypt request needed"; fi
}

kube_creds() {
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null
  local long="gke_${PROJECT}_${ZONE}_${CLUSTER}"
  kubectl config delete-context "$CTX" >/dev/null 2>&1 || true
  kubectl config rename-context "$long" "$CTX" >/dev/null
  ok "kubectl context: $CTX"
}

# ---------- gitops token ----------
need_token() {
  if [[ -z "${TF_VAR_gitops_repo_token:-}" ]]; then
    if [[ "${1:-}" == optional ]]; then
      export TF_VAR_gitops_repo_token="unused-during-destroy"
    else
      die "TF_VAR_gitops_repo_token is not set (GitHub read-only token for Argo CD)"
    fi
  elif [[ "$TF_VAR_gitops_repo_token" == github_pat_xxx* || "$TF_VAR_gitops_repo_token" == *PASTE* ]]; then
    die "TF_VAR_gitops_repo_token is still the placeholder text"
  fi
}

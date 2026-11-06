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

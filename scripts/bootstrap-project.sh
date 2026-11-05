#!/usr/bin/env bash
# One-time setup of a GCP project for an environment, before its first `terraform apply`.
#
#   scripts/bootstrap-project.sh <env>            # env = dev | stage | prod
#
# Reads the project ID from envs/<env>/main.tf, then:
#   creates the project (if missing) -> links billing -> enables base APIs
#   -> creates the versioned Terraform state bucket.
# Safe to re-run.
set -euo pipefail

ENV="${1:?usage: $0 <dev|stage|prod>}"
BILLING_ACCOUNT="${BILLING_ACCOUNT:?set BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX}"
REGION="asia-south1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/envs/$ENV/main.tf"

[[ -f "$MAIN" ]] || { echo "No $MAIN"; exit 1; }
PROJECT="$(sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$MAIN" | head -1)"
[[ -n "$PROJECT" ]] || { echo "Could not read project_id from $MAIN"; exit 1; }

echo "Environment: $ENV"
echo "Project:     $PROJECT"
echo "Billing:     $BILLING_ACCOUNT"
read -r -p "Continue? [y/N] " ok; [[ "$ok" == "y" ]] || exit 1

if ! gcloud projects describe "$PROJECT" >/dev/null 2>&1; then
  gcloud projects create "$PROJECT" --name="Jhanvi Trends ${ENV}"
else
  echo "Project exists, skipping create."
fi

gcloud billing projects link "$PROJECT" --billing-account="$BILLING_ACCOUNT" >/dev/null
echo "Billing enabled: $(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)')"

gcloud services enable --project "$PROJECT" \
  serviceusage.googleapis.com cloudresourcemanager.googleapis.com \
  compute.googleapis.com container.googleapis.com iam.googleapis.com storage.googleapis.com

BUCKET="gs://${PROJECT}-tfstate"
if ! gcloud storage buckets describe "$BUCKET" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud storage buckets create "$BUCKET" --project "$PROJECT" --location="$REGION" --uniform-bucket-level-access
fi
gcloud storage buckets update "$BUCKET" --versioning >/dev/null

echo
echo "Quota check (need CPUS >= 28, INSTANCES >= 8, IN_USE_ADDRESSES >= 2):"
gcloud compute regions describe "$REGION" --project "$PROJECT" --flatten=quotas \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  | grep -E "^CPUS |^INSTANCES |IN_USE_ADDRESSES|SSD_TOTAL_GB" || true

echo
echo "Done. Next:"
echo "  cd envs/$ENV && terraform init && terraform plan"

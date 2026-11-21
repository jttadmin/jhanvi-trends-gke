#!/usr/bin/env bash
# Create or update a monthly GCP budget for one environment's project, with e-mail alerts
# to the billing account admins at 50%, 90% and 100% of actual spend and 100% of forecast.
#
#   scripts/budget.sh dev 3000          # ₹3000/month (the billing account's currency is used)
#   scripts/budget.sh prod 15000
#
# Run it yourself (not from CI): budgets live on the billing account, which needs the
# "Billing Account Costs Manager" (or Administrator) role. Safe to re-run: updates the amount.
# A budget only ALERTS; it never stops spending.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV="${1:?usage: scripts/budget.sh <dev|stage|prod> <monthly amount>}"
AMOUNT="${2:?usage: scripts/budget.sh <dev|stage|prod> <monthly amount>}"
[[ "$AMOUNT" =~ ^[0-9]+$ ]] || { echo "amount must be a whole number, e.g. 3000"; exit 1; }

MAIN="envs/$ENV/main.tf"
PROJECT="$(sed -n 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$MAIN" | head -1)"
[[ -n "$PROJECT" ]] || { echo "Could not read project_id from $MAIN"; exit 1; }

BILLING="$(gcloud billing projects describe "$PROJECT" --format='value(billingAccountName)')"
BILLING="${BILLING#billingAccounts/}"
[[ -n "$BILLING" ]] || { echo "$PROJECT has no billing account linked"; exit 1; }
CURRENCY="$(gcloud billing accounts describe "$BILLING" --format='value(currencyCode)')"
NAME="jhanvi-trends-$ENV"

gcloud services enable billingbudgets.googleapis.com --project "$PROJECT" >/dev/null

existing="$(gcloud billing budgets list --billing-account="$BILLING" \
  --filter="displayName=$NAME" --format='value(name)' 2>/dev/null | head -1)"

args=(--budget-amount="${AMOUNT}${CURRENCY}"
      --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0
      --threshold-rule=percent=1.0,basis=forecasted-spend)

if [[ -n "$existing" ]]; then
  gcloud billing budgets update "$existing" --billing-account="$BILLING" --clear-threshold-rules "${args[@]}" >/dev/null
  echo "Updated budget $NAME: ${AMOUNT} ${CURRENCY}/month for $PROJECT"
else
  gcloud billing budgets create --billing-account="$BILLING" --display-name="$NAME" \
    --filter-projects="projects/$PROJECT" "${args[@]}" >/dev/null
  echo "Created budget $NAME: ${AMOUNT} ${CURRENCY}/month for $PROJECT"
fi
echo "Alerts go by e-mail to the billing account's admins at 50%, 90%, 100% (actual) and 100% (forecast)."

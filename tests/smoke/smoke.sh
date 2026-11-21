#!/usr/bin/env bash
# Smoke test for Jhanvi Trends: "is the deployment alive and wired up?"
# Runs in ~10s, touches every backing service once through the frontend BFF.
#
#   BASE_URL=https://shop.bhumaji.com ./tests/smoke/smoke.sh
#   SMOKE_CHECKOUT=1 ./tests/smoke/smoke.sh      # also places one real order (exercises order/payment/inventory/Kafka)
#
# Exit code 0 = all checks passed, 1 = at least one failed. Needs: bash, curl, jq.
set -uo pipefail

BASE_URL="${BASE_URL:-https://shop.bhumaji.com}"
BASE_URL="${BASE_URL%/}"
TIMEOUT="${TIMEOUT:-10}"
SMOKE_CHECKOUT="${SMOKE_CHECKOUT:-0}"
RETRIES="${RETRIES:-3}"   # retries per check, helps right after an Argo CD sync

command -v jq >/dev/null || { echo "jq is required"; exit 2; }

PASS=0; FAIL=0; TOKEN=""
BODY_FILE="$(mktemp)"; trap 'rm -f "$BODY_FILE"' EXIT
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

# req METHOD PATH [JSON_BODY] -> sets $STATUS, body in $BODY_FILE
req() {
  local method="$1" path="$2" data="${3:-}" args=(-sS -o "$BODY_FILE" -w '%{http_code}' -m "$TIMEOUT" -X "$method")
  [[ -n "$TOKEN" ]] && args+=(-H "authorization: Bearer $TOKEN")
  [[ -n "$data" ]] && args+=(-H 'content-type: application/json' --data "$data")
  STATUS="$(curl "${args[@]}" "$BASE_URL$path" 2>/dev/null || echo 000)"
}

# check NAME EXPECTED_STATUS METHOD PATH [BODY] [JQ_ASSERTION]
check() {
  local name="$1" want="$2" method="$3" path="$4" data="${5:-}" assertion="${6:-}" i
  for ((i = 1; i <= RETRIES; i++)); do
    req "$method" "$path" "$data"
    if [[ "$STATUS" == "$want" ]] && { [[ -z "$assertion" ]] || jq -e "$assertion" "$BODY_FILE" >/dev/null 2>&1; }; then
      green "  PASS  $name ($STATUS)"; PASS=$((PASS + 1)); return 0
    fi
    sleep 2
  done
  red "  FAIL  $name (got $STATUS, want $want${assertion:+, assert: $assertion})"
  head -c 300 "$BODY_FILE"; echo
  FAIL=$((FAIL + 1)); return 1
}

echo "Smoke testing $BASE_URL"

echo "[platform]"
check "frontend liveness"        200 GET /healthz  "" '.status == "ok"'
check "frontend readiness"       200 GET /readyz   "" '.status == "ready"'
req GET /; if [[ "$STATUS" == 200 ]] && grep -qi '<html' "$BODY_FILE"; then green "  PASS  storefront page (200)"; PASS=$((PASS+1)); else red "  FAIL  storefront page ($STATUS)"; FAIL=$((FAIL+1)); fi

echo "[catalog-service + MongoDB]"
check "categories"               200 GET /api/categories    "" 'length > 0'
check "product list"             200 GET "/api/products?limit=5" "" '.items | length > 0'
check "product image"            200 GET /api/images/1.svg

echo "[inventory-service + PostgreSQL]"
check "product detail + stock"   200 GET /api/products/1    "" '.id == 1 and (.stock != null)'

echo "[user-service + PostgreSQL]"
EMAIL="smoke-$(date +%s)-$RANDOM@smoke.jhanvi-trends.local"
if check "register"              201 POST /api/auth/register "{\"name\":\"Smoke Test\",\"email\":\"$EMAIL\",\"password\":\"smoke12345\"}" '.token | length > 0'; then
  TOKEN="$(jq -r .token "$BODY_FILE")"
fi
check "login"                    200 POST /api/auth/login "{\"email\":\"$EMAIL\",\"password\":\"smoke12345\"}" '.token | length > 0'
check "who am I (JWT)"           200 GET /api/me "" ".email == \"$EMAIL\""

echo "[cart-service + Valkey]"
check "add to cart"              201 POST /api/cart/items '{"productId":1,"quantity":1}' '.itemCount == 1'
check "read cart"                200 GET /api/cart "" '.items[0].productId == 1'

if [[ "$SMOKE_CHECKOUT" == 1 ]]; then
  echo "[order-service + payment + Kafka]"
  ADDR='{"shippingAddress":{"fullName":"Smoke Test","line1":"12 MG Road","city":"Bengaluru","pincode":"560001","state":"Karnataka"}}'
  req POST /api/checkout "$ADDR"
  # 402 (mock card decline) and 409 (out of stock) still prove the whole saga ran end to end.
  if [[ "$STATUS" =~ ^(201|402|409)$ ]]; then green "  PASS  checkout ($STATUS)"; PASS=$((PASS+1)); else red "  FAIL  checkout ($STATUS)"; head -c 300 "$BODY_FILE"; echo; FAIL=$((FAIL+1)); fi
  check "order history"          200 GET /api/orders "" 'type == "array"'
else
  check "remove from cart"       200 DELETE /api/cart/items/1 "" '.itemCount == 0'
fi

echo
echo "Smoke result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

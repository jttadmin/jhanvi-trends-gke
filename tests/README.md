# Jhanvi Trends tests

All suites hit the public frontend BFF (`/api/*`), the only service behind the ingress, so every test runs through the real path: Traefik → frontend → user/catalog/cart/inventory/order/payment → Postgres/Mongo/Valkey/Kafka.

| Suite | Tool | Question it answers | Time | When to run |
|---|---|---|---|---|
| **Smoke** `tests/smoke/smoke.sh` | bash + curl + jq | Is the deployment alive, and is every backing service wired up? | ~10 s | After every Argo CD sync / cluster restart |
| **Functional** `tests/functional/` | pytest + requests | Does each feature behave correctly, error paths included? (44 tests) | ~1 min | After deploys, before a release |
| **Load** `tests/k6/load.js` | k6 | At normal traffic (50 shoppers), do we meet the latency/error SLO? | ~13 min | Before a release, after perf-related changes |
| **Stress** `tests/k6/stress.js` | k6 | Where's the breaking point, does HPA scale, and does it recover? | ~24 min | Occasionally, and after you change resources or HPA |

Every suite reads `BASE_URL` (default `https://shop.bhumaji.com`, the GKE dev store). For stage use `BASE_URL=https://shop.stage.bhumaji.com`. To test without the ingress: `kubectl -n jhanvi-trends port-forward svc/frontend 8080:8080` and use `BASE_URL=http://localhost:8080`.

## Smoke

```bash
./tests/smoke/smoke.sh
SMOKE_CHECKOUT=1 ./tests/smoke/smoke.sh   # also places one order (order + payment + inventory + Kafka)
```
It checks health/readiness, the storefront page, catalog, product detail + stock, image, register/login/`/me`, add/read cart, and optionally checkout. It retries each check 3× (`RETRIES`) so it tolerates pods that are still starting.

## Functional

```bash
pip install -r tests/functional/requirements.txt
pytest tests/functional -v
pytest tests/functional -v -k "Cart or Checkout"   # just some areas
```
Covered: auth (register, duplicate email, validation, login, bad/missing JWT, admin API blocked for customers), catalog (shape, pagination, sorting, search, category counts, detail + stock, 404, images), cart (accumulate, update, qty 0 removes, delete, invalid qty, unknown product, per-user isolation), checkout (empty cart, required address fields, full order flow + cart cleared + order privacy, client cannot set prices).

## Load and stress (k6)

Install k6: https://grafana.com/docs/k6/latest/set-up/install-k6/ (or `choco install k6` / `winget install k6` on Windows).

```bash
k6 run tests/k6/load.js                                   # 50 VUs, 2m warm-up + 10m steady + 1m down
k6 run -e VUS=20 -e DURATION=5m tests/k6/load.js          # cheaper dev-cluster run
k6 run tests/k6/stress.js                                 # steps 50 → 100 → 200 → 400 VUs, then recovery
k6 run -e MAX_VUS=200 -e THINK_TIME=0 tests/k6/stress.js  # fewer VUs, no think time
```

Traffic mix: 50% browse, 20% search/category, 20% add to cart, 10% checkout. **402 (mock card decline) and 409 (out of stock) count as successes**, because they're expected business outcomes. They're tracked separately as `checkout_payment_declined` / `checkout_out_of_stock`.

Load SLO thresholds (the run fails if any is missed): errors < 1%, p95 < 500 ms, p99 < 1.5 s, product list p95 < 300 ms, checkout p95 < 2 s.

During stress runs, watch:
```bash
kubectl get hpa -n jhanvi-trends -w
kubectl top pods -n jhanvi-trends
```
Also watch the Grafana **Jhanvi Trends / Service Overview** dashboard. The stress test aborts by itself if errors stay above 20% for a minute.

### Notes
- Every k6 VU, smoke run and functional test **registers a new user**, and checkouts **use up inventory**. After big runs, expect more 409s until stock is topped up through the admin panel.
- Load and stress traffic will **trigger your PrometheusRules** (p95 latency, error ratio, low stock). That's expected.
- Stress runs make HPA add pods, which can make the GKE node pool scale up (and cost money). Run them on purpose on dev or stage, not on a schedule. The workflow refuses load/stress against prod.
- To exercise failure handling, change the payment chaos knobs (cluster-internal only): `kubectl -n jhanvi-trends port-forward svc/payment-service 8081:8080` then `curl -XPOST localhost:8081/chaos -H 'content-type: application/json' -d '{"failureRate":0.3,"latencyMs":800}'`.

## CI

`.github/workflows/tests.yaml`: Actions → **tests** → Run workflow → pick the suite (`smoke | functional | load | stress`) and the environment (`dev | stage | prod`). Load and stress are blocked on prod. Reports are uploaded as build artifacts.

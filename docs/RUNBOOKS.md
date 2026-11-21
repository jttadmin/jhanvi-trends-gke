# Runbooks

Every Jhanvi Trends alert links here (`runbook_url`). Each section says what the alert means, how to confirm it and what to do. Commands assume `kubectl --context gke-<env> -n jhanvi-trends`. In the examples below, `k` stands for that.

Useful everywhere:
- Grafana → **Jhanvi Trends / Service Overview** for RED metrics per service; **Explore → Loki** with `{namespace="jhanvi-trends", app="<service>"}`, then click a `trace_id` to open the trace in Tempo.
- Recent deploys: `k -n argocd get application jhanvi-trends -o jsonpath='{.status.history[-3:]}'` or the Argo CD UI. If an alert started right after a deploy, **roll back first** by reverting the PR (or the dev tag-bump commit), and investigate afterwards.

---

## JhanviTrendsErrorBudgetFastBurn
**Meaning:** the storefront API (frontend) is failing so often that the 30-day availability budget (default 99.5%) would be used up in about 2 days. This is the page-worthy SLO alert.
**Confirm:** Grafana error ratio by `job`; frontend 5xx often come from a downstream service. Check which upstream the frontend logs blame (`upstream ... unavailable`).
**Act:** roll back a recent deploy; otherwise follow the runbook of the failing downstream service (ServiceDown, HighErrorRate). Post-incident: note how much budget was used.

## JhanviTrendsErrorBudgetSlowBurn
**Meaning:** a lower but steady error rate (budget gone in ~5 days). Not urgent, but don't ignore it.
**Act:** find the endpoint with errors (`uri` label), open a ticket, and fix it within the week. Consider pausing risky releases until it's fixed.

## JhanviTrendsLatencyBudgetFastBurn
**Meaning:** too many requests are slower than the latency objective (default: 99% under 1 s).
**Confirm:** p95/p99 by service in Grafana, then a slow trace in Tempo: which span is slow?
**Act:** common causes are payment-service chaos latency (`GET /chaos`), the HPA at max replicas (`k get hpa`), a node under CPU pressure (`kubectl top nodes`), or a cold JVM after a restart. Scale up or roll back as needed.

## JhanviTrendsHighErrorRate
**Meaning:** one service returns more than 5% 5xx for 5 minutes.
**Confirm:** `k logs deploy/<service> --since=15m | grep -i error`; check its datastore (readyz checks it).
**Act:** restart only if logs show a stuck process (`k rollout restart deploy/<service>`); roll back if it started with a deploy; fix the dependency if it's a database/Kafka problem.

## JhanviTrendsHighLatency
**Meaning:** one service's p95 is above 1 s for 10 minutes.
**Act:** same steps as LatencyBudgetFastBurn, but for that service only.

## JhanviTrendsPaymentDeclineSpike
**Meaning:** more than 20% of payments are declined.
**Confirm:** `k port-forward svc/payment-service 8081:8080` then `curl localhost:8081/chaos`. A high `failureRate` means someone is rehearsing.
**Act:** reset with `curl -XPOST localhost:8081/chaos -H 'content-type: application/json' -d '{"failureRate":0.05,"latencyMs":150}'`. In real life, contact the payment provider.

## JhanviTrendsNoOrders
**Meaning:** customers are checking out but no order is confirmed in 30 minutes: a silent business outage.
**Confirm:** order-service logs for the checkout saga (`reservation`, `payment`); inventory-service and payment-service health; Postgres `orders` database.
**Act:** treat as critical. Roll back recent order/inventory/payment deploys first.

## JhanviTrendsLowStock
**Meaning:** more than 3 products have fewer than 10 units.
**Act:** restock in the admin panel (Products → stock), or `POST /api/admin/stock/<id>/adjust`. In dev, load tests use up stock: this is expected after big runs.

## JhanviTrendsNotificationBacklog
**Meaning:** notification-service is more than 100 messages behind on `order-events`.
**Confirm:** `k get pods -l app.kubernetes.io/name=notification-service`, its logs, and the Kafka pod.
**Act:** restart notification-service if stuck; check Kafka disk/health. No orders are lost: the consumer group resumes from its offset.

## JhanviTrendsServiceDown
**Meaning:** Prometheus can't scrape a pod for 3 minutes.
**Confirm:** `k get pods -o wide`, `k describe pod <pod>` (Events), `k logs <pod> --previous`.
**Act:** Pending → node capacity or a Spot preemption (cluster autoscaler should add a node; check `kubectl get nodes`); CrashLoopBackOff → logs; NetworkPolicy changes can also block scrapes (see `templates/networkpolicies.yaml`).

## JhanviTrendsPodRestarting
**Meaning:** a container restarted more than twice in 15 minutes.
**Confirm:** `k describe pod <pod>`: `OOMKilled` → raise the memory limit; liveness failures → the app is slow to answer (check the startup probe for JVM services).

## JhanviTrendsBackupStale
**Meaning:** a nightly database dump (`postgres-backup` / `mongodb-backup`) hasn't succeeded for 26+ hours.
**Confirm:** `k get cronjob,jobs | grep backup`, then `k logs job/<latest-job> -c dump` and `-c upload`.
**Act:** `no Workload Identity token` → Terraform's `backups.tf` isn't applied or the ServiceAccount annotation is wrong (`terraform output backups`). Upload 403 → the GSA lacks `objectCreator` on the bucket. Run one now: `k create job --from=cronjob/postgres-backup manual-$(date +%s)`. See [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

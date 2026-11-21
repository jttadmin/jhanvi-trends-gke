// LOAD TEST: expected normal traffic, held steady. Answers "does it meet the SLO at the load we plan for?"
//
//   k6 run tests/k6/load.js                                     # 50 shoppers for 10 min
//   k6 run -e VUS=20 -e DURATION=5m tests/k6/load.js            # smaller, cheaper run on the dev cluster
//   k6 run -e BASE_URL=http://localhost:8080 tests/k6/load.js   # via kubectl port-forward svc/frontend 8080:8080
//
// Pass = every threshold below holds. Watch Grafana "Jhanvi Trends / Service Overview" while it runs.
import { discoverProducts, shopperIteration } from './lib/shopper.js';

const VUS = Number(__ENV.VUS || 50);
const DURATION = __ENV.DURATION || '10m';

export const options = {
  scenarios: {
    steady_shoppers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: VUS },   // warm up (lets JIT/caches/connection pools settle)
        { duration: DURATION, target: VUS }, // steady state = the actual measurement
        { duration: '1m', target: 0 },     // ramp down
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],                                // < 1% failed requests
    http_req_duration: ['p(95)<500', 'p(99)<1500'],               // overall latency SLO
    'http_req_duration{name:GET /api/products}': ['p(95)<300'],   // browsing must stay snappy
    'http_req_duration{name:GET /api/products/:id}': ['p(95)<400'],
    'http_req_duration{name:POST /api/cart/items}': ['p(95)<500'],
    checkout_duration: ['p(95)<2000'],                              // saga: reserve -> pay -> save -> Kafka
    business_errors: ['rate<0.01'],
    checks: ['rate>0.99'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export const setup = discoverProducts;
export default shopperIteration;

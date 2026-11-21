// STRESS TEST: push past normal load in steps until it degrades, then back down.
// Answers "where is the breaking point, which service breaks first, does HPA scale out, and does it recover?"
//
//   k6 run tests/k6/stress.js                          # steps up to 400 shoppers (MAX_VUS)
//   k6 run -e MAX_VUS=200 tests/k6/stress.js           # gentler, for the cost-sensitive dev cluster
//   k6 run -e THINK_TIME=0 tests/k6/stress.js          # no think time = far more requests per VU
//
// While it runs, watch in another terminal:
//   kubectl get hpa -n jhanvi-trends -w                (pods should scale out once CPU/memory > 70%)
//   kubectl top pods -n jhanvi-trends
// Thresholds here are deliberately loose and abort the run early if the system is clearly falling over,
// so you don't burn money/nodes on a dead cluster. The interesting output is *at which stage* things degraded.
import { discoverProducts, shopperIteration } from './lib/shopper.js';

const MAX = Number(__ENV.MAX_VUS || 400);
const step = (f) => Math.max(1, Math.round(MAX * f));

export const options = {
  scenarios: {
    stepped_stress: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: step(0.125) }, // ~normal load (50 @ MAX 400)
        { duration: '3m', target: step(0.125) },
        { duration: '2m', target: step(0.25) },  // 2x
        { duration: '3m', target: step(0.25) },
        { duration: '2m', target: step(0.5) },   // 4x  - HPA should have added pods by now
        { duration: '3m', target: step(0.5) },
        { duration: '2m', target: step(1) },     // 8x  - expected breaking point
        { duration: '3m', target: step(1) },
        { duration: '2m', target: 0 },           // recovery: latency/errors should return to baseline
        { duration: '2m', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    // Abort if the cluster is clearly down (>20% errors sustained for a minute).
    http_req_failed: [{ threshold: 'rate<0.20', abortOnFail: true, delayAbortEval: '1m' }],
    // Recorded, not expected to pass at peak; read the per-stage numbers in Grafana/k6 output.
    http_req_duration: ['p(95)<2000'],
    business_errors: ['rate<0.10'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export const setup = discoverProducts;
export default shopperIteration;

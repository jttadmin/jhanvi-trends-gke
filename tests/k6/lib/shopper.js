// Shared k6 shopper journey for Jhanvi Trends load + stress tests.
// Mirrors real traffic mix (same as services/loadgen): mostly browsing, some cart, few checkouts.
import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

export const BASE_URL = (__ENV.BASE_URL || 'https://shop.bhumaji.com').replace(/\/$/, '');
const THINK = Number(__ENV.THINK_TIME || 1); // seconds between steps; 0 = hammer

const QUERIES = ['earbuds', 'keyboard', 'shoes', 'coffee', 'drone', 'yoga', 'monitor', 'novel', 'xyznothing'];
const CATEGORIES = ['Electronics', 'Books', 'Home & Kitchen', 'Fashion', 'Sports & Fitness', 'Toys & Games'];

export const checkoutOk = new Counter('checkout_confirmed');
export const checkoutDeclined = new Counter('checkout_payment_declined');
export const checkoutNoStock = new Counter('checkout_out_of_stock');
export const businessErrors = new Rate('business_errors'); // 5xx / timeouts only
export const checkoutLatency = new Trend('checkout_duration', true);

// Declines (402) and stock-outs (409) are expected business outcomes, so they don't count as failed requests.
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }, 402, 409));

const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
const pause = () => THINK > 0 && sleep(THINK * (0.5 + Math.random()));

function ok(res, name, status = 200) {
  const passed = check(res, { [`${name} ${status}`]: (r) => r.status === status });
  businessErrors.add(res.status === 0 || res.status >= 500);
  return passed;
}

// Runs once per test: fetch real product ids so we never request non-existent products.
export function discoverProducts() {
  const res = http.get(`${BASE_URL}/api/products?limit=50`, { tags: { name: 'setup' } });
  const ids = res.status === 200 ? res.json('items').map((p) => p.id) : [];
  if (!ids.length) throw new Error(`catalog not reachable at ${BASE_URL} (status ${res.status})`);
  return { ids };
}

// One token per VU, created lazily on the VU's first iteration.
let token = null;
function authHeaders() {
  if (!token) {
    const email = `k6-${__VU}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}@k6.jhanvi-trends.local`;
    const res = http.post(`${BASE_URL}/api/auth/register`,
      JSON.stringify({ name: 'k6 Shopper', email, password: 'k6pass123' }),
      { headers: { 'content-type': 'application/json' }, tags: { name: 'POST /api/auth/register' } });
    if (ok(res, 'register', 201)) token = res.json('token');
  }
  return token ? { authorization: `Bearer ${token}`, 'content-type': 'application/json' } : null;
}

export function browse(ids) {
  group('browse', () => {
    ok(http.get(`${BASE_URL}/api/products?limit=20`, { tags: { name: 'GET /api/products' } }), 'list');
    const id = pick(ids);
    ok(http.get(`${BASE_URL}/api/products/${id}`, { tags: { name: 'GET /api/products/:id' } }), 'detail');
    ok(http.get(`${BASE_URL}/api/images/${id}.svg`, { tags: { name: 'GET /api/images/:id' } }), 'image');
  });
  pause();
}

export function search() {
  group('search', () => {
    ok(http.get(`${BASE_URL}/api/products?q=${pick(QUERIES)}`, { tags: { name: 'GET /api/products?q' } }), 'search');
    ok(http.get(`${BASE_URL}/api/products?category=${encodeURIComponent(pick(CATEGORIES))}`,
      { tags: { name: 'GET /api/products?category' } }), 'category');
  });
  pause();
}

export function addToCart(ids) {
  const headers = authHeaders();
  if (!headers) return;
  group('cart', () => {
    ok(http.post(`${BASE_URL}/api/cart/items`, JSON.stringify({ productId: pick(ids), quantity: 1 }),
      { headers, tags: { name: 'POST /api/cart/items' } }), 'add to cart', 201);
    ok(http.get(`${BASE_URL}/api/cart`, { headers, tags: { name: 'GET /api/cart' } }), 'view cart');
  });
  pause();
}

export function checkout(ids) {
  const headers = authHeaders();
  if (!headers) return;
  group('checkout', () => {
    http.post(`${BASE_URL}/api/cart/items`, JSON.stringify({ productId: pick(ids), quantity: 1 }),
      { headers, tags: { name: 'POST /api/cart/items' } });
    const res = http.post(`${BASE_URL}/api/checkout`, JSON.stringify({
      shippingAddress: { fullName: 'k6 Shopper', line1: '12 MG Road', city: 'Bengaluru', pincode: '560001', state: 'Karnataka' },
    }), { headers, tags: { name: 'POST /api/checkout' }, timeout: '20s' });
    checkoutLatency.add(res.timings.duration);
    if (res.status === 201) checkoutOk.add(1);
    else if (res.status === 402) checkoutDeclined.add(1);
    else if (res.status === 409) checkoutNoStock.add(1);
    check(res, { 'checkout 201/402/409': (r) => [201, 402, 409].includes(r.status) });
    businessErrors.add(res.status === 0 || res.status >= 500);
    ok(http.get(`${BASE_URL}/api/orders`, { headers, tags: { name: 'GET /api/orders' } }), 'orders');
  });
  pause();
}

// Weighted mix: 50% browse, 20% search, 20% cart, 10% checkout.
export function shopperIteration(data) {
  const r = Math.random();
  if (r < 0.5) browse(data.ids);
  else if (r < 0.7) search();
  else if (r < 0.9) addToCart(data.ids);
  else checkout(data.ids);
}

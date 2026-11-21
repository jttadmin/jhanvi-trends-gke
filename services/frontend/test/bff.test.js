process.env.LOG_LEVEL = 'silent';
process.env.JWT_SECRET = 'test-secret';

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const jwt = require('jsonwebtoken');
const { app, svc } = require('../src/server');

// ---- fake upstream services: route "<METHOD> <service-url><path>" to a handler ----
let routes;
let calls;
// Returns a factory, so every call gets a fresh (unread) Response.
const json = (status, body) => () => new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

beforeEach(() => {
  calls = [];
  routes = {};
  globalThis.fetch = async (url, opts = {}) => {
    const method = opts.method || 'GET';
    calls.push({ method, url, body: opts.body ? JSON.parse(opts.body) : undefined, headers: opts.headers });
    const key = Object.keys(routes).find((k) => {
      const [m, prefix] = k.split(' ');
      return m === method && url.startsWith(prefix);
    });
    if (!key) throw new Error(`no fake route for ${method} ${url}`);
    const out = routes[key]({ url, body: opts.body ? JSON.parse(opts.body) : undefined });
    return typeof out === 'function' ? out() : out;
  };
});
const on = (method, url, handler) => { routes[`${method} ${url}`] = handler; };

const tokenFor = (claims = {}) => jwt.sign({ sub: 'u-1', name: 'Asha', email: 'asha@x.in', ...claims }, 'test-secret');
const auth = (claims) => ({ authorization: `Bearer ${tokenFor(claims)}` });
const product = (id, price = 100) => ({ id, name: `P${id}`, price, active: true });

// ---------------- auth ----------------
test('protected routes reject missing, garbage and wrongly-signed tokens', async () => {
  for (const header of [undefined, 'Bearer garbage', `Bearer ${jwt.sign({ sub: 'x' }, 'other-secret')}`]) {
    const req = request(app).get('/api/me');
    if (header) req.set('authorization', header);
    assert.equal((await req).status, 401);
  }
});

test('/api/me returns the identity from the JWT, defaulting role to customer', async () => {
  const res = await request(app).get('/api/me').set(auth());
  assert.deepEqual(res.body, { id: 'u-1', name: 'Asha', email: 'asha@x.in', role: 'customer' });
});

test('register is proxied to user-service with 201', async () => {
  on('POST', `${svc.user}/register`, json(201, { token: 't' }));
  const res = await request(app).post('/api/auth/register').send({ name: 'A', email: 'a@x.in', password: 'secret1' });
  assert.equal(res.status, 201);
  assert.equal(calls[0].body.email, 'a@x.in');
});

test('upstream 4xx errors are passed through with their message', async () => {
  on('POST', `${svc.user}/login`, json(401, { error: 'invalid email or password' }));
  const res = await request(app).post('/api/auth/login').send({});
  assert.equal(res.status, 401);
  assert.equal(res.body.error, 'invalid email or password');
});

test('an unreachable upstream becomes 503', async () => {
  globalThis.fetch = async () => { throw new Error('ECONNREFUSED'); };
  const res = await request(app).get('/api/categories');
  assert.equal(res.status, 503);
});

// ---------------- catalog ----------------
test('product list forwards only the allowed query parameters', async () => {
  on('GET', `${svc.catalog}/products`, json(200, { items: [], total: 0 }));
  await request(app).get('/api/products?q=shoes&category=Fashion&limit=5&offset=10&sort=price_asc&includeInactive=true');
  const url = new URL(calls[0].url);
  assert.deepEqual(Object.fromEntries(url.searchParams), { q: 'shoes', category: 'Fashion', limit: '5', offset: '10', sort: 'price_asc' });
});

test('product detail merges stock, and still works when inventory is down', async () => {
  on('GET', `${svc.catalog}/products/3`, json(200, product(3)));
  on('GET', `${svc.inventory}/stock/3`, json(200, { productId: 3, available: 7 }));
  assert.equal((await request(app).get('/api/products/3')).body.stock, 7);

  on('GET', `${svc.inventory}/stock/3`, json(503, { error: 'database unavailable' }));
  const degraded = await request(app).get('/api/products/3');
  assert.equal(degraded.status, 200);
  assert.equal(degraded.body.stock, null);
});

// ---------------- cart ----------------
test('cart is enriched with catalog prices, line totals and subtotal', async () => {
  on('GET', `${svc.cart}/cart/u-1`, json(200, { items: [{ productId: 1, quantity: 2 }, { productId: 2, quantity: 1 }, { productId: 9, quantity: 1 }] }));
  on('GET', `${svc.catalog}/products?ids=`, json(200, { items: [product(1, 10.1), product(2, 5)] }));
  const res = await request(app).get('/api/cart').set(auth());
  assert.equal(res.status, 200);
  assert.equal(res.body.items.length, 2, 'products missing from the catalog are dropped');
  assert.equal(res.body.items[0].lineTotal, 20.2);
  assert.equal(res.body.subtotal, 25.2);
  assert.equal(res.body.itemCount, 3);
});

test('adding an unknown product is rejected before touching the cart', async () => {
  on('GET', `${svc.catalog}/products/999`, json(404, { detail: 'product not found' }));
  const res = await request(app).post('/api/cart/items').set(auth()).send({ productId: 999, quantity: 1 });
  assert.equal(res.status, 404);
  assert.ok(!calls.some((c) => c.url.startsWith(svc.cart)));
});

// ---------------- checkout ----------------
const address = { fullName: 'Asha', line1: '12 MG Road', city: 'Bengaluru', pincode: '560001' };
function cartWith(items) {
  on('GET', `${svc.cart}/cart/u-1`, json(200, { items }));
  on('GET', `${svc.catalog}/products?ids=`, json(200, { items: items.map((i) => product(i.productId, 100)) }));
}

test('checkout validates the address and refuses an empty cart', async () => {
  assert.equal((await request(app).post('/api/checkout').set(auth()).send({ shippingAddress: { ...address, city: '' } })).status, 400);
  cartWith([]);
  const res = await request(app).post('/api/checkout').set(auth()).send({ shippingAddress: address });
  assert.equal(res.status, 400);
  assert.match(res.body.error, /empty/);
});

test('checkout uses catalog prices (not the browser), then clears the cart', async () => {
  cartWith([{ productId: 1, quantity: 2 }]);
  on('POST', `${svc.order}/orders`, ({ body }) => json(201, { id: 'o-1', status: 'CONFIRMED', totalAmount: body.items[0].unitPrice * 2 }));
  on('DELETE', `${svc.cart}/cart/u-1`, json(204));
  const res = await request(app).post('/api/checkout').set(auth()).send({ shippingAddress: address, items: [{ productId: 1, unitPrice: 1 }] });
  assert.equal(res.status, 201);
  const order = calls.find((c) => c.url === `${svc.order}/orders`);
  assert.equal(order.body.items[0].unitPrice, 100);
  assert.equal(order.headers['x-user-id'], 'u-1');
  assert.ok(calls.some((c) => c.method === 'DELETE' && c.url === `${svc.cart}/cart/u-1`));
});

test('a declined payment returns 402 and keeps the cart', async () => {
  cartWith([{ productId: 1, quantity: 1 }]);
  on('POST', `${svc.order}/orders`, json(402, { error: 'Your payment was declined' }));
  const res = await request(app).post('/api/checkout').set(auth()).send({ shippingAddress: address });
  assert.equal(res.status, 402);
  assert.ok(!calls.some((c) => c.method === 'DELETE'));
});

test('users cannot read someone else\'s order', async () => {
  on('GET', `${svc.order}/orders/o-9`, json(200, { id: 'o-9', userId: 'someone-else' }));
  assert.equal((await request(app).get('/api/orders/o-9').set(auth())).status, 404);
});

// ---------------- admin ----------------
test('admin API is admin-only', async () => {
  assert.equal((await request(app).get('/api/admin/products')).status, 401);
  assert.equal((await request(app).get('/api/admin/products').set(auth())).status, 403);
});

test('admin product list merges stock levels', async () => {
  on('GET', `${svc.catalog}/products`, json(200, { items: [product(1), product(2)], total: 2 }));
  on('GET', `${svc.inventory}/stock`, json(200, [{ productId: 1, available: 4 }]));
  const res = await request(app).get('/api/admin/products').set(auth({ role: 'admin' }));
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.items.map((p) => p.stock), [4, 0]);
});

// ---------------- routing ----------------
test('unknown /api routes are JSON 404s; other paths serve the SPA', async () => {
  const api = await request(app).get('/api/nope');
  assert.equal(api.status, 404);
  assert.deepEqual(api.body, { error: 'not found' });
  const spa = await request(app).get('/product/1');
  assert.equal(spa.status, 200);
  assert.match(spa.text, /<html/i);
});

test('healthz is always ok', async () => {
  assert.equal((await request(app).get('/healthz')).body.status, 'ok');
});

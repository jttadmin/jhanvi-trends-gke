process.env.LOG_LEVEL = 'silent';
const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { app, chaos } = require('../src/server');

const valid = { orderRef: 'o-1', userId: 'u-1', amount: 1499.5 };

beforeEach(() => {
  chaos.latencyMs = 0;
  chaos.failureRate = 0;
});

test('healthz and readyz report ok', async () => {
  assert.equal((await request(app).get('/healthz')).body.status, 'ok');
  assert.equal((await request(app).get('/readyz')).body.status, 'ready');
});

test('captures a valid payment in INR by default', async () => {
  const res = await request(app).post('/payments').send(valid);
  assert.equal(res.status, 201);
  assert.equal(res.body.status, 'captured');
  assert.equal(res.body.amount, 1499.5);
  assert.equal(res.body.currency, 'INR');
  assert.match(res.body.paymentId, /^pay_[0-9a-f]{20}$/);
});

test('rejects missing fields and non-positive amounts', async () => {
  for (const body of [{}, { ...valid, orderRef: '' }, { ...valid, userId: undefined }, { ...valid, amount: 0 }, { ...valid, amount: -5 }, { ...valid, amount: 'abc' }]) {
    const res = await request(app).post('/payments').send(body);
    assert.equal(res.status, 400, JSON.stringify(body));
  }
});

test('declines every payment when failureRate is 1', async () => {
  chaos.failureRate = 1;
  const res = await request(app).post('/payments').send(valid);
  assert.equal(res.status, 402);
  assert.equal(res.body.reason, 'card_declined');
});

test('chaos knobs are clamped to safe ranges', async () => {
  let res = await request(app).post('/chaos').send({ failureRate: 5, latencyMs: -100 });
  assert.deepEqual(res.body, { failureRate: 1, latencyMs: 0 });
  res = await request(app).post('/chaos').send({ failureRate: -1 });
  assert.equal(res.body.failureRate, 0);
  assert.deepEqual((await request(app).get('/chaos')).body, { failureRate: 0, latencyMs: 0 });
});

test('metrics endpoint exposes the shared RED histogram', async () => {
  await request(app).post('/payments').send(valid);
  const res = await request(app).get('/metrics');
  assert.equal(res.status, 200);
  assert.match(res.text, /http_server_requests_seconds_bucket/);
  assert.match(res.text, /payments_total\{status="captured"\}/);
});

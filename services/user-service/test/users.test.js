process.env.LOG_LEVEL = 'silent';
process.env.JWT_SECRET = 'test-secret';
process.env.ADMIN_EMAILS = 'Boss@Example.com';

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { app, pool } = require('../src/server');

// In-memory stand-in for the Postgres "users" table: answers the handful of queries the service makes.
let users;
beforeEach(() => {
  users = [];
  pool.query = async (sql, args = []) => {
    if (sql.startsWith('SELECT 1')) return { rows: [{ '?column?': 1 }] };
    if (sql.startsWith('INSERT INTO users')) {
      const [name, email, hash] = args;
      if (users.some((u) => u.email === email.toLowerCase())) throw Object.assign(new Error('dup'), { code: '23505' });
      const row = { id: users.length + 1, name, email: email.toLowerCase(), password_hash: hash, created_at: new Date().toISOString() };
      users.push(row);
      return { rows: [row] };
    }
    if (sql.startsWith('SELECT * FROM users WHERE email')) return { rows: users.filter((u) => u.email === String(args[0]).toLowerCase()) };
    if (sql.startsWith('SELECT * FROM users WHERE id')) return { rows: users.filter((u) => u.id === args[0]) };
    if (sql.startsWith('SELECT count(*)')) return { rows: [{ n: users.length }] };
    if (sql.startsWith('SELECT * FROM users')) return { rows: users.slice(args[1], args[1] + args[0]) };
    throw new Error(`unexpected query: ${sql}`);
  };
});

const register = (body) => request(app).post('/register').send(body);

test('register returns a signed JWT and never the password hash', async () => {
  const res = await register({ name: ' Asha ', email: 'Asha@Example.com', password: 'secret123' });
  assert.equal(res.status, 201);
  assert.deepEqual(Object.keys(res.body.user).sort(), ['createdAt', 'email', 'id', 'name', 'role']);
  assert.equal(res.body.user.email, 'asha@example.com');
  assert.equal(res.body.user.name, 'Asha');
  const claims = jwt.verify(res.body.token, 'test-secret');
  assert.equal(claims.sub, '1');
  assert.equal(claims.role, 'customer');
  assert.ok(await bcrypt.compare('secret123', users[0].password_hash), 'password stored as bcrypt hash');
});

test('register validates input', async () => {
  for (const body of [{}, { name: 'A', email: 'a@x.in' }, { name: 'A', email: 'a@x.in', password: '12345' }, { email: 'a@x.in', password: 'secret123' }]) {
    assert.equal((await register(body)).status, 400, JSON.stringify(body));
  }
});

test('duplicate email gives 409', async () => {
  await register({ name: 'A', email: 'dup@x.in', password: 'secret123' });
  const res = await register({ name: 'B', email: 'DUP@x.in', password: 'secret123' });
  assert.equal(res.status, 409);
});

test('emails in ADMIN_EMAILS get the admin role (case-insensitive)', async () => {
  const res = await register({ name: 'Boss', email: 'boss@example.com', password: 'secret123' });
  assert.equal(res.body.user.role, 'admin');
  assert.equal(jwt.decode(res.body.token).role, 'admin');
});

test('login succeeds with the right password and fails otherwise', async () => {
  await register({ name: 'A', email: 'login@x.in', password: 'secret123' });
  const ok = await request(app).post('/login').send({ email: 'LOGIN@x.in', password: 'secret123' });
  assert.equal(ok.status, 200);
  assert.ok(ok.body.token);
  assert.equal((await request(app).post('/login').send({ email: 'login@x.in', password: 'wrong' })).status, 401);
  assert.equal((await request(app).post('/login').send({ email: 'nobody@x.in', password: 'secret123' })).status, 401);
  assert.equal((await request(app).post('/login').send({})).status, 401);
});

test('user lookup and list', async () => {
  await register({ name: 'A', email: 'a@x.in', password: 'secret123' });
  await register({ name: 'B', email: 'b@x.in', password: 'secret123' });
  const one = await request(app).get('/users/2');
  assert.equal(one.status, 200);
  assert.equal(one.body.email, 'b@x.in');
  assert.equal((await request(app).get('/users/99')).status, 404);
  assert.equal((await request(app).get('/users/abc')).status, 404);
  const list = await request(app).get('/users?limit=1');
  assert.equal(list.body.total, 2);
  assert.equal(list.body.items.length, 1);
});

test('database errors become a generic 500 without leaking details', async () => {
  pool.query = async () => { throw new Error('connection refused to 10.0.0.5'); };
  const res = await request(app).get('/users/1');
  assert.equal(res.status, 500);
  assert.deepEqual(res.body, { error: 'internal error' });
});

test('readyz reflects database reachability', async () => {
  assert.equal((await request(app).get('/readyz')).status, 200);
  pool.query = async () => { throw new Error('down'); };
  assert.equal((await request(app).get('/readyz')).status, 503);
});

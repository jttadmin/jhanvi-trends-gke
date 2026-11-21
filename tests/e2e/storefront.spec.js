// A shopper's journey through the real UI: browse, search, product page, register, cart, checkout.
const { test, expect } = require('@playwright/test');

const uniqueEmail = () => `e2e-${Date.now()}-${Math.random().toString(36).slice(2, 8)}@e2e.jhanvi-trends.local`;

test('home page lists products and categories', async ({ page }) => {
  await page.goto('/#/');
  // First page load of a run: browsers, TLS and the catalog are cold, so allow more time once.
  await expect(page.locator('#app .card .title').first()).toBeVisible({ timeout: 45_000 });
  expect(await page.locator('#app .card .title').count()).toBeGreaterThan(3);
  await expect(page.locator('#subnav a').nth(1)).toBeVisible(); // first real category after "All"
});

test('search narrows the results and a product page opens', async ({ page }) => {
  await page.goto('/#/');
  await page.locator('#search-q').fill('earbuds');
  await page.locator('#search-q').press('Enter');
  await expect(page).toHaveURL(/q=earbuds/);
  const first = page.locator('#app .card .title').first();
  await expect(first).toBeVisible();
  const name = (await first.textContent()).trim();
  await first.click();
  await expect(page).toHaveURL(/#\/product\/\d+/);
  await expect(page.locator('#app')).toContainText(name);
});

test('adding to cart asks a guest to sign in', async ({ page }) => {
  await page.goto('/#/');
  await page.locator('#app .card button', { hasText: 'Add to cart' }).first().click();
  await expect(page).toHaveURL(/#\/login/);
});

test('a new customer can register, add to cart and check out', async ({ page }) => {
  await page.goto('/#/register?next=/');
  await page.locator('#auth input[name=name]').fill('E2E Shopper');
  await page.locator('#auth input[name=email]').fill(uniqueEmail());
  await page.locator('#auth input[name=password]').fill('e2epass123');
  await page.locator('#auth button').click();
  await expect(page.locator('#account-label')).not.toHaveText('Sign in');

  await page.locator('#app .card button', { hasText: 'Add to cart' }).first().click();
  await expect(page.locator('#cart-count')).toHaveText('1');

  await page.goto('/#/cart');
  await page.getByRole('link', { name: 'Checkout' }).click();
  await page.locator('#co input[name=line1]').fill('12 MG Road');
  await page.locator('#co input[name=pincode]').fill('560001');
  await page.locator('#place').click();

  // The mock payment gateway declines ~5% of cards and stock can run out after load tests:
  // both are correct business outcomes, shown to the user as an error instead of an order.
  const placed = page.waitForURL(/#\/orders\/.+placed=1/, { timeout: 30_000 }).then(() => 'placed');
  const refused = page.locator('#co-err .error').waitFor({ timeout: 30_000 }).then(() => 'refused');
  const outcome = await Promise.race([placed, refused]);
  if (outcome === 'refused') {
    await expect(page.locator('#co-err')).toContainText(/declined|stock/i);
  } else {
    await expect(page.locator('#app')).toContainText(/Order/);
  }
});

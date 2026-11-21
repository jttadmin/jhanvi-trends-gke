"""Functional tests: does each feature behave correctly, including the error paths?"""
import uuid

import pytest

from conftest import PASSWORD, Api, new_email, register


# ---------------------------------------------------------------- platform
class TestPlatform:
    def test_healthz(self, anon):
        res = anon.get("/healthz")
        assert res.status_code == 200 and res.json()["status"] == "ok"

    def test_readyz(self, anon):
        res = anon.get("/readyz")
        assert res.status_code == 200 and res.json()["status"] == "ready"

    def test_spa_served_for_deep_links(self, anon):
        res = anon.get("/product/1")  # client-side route -> index.html
        assert res.status_code == 200 and "<html" in res.text.lower()

    def test_unknown_api_route_is_json_404(self, anon):
        res = anon.get(f"/api/does-not-exist-{uuid.uuid4().hex[:6]}")
        assert res.status_code == 404 and res.json()["error"] == "not found"


# ---------------------------------------------------------------- auth
class TestAuth:
    def test_register_returns_token_and_public_user(self):
        email = new_email()
        res = register(email, name="Asha")
        assert res.status_code == 201
        body = res.json()
        assert body["token"]
        assert body["user"]["email"] == email
        assert "password" not in body["user"] and "passwordHash" not in body["user"]

    def test_duplicate_email_rejected(self):
        email = new_email()
        assert register(email).status_code == 201
        res = register(email)
        assert res.status_code == 409
        assert "already registered" in res.json()["error"]

    @pytest.mark.parametrize("payload", [
        {"name": "x", "email": "short@pw.test", "password": "123"},      # password < 6 chars
        {"email": "noname@x.test", "password": "secret123"},              # missing name
        {"name": "No Email", "password": "secret123"},                     # missing email
    ])
    def test_register_validation(self, anon, payload):
        assert anon.post("/api/auth/register", json=payload).status_code == 400

    def test_login_success(self, user, anon):
        res = anon.post("/api/auth/login", json={"email": user["email"], "password": PASSWORD})
        assert res.status_code == 200 and res.json()["token"]

    def test_login_wrong_password(self, user, anon):
        res = anon.post("/api/auth/login", json={"email": user["email"], "password": "wrong-password"})
        assert res.status_code == 401

    def test_login_unknown_user(self, anon):
        res = anon.post("/api/auth/login", json={"email": new_email(), "password": PASSWORD})
        assert res.status_code == 401

    def test_me_returns_identity_from_jwt(self, user):
        res = user["api"].get("/api/me")
        assert res.status_code == 200
        assert res.json()["email"] == user["email"]
        assert res.json()["role"] == "customer"

    @pytest.mark.parametrize("token", [None, "garbage", "eyJhbGciOiJIUzI1NiJ9.e30.invalid-signature"])
    def test_protected_routes_need_valid_token(self, token):
        api = Api(token)
        for path in ("/api/me", "/api/cart", "/api/orders"):
            assert api.get(path).status_code == 401, path

    def test_customer_cannot_use_admin_api(self, user):
        assert user["api"].get("/api/admin/products").status_code == 403


# ---------------------------------------------------------------- catalog
class TestCatalog:
    def test_list_shape(self, anon):
        res = anon.get("/api/products", params={"limit": 5})
        assert res.status_code == 200
        body = res.json()
        assert len(body["items"]) <= 5 and body["total"] >= len(body["items"])
        p = body["items"][0]
        for field in ("id", "name", "category", "brand", "price", "mrp", "imageUrl"):
            assert field in p, field
        assert p["price"] > 0

    def test_pagination_does_not_overlap(self, anon):
        a = anon.get("/api/products", params={"limit": 3, "offset": 0}).json()["items"]
        b = anon.get("/api/products", params={"limit": 3, "offset": 3}).json()["items"]
        assert not {p["id"] for p in a} & {p["id"] for p in b}

    @pytest.mark.parametrize("sort,key,reverse", [("price_asc", "price", False), ("price_desc", "price", True)])
    def test_sorting(self, anon, sort, key, reverse):
        items = anon.get("/api/products", params={"sort": sort, "limit": 20}).json()["items"]
        values = [p[key] for p in items]
        assert values == sorted(values, reverse=reverse)

    def test_search_finds_matches(self, anon):
        first = anon.get("/api/products", params={"limit": 1}).json()["items"][0]
        word = first["name"].split()[0]
        res = anon.get("/api/products", params={"q": word}).json()
        assert res["total"] >= 1
        assert any(p["id"] == first["id"] for p in res["items"]) or res["total"] > len(res["items"])

    def test_search_no_results(self, anon):
        res = anon.get("/api/products", params={"q": "xyznothing" + uuid.uuid4().hex[:6]}).json()
        assert res["total"] == 0 and res["items"] == []

    def test_categories_and_filter_agree(self, anon):
        cats = anon.get("/api/categories").json()
        assert cats and all(c["count"] > 0 for c in cats)
        cat = cats[0]
        res = anon.get("/api/products", params={"category": cat["name"], "limit": 200}).json()
        assert res["total"] == cat["count"]
        assert all(p["category"] == cat["name"] for p in res["items"])

    def test_product_detail_includes_stock(self, anon, product_ids):
        res = anon.get(f"/api/products/{product_ids[0]}")
        assert res.status_code == 200
        body = res.json()
        assert body["id"] == product_ids[0]
        assert body["stock"] is None or body["stock"] >= 0  # None = inventory degraded but page still works

    def test_unknown_product_404(self, anon):
        assert anon.get("/api/products/999999").status_code == 404

    def test_product_image(self, anon, product_ids):
        res = anon.get(f"/api/images/{product_ids[0]}.svg")
        assert res.status_code == 200
        assert res.headers["content-type"].startswith("image/")


# ---------------------------------------------------------------- cart
class TestCart:
    def test_new_user_has_empty_cart(self, user):
        cart = user["api"].get("/api/cart").json()
        assert cart == {"items": [], "itemCount": 0, "subtotal": 0}

    def test_add_accumulates_quantity_and_totals(self, user, product_ids):
        api, pid = user["api"], product_ids[0]
        assert api.post("/api/cart/items", json={"productId": pid, "quantity": 2}).status_code == 201
        cart = api.post("/api/cart/items", json={"productId": pid, "quantity": 1}).json()
        line = next(i for i in cart["items"] if i["productId"] == pid)
        assert line["quantity"] == 3
        assert line["lineTotal"] == pytest.approx(line["product"]["price"] * 3, abs=0.01)
        assert cart["subtotal"] == pytest.approx(sum(i["lineTotal"] for i in cart["items"]), abs=0.01)

    def test_update_quantity(self, user, product_ids):
        api, pid = user["api"], product_ids[0]
        api.post("/api/cart/items", json={"productId": pid, "quantity": 1})
        cart = api.put(f"/api/cart/items/{pid}", json={"quantity": 5}).json()
        assert next(i for i in cart["items"] if i["productId"] == pid)["quantity"] == 5

    def test_quantity_zero_removes_line(self, user, product_ids):
        api, pid = user["api"], product_ids[0]
        api.post("/api/cart/items", json={"productId": pid, "quantity": 1})
        assert api.put(f"/api/cart/items/{pid}", json={"quantity": 0}).json()["itemCount"] == 0

    def test_delete_item(self, user, product_ids):
        api = user["api"]
        api.post("/api/cart/items", json={"productId": product_ids[0], "quantity": 1})
        api.post("/api/cart/items", json={"productId": product_ids[1], "quantity": 1})
        cart = api.delete(f"/api/cart/items/{product_ids[0]}").json()
        assert [i["productId"] for i in cart["items"]] == [product_ids[1]]

    def test_unknown_product_cannot_be_added(self, user):
        assert user["api"].post("/api/cart/items", json={"productId": 999999, "quantity": 1}).status_code == 404

    @pytest.mark.parametrize("qty", [0, -1, 51])
    def test_invalid_quantity_rejected(self, user, product_ids, qty):
        res = user["api"].post("/api/cart/items", json={"productId": product_ids[0], "quantity": qty})
        assert res.status_code == 400

    def test_carts_are_isolated_between_users(self, user, product_ids):
        user["api"].post("/api/cart/items", json={"productId": product_ids[0], "quantity": 1})
        other = Api(register().json()["token"])
        assert other.get("/api/cart").json()["itemCount"] == 0


# ---------------------------------------------------------------- checkout & orders
class TestCheckout:
    def test_empty_cart_rejected(self, user, address):
        res = user["api"].post("/api/checkout", json={"shippingAddress": address})
        assert res.status_code == 400 and "empty" in res.json()["error"]

    @pytest.mark.parametrize("missing", ["fullName", "line1", "city", "pincode"])
    def test_address_required(self, user, product_ids, address, missing):
        user["api"].post("/api/cart/items", json={"productId": product_ids[0], "quantity": 1})
        bad = {k: v for k, v in address.items() if k != missing}
        assert user["api"].post("/api/checkout", json={"shippingAddress": bad}).status_code == 400

    def test_full_checkout_flow(self, user, product_ids, address):
        api = user["api"]
        api.post("/api/cart/items", json={"productId": product_ids[0], "quantity": 1})
        cart = api.get("/api/cart").json()

        res = api.post("/api/checkout", json={"shippingAddress": address})
        # 402 = mock payment decline, 409 = out of stock: valid business outcomes, not bugs.
        assert res.status_code in (201, 402, 409), res.text
        if res.status_code != 201:
            pytest.skip(f"checkout ended with expected business outcome {res.status_code}: {res.json().get('error')}")

        order = res.json()
        assert order["status"] == "CONFIRMED"
        assert float(order["totalAmount"]) == pytest.approx(cart["subtotal"], abs=0.01)
        # cart is cleared after a successful order
        assert api.get("/api/cart").json()["itemCount"] == 0
        # order appears in history and is readable by its owner
        assert any(o["id"] == order["id"] for o in api.get("/api/orders").json())
        assert api.get(f"/api/orders/{order['id']}").status_code == 200
        # ...but not by anyone else
        stranger = Api(register().json()["token"])
        assert stranger.get(f"/api/orders/{order['id']}").status_code == 404

    def test_client_cannot_set_prices(self, user, product_ids, address):
        """Prices come from the catalog; a forged unitPrice in the body must be ignored."""
        api = user["api"]
        api.post("/api/cart/items", json={"productId": product_ids[0], "quantity": 1})
        expected = api.get("/api/cart").json()["subtotal"]
        res = api.post("/api/checkout", json={
            "shippingAddress": address,
            "items": [{"productId": product_ids[0], "unitPrice": 1, "quantity": 1}],
            "totalAmount": 1,
        })
        if res.status_code == 201:
            assert float(res.json()["totalAmount"]) == pytest.approx(expected, abs=0.01)
        else:
            assert res.status_code in (402, 409)

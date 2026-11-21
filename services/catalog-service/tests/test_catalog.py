from app.seed import CATEGORIES


def test_health(api):
    assert api.get("/healthz").json() == {"status": "ok"}


def test_list_returns_seeded_products_with_api_shape(api, seeded_count):
    body = api.get("/products", params={"limit": 200}).json()
    assert body["total"] == seeded_count
    first = body["items"][0]
    assert set(first) >= {"id", "name", "category", "brand", "price", "mrp", "imageUrl", "hasPhoto"}
    assert first["imageUrl"] == f"/api/images/{first['id']}.svg"
    assert not first["hasPhoto"]


def test_default_sort_is_most_reviewed(api):
    counts = [p["reviewCount"] for p in api.get("/products", params={"limit": 200}).json()["items"]]
    assert counts == sorted(counts, reverse=True)


def test_price_sorting_and_pagination(api):
    asc = [p["price"] for p in api.get("/products", params={"sort": "price_asc", "limit": 200}).json()["items"]]
    assert asc == sorted(asc)
    page1 = api.get("/products", params={"limit": 5, "offset": 0}).json()["items"]
    page2 = api.get("/products", params={"limit": 5, "offset": 5}).json()["items"]
    assert not {p["id"] for p in page1} & {p["id"] for p in page2}


def test_limit_is_bounded(api):
    assert api.get("/products", params={"limit": 0}).status_code == 422
    assert api.get("/products", params={"limit": 201}).status_code == 422


def test_search_is_case_insensitive_and_regex_safe(api):
    assert api.get("/products", params={"q": "EARBUDS"}).json()["total"] >= 1
    assert api.get("/products", params={"q": ".*"}).json()["total"] == 0  # escaped, not a wildcard
    assert api.get("/products", params={"q": "xyznothing"}).json() == {"items": [], "total": 0}


def test_ids_filter(api):
    body = api.get("/products", params={"ids": "3,1"}).json()
    assert sorted(p["id"] for p in body["items"]) == [1, 3]
    assert api.get("/products", params={"ids": "1,abc"}).status_code == 400


def test_categories_match_filter_counts(api):
    cats = api.get("/categories").json()
    assert {c["name"] for c in cats} <= set(CATEGORIES)
    for c in cats:
        assert api.get("/products", params={"category": c["name"], "limit": 200}).json()["total"] == c["count"]


def test_get_product_and_404(api):
    assert api.get("/products/1").json()["id"] == 1
    assert api.get("/products/99999").status_code == 404
    assert api.get("/products/abc").status_code == 422


def test_create_update_delete_product(api, new_product):
    created = api.post("/products", json=new_product)
    assert created.status_code == 201
    p = created.json()
    assert p["description"] == "A kettle."
    assert p["features"] == ["1 litre", "Auto shut-off"]
    assert p["rating"] == 0
    assert p["reviewCount"] == 0

    updated = api.put(f"/products/{p['id']}", json={**new_product, "price": 1200, "active": False}).json()
    assert updated["price"] == 1200
    assert updated["active"] is False
    # inactive products are hidden from shoppers but visible to the admin view
    assert api.get(f"/products/{p['id']}").status_code == 404
    assert api.get(f"/products/{p['id']}", params={"includeInactive": True}).status_code == 200

    assert api.delete(f"/products/{p['id']}").status_code == 204
    assert api.delete(f"/products/{p['id']}").status_code == 404


def test_validation_messages_are_readable(api, new_product):
    res = api.post("/products", json={**new_product, "mrp": 10, "price": 100})
    assert res.status_code == 422
    assert "MRP cannot be lower than the selling price" in res.json()["error"]
    res = api.post("/products", json={**new_product, "price": -1})
    assert res.status_code == 422
    assert res.json()["error"].startswith("price:")


def test_update_unknown_product(api, new_product):
    assert api.put("/products/99999", json=new_product).status_code == 404


def test_generated_svg_escapes_brand(api, new_product):
    pid = api.post("/products", json={**new_product, "brand": "<script>"}).json()["id"]
    res = api.get(f"/images/{pid}.svg")
    assert res.status_code == 200
    assert res.headers["content-type"].startswith("image/svg+xml")
    assert "<script>" not in res.text
    assert "&lt;script&gt;" in res.text


def test_photo_upload_replace_and_delete(api):
    jpeg = b"\xff\xd8\xff\xe0fake-jpeg"
    assert api.put("/products/1/image", content=jpeg, headers={"content-type": "text/plain"}).status_code == 415
    assert api.put("/products/1/image", content=b"", headers={"content-type": "image/jpeg"}).status_code == 400
    assert api.put("/products/99999/image", content=jpeg, headers={"content-type": "image/jpeg"}).status_code == 404

    up = api.put("/products/1/image", content=jpeg, headers={"content-type": "image/jpeg"})
    assert up.status_code == 200
    assert up.json()["hasPhoto"]
    photo = api.get("/images/1")
    assert photo.content == jpeg
    assert photo.headers["content-type"] == "image/jpeg"

    removed = api.delete("/products/1/image").json()
    assert not removed["hasPhoto"]
    assert api.get("/images/1").headers["content-type"].startswith("image/svg+xml")


def test_oversized_photo_rejected(api):
    big = b"\xff" * (3 * 1024 * 1024 + 1)
    assert api.put("/products/1/image", content=big, headers={"content-type": "image/png"}).status_code == 413


def test_metrics_exposed(api):
    api.get("/products", params={"q": "earbuds"})
    text = api.get("/metrics").text
    assert "http_server_requests_seconds_bucket" in text
    assert "catalog_searches_total" in text

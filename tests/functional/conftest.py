"""Shared fixtures for the Jhanvi Trends functional tests.

All tests go through the public frontend BFF (the only service behind the ingress), so they
check real behaviour across frontend -> user/catalog/cart/inventory/order/payment services.

    BASE_URL=https://shop.bhumaji.com pytest tests/functional -v
"""
import os
import uuid

import pytest
import requests

BASE_URL = os.environ.get("BASE_URL", "https://shop.bhumaji.com").rstrip("/")
TIMEOUT = float(os.environ.get("TIMEOUT", "15"))
PASSWORD = "functest123"

ADDRESS = {
    "fullName": "Functional Test",
    "line1": "12 MG Road",
    "city": "Bengaluru",
    "pincode": "560001",
    "state": "Karnataka",
}


class Api:
    """Tiny client: api.get('/api/products') -> requests.Response, with optional bearer token."""

    def __init__(self, token=None):
        self.s = requests.Session()
        if token:
            self.s.headers["authorization"] = f"Bearer {token}"

    def request(self, method, path, **kw):
        kw.setdefault("timeout", TIMEOUT)
        return self.s.request(method, BASE_URL + path, **kw)

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def post(self, path, **kw):
        return self.request("POST", path, **kw)

    def put(self, path, **kw):
        return self.request("PUT", path, **kw)

    def delete(self, path, **kw):
        return self.request("DELETE", path, **kw)


def new_email():
    return f"func-{uuid.uuid4().hex[:12]}@functest.jhanvi-trends.local"


def register(email=None, name="Functional Test", password=PASSWORD):
    return Api().post("/api/auth/register", json={"name": name, "email": email or new_email(), "password": password})


@pytest.fixture(scope="session")
def anon():
    return Api()


@pytest.fixture
def user():
    """A brand-new registered user (fresh, empty cart) for each test."""
    email = new_email()
    res = register(email)
    assert res.status_code == 201, res.text
    body = res.json()
    return {"email": email, "token": body["token"], "user": body["user"], "api": Api(body["token"])}


@pytest.fixture(scope="session")
def product_ids():
    """IDs of a few active products, read from the catalog instead of hard-coding them."""
    res = Api().get("/api/products", params={"limit": 10})
    assert res.status_code == 200, res.text
    ids = [p["id"] for p in res.json()["items"]]
    assert ids, "catalog is empty - is the seed data loaded?"
    return ids


@pytest.fixture(scope="session")
def address():
    return dict(ADDRESS)

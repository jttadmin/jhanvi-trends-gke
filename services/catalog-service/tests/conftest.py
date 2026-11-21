"""Run the API against an in-memory MongoDB (mongomock) instead of a real database."""
import gridfs
import mongomock
import mongomock.gridfs
import pytest
from fastapi.testclient import TestClient

from app import main
from app.seed import PRODUCTS

mongomock.gridfs.enable_gridfs_integration()


@pytest.fixture
def db(monkeypatch):
    client = mongomock.MongoClient()
    database = client["catalog"]
    monkeypatch.setattr(main, "products", database["products"])
    monkeypatch.setattr(main, "images", gridfs.GridFS(database, collection="images"))
    monkeypatch.setattr(main, "client", client)
    # Seed the demo catalog the same way the service does on startup (without the bundled photos).
    monkeypatch.setattr(main, "seed_photos", lambda: None)
    main.migrate()
    return database


@pytest.fixture
def api(db):
    # No "with" block: the lifespan (real MongoDB connection) is skipped; migrate() already ran on mongomock.
    return TestClient(main.app)


@pytest.fixture
def seeded_count():
    return len(PRODUCTS)


@pytest.fixture
def new_product():
    return {
        "name": "Test Kettle",
        "category": "Home & Kitchen",
        "brand": "Testco",
        "price": 999,
        "mrp": 1499,
        "description": "  A kettle.  ",
        "features": ["1 litre", "  ", "Auto shut-off"],
    }

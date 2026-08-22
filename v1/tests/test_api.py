import uuid

from fastapi.testclient import TestClient

from app.main import ObjectService, StoredObject, app


class FakeRepository:
    def __init__(self) -> None:
        self.items: dict[uuid.UUID, StoredObject] = {}

    def initialize(self) -> None:
        pass

    def ping(self) -> None:
        pass

    def insert(self, item: StoredObject) -> None:
        self.items[item.id] = item

    def get(self, object_id: uuid.UUID) -> StoredObject | None:
        return self.items.get(object_id)


class FakeBlobStore:
    def __init__(self) -> None:
        self.items: dict[str, bytes] = {}

    def ping(self) -> None:
        pass

    def put(self, key: str, payload: bytes, content_type: str) -> None:
        self.items[key] = payload

    def get(self, key: str) -> bytes:
        return self.items[key]

    def delete(self, key: str) -> None:
        self.items.pop(key, None)


def test_post_get_and_demo_round_trip() -> None:
    service = ObjectService(FakeRepository(), FakeBlobStore())
    app.state.object_service = service

    client = TestClient(app)
    created = client.post("/objects", json={"content": "hello"})
    assert created.status_code == 201

    object_id = created.json()["id"]
    fetched = client.get(f"/objects/{object_id}")
    assert fetched.status_code == 200
    assert fetched.json()["content"] == "hello"

    demo = client.post("/demo", json={"content": "complete flow"})
    assert demo.status_code == 201
    assert demo.json()["verified"] is True
    assert demo.json()["written"] == demo.json()["read_back"]


def test_missing_object_is_404() -> None:
    app.state.object_service = ObjectService(FakeRepository(), FakeBlobStore())
    response = TestClient(app).get(f"/objects/{uuid.uuid4()}")
    assert response.status_code == 404


def test_compensates_blob_when_metadata_insert_fails() -> None:
    class FailingRepository(FakeRepository):
        def insert(self, item: StoredObject) -> None:
            raise RuntimeError("database unavailable")

    blobs = FakeBlobStore()
    service = ObjectService(FailingRepository(), blobs)

    try:
        service.create("payload", "text/plain")
    except RuntimeError:
        pass
    else:
        raise AssertionError("Expected metadata insert to fail")

    assert blobs.items == {}

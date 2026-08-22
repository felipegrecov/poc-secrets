import uuid

from fastapi.testclient import TestClient

from app.main import ObjectService, Settings, StoredObject, app


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


def test_settings_read_csi_mounted_secret_files(tmp_path, monkeypatch) -> None:
    secrets = {
        "POSTGRES_USER": "dynamic-user",
        "POSTGRES_PASSWORD": "dynamic-password",
        "MINIO_ACCESS_KEY": "blue-access-key",
        "MINIO_SECRET_KEY": "blue-secret-key",
    }
    for name, value in secrets.items():
        path = tmp_path / name.lower()
        path.write_text(f"{value}\n", encoding="utf-8")
        monkeypatch.setenv(f"{name}_FILE", str(path))
        monkeypatch.delenv(name, raising=False)

    monkeypatch.setenv("POSTGRES_HOST", "postgres-rw")
    monkeypatch.setenv("POSTGRES_DB", "datenna")
    monkeypatch.setenv("MINIO_ENDPOINT", "minio:9000")
    monkeypatch.setenv("MINIO_BUCKET", "datenna-objects")

    settings = Settings.from_env()

    assert settings.postgres_user == "dynamic-user"
    assert settings.postgres_password == "dynamic-password"
    assert settings.minio_access_key == "blue-access-key"
    assert settings.minio_secret_key == "blue-secret-key"

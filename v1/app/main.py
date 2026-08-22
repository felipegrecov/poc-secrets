from __future__ import annotations

import io
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

import psycopg
from fastapi import FastAPI, HTTPException, Request, status
from minio import Minio
from minio.error import S3Error
from pydantic import BaseModel, Field
from psycopg.rows import dict_row


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("datenna-demo")


@dataclass(frozen=True)
class Settings:
    postgres_host: str
    postgres_port: int
    postgres_db: str
    postgres_user: str
    postgres_password: str
    minio_endpoint: str
    minio_access_key: str
    minio_secret_key: str
    minio_bucket: str
    minio_secure: bool

    @classmethod
    def from_env(cls) -> "Settings":
        required = (
            "POSTGRES_HOST",
            "POSTGRES_DB",
            "POSTGRES_USER",
            "POSTGRES_PASSWORD",
            "MINIO_ENDPOINT",
            "MINIO_ACCESS_KEY",
            "MINIO_SECRET_KEY",
            "MINIO_BUCKET",
        )
        missing = [name for name in required if not os.getenv(name)]
        if missing:
            raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")

        return cls(
            postgres_host=os.environ["POSTGRES_HOST"],
            postgres_port=int(os.getenv("POSTGRES_PORT", "5432")),
            postgres_db=os.environ["POSTGRES_DB"],
            postgres_user=os.environ["POSTGRES_USER"],
            postgres_password=os.environ["POSTGRES_PASSWORD"],
            minio_endpoint=os.environ["MINIO_ENDPOINT"],
            minio_access_key=os.environ["MINIO_ACCESS_KEY"],
            minio_secret_key=os.environ["MINIO_SECRET_KEY"],
            minio_bucket=os.environ["MINIO_BUCKET"],
            minio_secure=os.getenv("MINIO_SECURE", "false").lower() == "true",
        )

    @property
    def postgres_dsn(self) -> str:
        return (
            f"host={self.postgres_host} port={self.postgres_port} "
            f"dbname={self.postgres_db} user={self.postgres_user} "
            f"password={self.postgres_password} sslmode=require connect_timeout=5"
        )


@dataclass(frozen=True)
class StoredObject:
    id: uuid.UUID
    object_key: str
    content_type: str
    size_bytes: int
    created_at: datetime


class MetadataRepository(Protocol):
    def initialize(self) -> None: ...
    def ping(self) -> None: ...
    def insert(self, item: StoredObject) -> None: ...
    def get(self, object_id: uuid.UUID) -> StoredObject | None: ...


class BlobStore(Protocol):
    def ping(self) -> None: ...
    def put(self, key: str, payload: bytes, content_type: str) -> None: ...
    def get(self, key: str) -> bytes: ...
    def delete(self, key: str) -> None: ...


class PostgresRepository:
    def __init__(self, dsn: str) -> None:
        self._dsn = dsn

    def _connect(self) -> psycopg.Connection:
        return psycopg.connect(self._dsn, row_factory=dict_row)

    def initialize(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS stored_objects (
                    id UUID PRIMARY KEY,
                    object_key TEXT NOT NULL UNIQUE,
                    content_type TEXT NOT NULL,
                    size_bytes BIGINT NOT NULL CHECK (size_bytes >= 0),
                    created_at TIMESTAMPTZ NOT NULL
                )
                """
            )

    def ping(self) -> None:
        with self._connect() as connection:
            connection.execute("SELECT 1")

    def insert(self, item: StoredObject) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO stored_objects
                    (id, object_key, content_type, size_bytes, created_at)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (
                    item.id,
                    item.object_key,
                    item.content_type,
                    item.size_bytes,
                    item.created_at,
                ),
            )

    def get(self, object_id: uuid.UUID) -> StoredObject | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT id, object_key, content_type, size_bytes, created_at
                FROM stored_objects
                WHERE id = %s
                """,
                (object_id,),
            ).fetchone()
        return StoredObject(**row) if row else None


class MinioBlobStore:
    def __init__(
        self,
        endpoint: str,
        access_key: str,
        secret_key: str,
        bucket: str,
        secure: bool,
    ) -> None:
        self._client = Minio(
            endpoint,
            access_key=access_key,
            secret_key=secret_key,
            secure=secure,
        )
        self._bucket = bucket

    def ping(self) -> None:
        if not self._client.bucket_exists(self._bucket):
            raise RuntimeError(f"MinIO bucket {self._bucket!r} does not exist")

    def put(self, key: str, payload: bytes, content_type: str) -> None:
        self._client.put_object(
            self._bucket,
            key,
            io.BytesIO(payload),
            length=len(payload),
            content_type=content_type,
        )

    def get(self, key: str) -> bytes:
        response = self._client.get_object(self._bucket, key)
        try:
            return response.read()
        finally:
            response.close()
            response.release_conn()

    def delete(self, key: str) -> None:
        self._client.remove_object(self._bucket, key)


class ObjectService:
    def __init__(self, repository: MetadataRepository, blobs: BlobStore) -> None:
        self.repository = repository
        self.blobs = blobs

    def initialize(self) -> None:
        self.repository.initialize()
        self.blobs.ping()

    def ready(self) -> None:
        self.repository.ping()
        self.blobs.ping()

    def create(self, content: str, content_type: str) -> tuple[StoredObject, bytes]:
        payload = content.encode("utf-8")
        object_id = uuid.uuid4()
        object_key = f"objects/{object_id}"
        item = StoredObject(
            id=object_id,
            object_key=object_key,
            content_type=content_type,
            size_bytes=len(payload),
            created_at=datetime.now().astimezone(),
        )

        self.blobs.put(object_key, payload, content_type)
        try:
            self.repository.insert(item)
        except Exception:
            logger.exception("Database insert failed; compensating by deleting blob")
            try:
                self.blobs.delete(object_key)
            except Exception:
                logger.exception("Blob compensation failed for %s", object_key)
            raise
        return item, payload

    def read(self, object_id: uuid.UUID) -> tuple[StoredObject, bytes] | None:
        item = self.repository.get(object_id)
        if item is None:
            return None
        return item, self.blobs.get(item.object_key)


class ObjectWrite(BaseModel):
    content: str = Field(min_length=1, max_length=1_000_000)
    content_type: str = Field(default="text/plain; charset=utf-8", max_length=200)


class ObjectRead(BaseModel):
    id: uuid.UUID
    object_key: str
    content: str
    content_type: str
    size_bytes: int
    created_at: datetime


class DemoResult(BaseModel):
    status: str
    written: ObjectRead
    read_back: ObjectRead
    verified: bool


def _response(item: StoredObject, payload: bytes) -> ObjectRead:
    try:
        content = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise HTTPException(status_code=500, detail="Stored object is not UTF-8") from exc
    return ObjectRead(
        id=item.id,
        object_key=item.object_key,
        content=content,
        content_type=item.content_type,
        size_bytes=item.size_bytes,
        created_at=item.created_at,
    )


def build_service(settings: Settings) -> ObjectService:
    return ObjectService(
        PostgresRepository(settings.postgres_dsn),
        MinioBlobStore(
            endpoint=settings.minio_endpoint,
            access_key=settings.minio_access_key,
            secret_key=settings.minio_secret_key,
            bucket=settings.minio_bucket,
            secure=settings.minio_secure,
        ),
    )


def initialize_with_retry(service: ObjectService, attempts: int = 30) -> None:
    for attempt in range(1, attempts + 1):
        try:
            service.initialize()
            return
        except Exception:
            if attempt == attempts:
                raise
            logger.warning("Dependencies are not ready (attempt %s/%s)", attempt, attempts)
            time.sleep(2)


@asynccontextmanager
async def lifespan(app: FastAPI):
    service = build_service(Settings.from_env())
    initialize_with_retry(service)
    app.state.object_service = service
    yield


app = FastAPI(
    title="Datenna storage exercise",
    version="1.0.0",
    description="Stores metadata in PostgreSQL and content in MinIO.",
    lifespan=lifespan,
)


def get_service(request: Request) -> ObjectService:
    return request.app.state.object_service


@app.get("/healthz", tags=["operations"])
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz", tags=["operations"])
def readyz(request: Request) -> dict[str, str]:
    try:
        get_service(request).ready()
    except Exception as exc:
        logger.warning("Readiness check failed: %s", exc)
        raise HTTPException(status_code=503, detail="Dependencies are unavailable") from exc
    return {"status": "ready"}


@app.post("/objects", response_model=ObjectRead, status_code=status.HTTP_201_CREATED)
def create_object(body: ObjectWrite, request: Request) -> ObjectRead:
    try:
        item, payload = get_service(request).create(body.content, body.content_type)
        return _response(item, payload)
    except (psycopg.Error, S3Error, OSError) as exc:
        logger.exception("Object creation failed")
        raise HTTPException(status_code=503, detail="Storage operation failed") from exc


@app.get("/objects/{object_id}", response_model=ObjectRead)
def get_object(object_id: uuid.UUID, request: Request) -> ObjectRead:
    try:
        result = get_service(request).read(object_id)
    except (psycopg.Error, S3Error, OSError) as exc:
        logger.exception("Object retrieval failed")
        raise HTTPException(status_code=503, detail="Storage operation failed") from exc
    if result is None:
        raise HTTPException(status_code=404, detail="Object not found")
    return _response(*result)


@app.post("/demo", response_model=DemoResult, status_code=status.HTTP_201_CREATED)
def run_demo(body: ObjectWrite, request: Request) -> DemoResult:
    """Write to both stores, read from both stores, and verify the round trip."""
    service = get_service(request)
    try:
        written_item, written_payload = service.create(body.content, body.content_type)
        result = service.read(written_item.id)
    except (psycopg.Error, S3Error, OSError) as exc:
        logger.exception("End-to-end demo failed")
        raise HTTPException(status_code=503, detail="Storage operation failed") from exc

    if result is None:
        raise HTTPException(status_code=500, detail="Metadata disappeared after write")
    read_item, read_payload = result
    verified = written_item == read_item and written_payload == read_payload
    if not verified:
        raise HTTPException(status_code=500, detail="Round-trip verification failed")
    return DemoResult(
        status="round trip succeeded",
        written=_response(written_item, written_payload),
        read_back=_response(read_item, read_payload),
        verified=True,
    )


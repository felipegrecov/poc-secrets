# Datenna storage exercise

A small FastAPI service on a local kind cluster. A `POST` stores object content in MinIO and its metadata in PostgreSQL; a `GET` reads both. PostgreSQL is managed by CloudNativePG (CNPG).

## Run it

Prerequisite: Docker Desktop (or Docker Engine on Linux) must be installed and running. Allocate roughly 6 GB RAM to Docker. The startup script downloads pinned `kind` and `kubectl` binaries into the Git-ignored `.tools/` directory when they are not already available.

Windows PowerShell:

```powershell
.\scripts\up.ps1
```

Linux/macOS:

```bash
make up
```

Startup creates the kind cluster, builds and loads the two local images, installs CNPG 1.30.0, deploys PostgreSQL and MinIO, creates scoped Kubernetes Secrets, deploys the API, and calls `POST /demo`. Open [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs) for Swagger UI.

Useful calls:

```bash
curl -sS -X POST http://127.0.0.1:8080/objects \
  -H 'content-type: application/json' \
  -d '{"content":"hello"}'

curl -sS http://127.0.0.1:8080/objects/OBJECT_ID

curl -sS -X POST http://127.0.0.1:8080/demo \
  -H 'content-type: application/json' \
  -d '{"content":"verify the full round trip"}'
```

Stop and remove the cluster with `.\scripts\down.ps1` or `make down`. The generated credentials are preserved for repeatable reruns. To remove them too, use `.\scripts\down.ps1 -PurgeSecrets` or `./scripts/down.sh --purge-secrets`.

## Credential path

- `scripts/generate-secrets.ps1` (or `up.sh`) generates `.secrets.env` locally with cryptographic randomness. The file is Git-ignored and values are never printed by startup.
- Startup turns those values into three namespace-scoped Secrets: `postgres-app`, `minio-root`, and `minio-app`.
- CNPG and the API consume `postgres-app` through `secretKeyRef`. MinIO alone receives `minio-root`; the short-lived bootstrap Job receives root plus app credentials; the API receives only `minio-app` through `secretKeyRef`.
- The application and MinIO ServiceAccounts do not mount Kubernetes API tokens and receive no Secret-reading RBAC. On this local kind cluster, anyone with the generated cluster-admin kubeconfig can still read Secrets.
- In a real environment, replace the local file and static Kubernetes Secrets with workload identity plus an external secret manager, enforce narrowly scoped RBAC, rotate credentials, and use audited access.

## Layout and tests

- `app/main.py` - API, PostgreSQL metadata repository, MinIO blob store, compensation on partial write failure.
- `k8s/` - CNPG cluster, MinIO, scoped bootstrap Job, and FastAPI deployment.
- `infra/` - kind configuration and a source-built MinIO image.
- `../DECISIONS.md` - consolidated decision log covering both variants.

Run unit tests with:

```bash
python -m pip install -r requirements-dev.txt
python -m pytest -q
```

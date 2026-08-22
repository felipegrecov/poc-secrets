# Datenna storage exercise — OpenBao variant

This is the OpenBao-based `v2` of the local Kubernetes exercise. The FastAPI API still stores object bytes in MinIO and metadata in PostgreSQL/CloudNativePG, but application credentials no longer come from hand-maintained Kubernetes Secrets.

## Implemented pipeline

```text
Helm installs OpenBao HA (3 replicas, integrated Raft storage)
  -> startup initializes/unseals the cluster
  -> Kubernetes auth trusts the datenna-app ServiceAccount
  -> database/config/postgres connects to CloudNativePG
  -> database/roles/datenna-app issues a unique PostgreSQL login
  -> OpenBao CSI mounts the login and active MinIO KV slot as files
  -> a rolling update starts a ready pod before terminating the old pod
  -> the old PostgreSQL lease expires and OpenBao drops its login
```

PostgreSQL credentials are dynamic, with a 2-minute default lease and a 10-minute maximum lease. MinIO has no OpenBao dynamic secrets engine in this design, so `kv-v2` holds blue and green credential slots. Rotation removes the retired identity from the inactive slot, creates its replacement, switches the active KV value, verifies a rolling deployment and only then disables the old user.

The implementation follows the official [OpenBao Kubernetes](https://openbao.org/docs/platform/k8s/), [HA Raft](https://openbao.org/docs/platform/k8s/helm/examples/ha-with-raft/), [database secrets](https://openbao.org/docs/secrets/databases/), [Kubernetes auth](https://openbao.org/docs/auth/kubernetes/), [CSI dynamic database example](https://openbao.org/docs/platform/k8s/csi/examples/) and [lease lifecycle](https://openbao.org/docs/concepts/lease/) documentation.

## Run it

Prerequisites:

- Docker Desktop/Engine running, with roughly 8 GB available to Docker;
- PowerShell 7 on Windows, or Bash plus `curl`, `openssl`, `python3`, `tar` and either `sha256sum` or `shasum` on Linux, macOS or WSL;
- port `127.0.0.1:8080` free. Stop `v1` first if its kind cluster is running.

Windows with PowerShell 7:

```powershell
.\scripts\up.ps1
```

Linux, macOS or WSL with Bash:

```bash
bash ./scripts/up.sh
```

The script downloads checksum-verified `kind`, `kubectl` and Helm binaries when missing. It installs these pinned components:

| Component | Version |
|---|---:|
| kind | 0.32.0 |
| Kubernetes client | 1.35.0 |
| Helm | 3.21.0 |
| CloudNativePG | 1.30.0 |
| Secrets Store CSI Driver | 1.6.0 |
| OpenBao Helm chart | 0.29.1 |
| OpenBao | 2.6.1 |
| OpenBao CSI provider | 2.0.3 |

Startup creates an isolated kind cluster named `datenna-openbao`, runs a full `POST /demo` round trip, and exposes Swagger at [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs).

## Rotation demos

Request a new dynamic PostgreSQL identity by rolling the application:

```powershell
.\scripts\rotate-postgres.ps1
```

To wait past the local TTL and verify that PostgreSQL no longer contains the old login:

```powershell
.\scripts\rotate-postgres.ps1 -VerifyRevocation
```

On Bash use `./scripts/rotate-postgres.sh` and optionally `--verify-revocation`.

Rotate MinIO blue/green credentials:

```powershell
.\scripts\rotate-minio.ps1
```

On Bash use `./scripts/rotate-minio.sh`. The script restores the previous active KV value if the new application pod or the end-to-end check fails.

## Credential boundaries

- The API mounts four read-only CSI files. It receives no Kubernetes Secret-reading RBAC and does not mount the default API token.
- `database/creds/datenna-app` returns a unique PostgreSQL login. The login only inherits the `datenna_runtime` DML role; it owns neither the schema nor the table.
- `kv/data/minio/datenna-app-active` contains only the current bucket-scoped MinIO application credentials.
- `.secrets.env` is a Git-ignored local bootstrap source for the MinIO root and initial blue/green users. The temporary application bootstrap Secret is deleted after deployment. MinIO still needs its root Secret to restart.
- `.openbao-bootstrap.json` is Git-ignored and contains the local unseal key and initial root token. This is acceptable only for this disposable local cluster.
- CloudNativePG generates `postgres-superuser`; startup reads it to configure the database engine. The application never receives it.

The CSI files are read when a pod starts. Updating a secret value alone does not reconfigure existing Python clients, so both rotation scripts deliberately trigger a rolling deployment.

## Operations and tests

Useful API calls:

```bash
curl -sS -X POST http://127.0.0.1:8080/objects \
  -H 'content-type: application/json' \
  -d '{"content":"hello"}'

curl -sS http://127.0.0.1:8080/objects/OBJECT_ID
```

Run unit tests with `python -m pytest -q`. Remove the cluster with `./scripts/down.sh` or `.\scripts\down.ps1`. Add `--purge-secrets` or `-PurgeSecrets` to also irreversibly remove both local bootstrap files.

## Local-demo limitations

OpenBao uses three Raft members, but this kind cluster has one node and therefore one physical failure domain. TLS and auto-unseal are intentionally omitted to keep the exercise runnable on a laptop. A production setup needs verified TLS, external auto-unseal/KMS, independent failure domains, audit devices, Raft snapshots and restore tests, monitoring, NetworkPolicies, PodDisruptionBudgets aligned with real topology, a dedicated PostgreSQL administrative role, and a protected GitOps/bootstrap process.

See `../DECISIONS.md` for the consolidated trade-offs across both variants, including the production AI and credential-leak response model.

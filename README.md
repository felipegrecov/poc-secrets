This repository contains two local Kubernetes implementations of the same FastAPI object-storage flow:

- [`v1`](v1/README.md): the small baseline using scoped Kubernetes Secrets.
- [`v2`](v2/README.md): the OpenBao variant using Kubernetes authentication, CSI-mounted credentials, dynamic PostgreSQL identities and blue/green MinIO credential rotation.

The API stores object bytes in MinIO and metadata in PostgreSQL managed by CloudNativePG. Both variants run in an isolated kind cluster and expose Swagger only on `127.0.0.1:8080`.

## Prerequisites

- Docker Desktop or Docker Engine running, with about 8 GB available;
- port `127.0.0.1:8080` available;
- PowerShell 7 on Windows, or Bash on Linux, macOS or WSL;
- for Bash: `curl`, `openssl`, `python3`, `tar` and either `sha256sum` or `shasum`.

The startup scripts download checksum-verified copies of kind, kubectl and Helm into the Git-ignored `v2/.tools` directory when those commands are not already installed.

## Run with PowerShell 7

From the repository root:

```powershell
Set-Location .\v2
.\scripts\up.ps1
```

The command creates the `datenna-openbao` kind cluster, deploys all components and performs a POST/read-back verification. Open Swagger at [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs), or call the demo directly:

```powershell
$demo = Invoke-RestMethod `
  -Method Post `
  -Uri 'http://127.0.0.1:8080/demo' `
  -ContentType 'application/json' `
  -Body '{"content":"hello from PowerShell"}'
$demo | ConvertTo-Json -Depth 4
```

Demonstrate credential rotation:

```powershell
.\scripts\rotate-postgres.ps1
.\scripts\rotate-postgres.ps1 -VerifyRevocation  # optional: waits for and verifies lease revocation
.\scripts\rotate-minio.ps1
```

Stop and remove the local cluster:

```powershell
.\scripts\down.ps1
```

## Run with Bash

From the repository root:

```bash
cd v2
bash ./scripts/up.sh
```

The command performs the same deployment and end-to-end verification as the PowerShell version. Open [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs), or call the demo directly:

```bash
curl -fsS -X POST http://127.0.0.1:8080/demo \
  -H 'content-type: application/json' \
  -d '{"content":"hello from Bash"}'
```

Demonstrate credential rotation:

```bash
bash ./scripts/rotate-postgres.sh
bash ./scripts/rotate-postgres.sh --verify-revocation  # optional: waits for and verifies lease revocation
bash ./scripts/rotate-minio.sh
```

Stop and remove the local cluster:

```bash
bash ./scripts/down.sh
```

By default, teardown preserves the local Git-ignored bootstrap files so the environment can be recreated with the same values. To remove them as well, use `-PurgeSecrets` in PowerShell or `--purge-secrets` in Bash. This deletion is irreversible.

See [`DECISIONS.md`](DECISIONS.md) for the short decision log requested for the live session. The version-specific READMEs contain implementation details and pinned component versions.

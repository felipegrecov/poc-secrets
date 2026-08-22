# Decision log

*Cloud provider: Felipe Santana Services · Region: Tilburg · Node: PC Gamer*

I built two versions on purpose. `v1` is a small PoC that proves the basic flow. `v2` shows how I would improve secret management and credential rotation. It is safer for the application, but it also gives the platform team more work.

## What I built and checked with my big friend Codex (only two start prompts without skills, rules, guardrails, specs, or any agentic approach: https://specs.md/)

- `v1` is the simple starting point. I built it from a prompt as part of a 30-minute work task (basically, coffee-break time) with GPT-5.6 Codex using high reasoning. It uses kind, FastAPI, CloudNativePG, and MinIO. Local credentials are stored in Kubernetes Secrets with limited access.
- `v2` came from a second prompt and took 15 minutes (time for a breather). It keeps the same storage flow, but the application now gets its credentials through OpenBao and CSI. PostgreSQL users are short-lived, and MinIO credentials can be rotated.

## Main trade-offs

- **OpenBao improves security, but adds work:** It creates short-lived PostgreSQL users and gives us one place to manage access. But it is also another important service that needs security, upgrades, backups, monitoring and recovery.
- **CloudNativePG adds a component, but helps manage the database:** It makes database setup, health checks and upgrades easier. It also gives us a better path to backups and high availability than writing our own StatefulSet.
- **PostgreSQL and MinIO are separate:** PostgreSQL stores the metadata and MinIO stores the files. The API writes the file first. If the database write fails, it tries to delete the file. This is not fully atomic, so production would still need protection against duplicate requests and files left behind.
- **The API has limited access:** It does not receive MinIO root credentials, OpenBao root credentials, access to Kubernetes Secrets or a default Kubernetes API token. Some credentials are still needed to start the local environment. `v2` reduces the risk.
- **Credential rotation needs a new pod:** The application reads the CSI-mounted credentials when it starts. Rotation therefore starts a controlled rollout and waits until the new pod is ready. This is slower than reloading credentials inside the application, but it is easier to understand and roll back.

## What I left out of the timebox

- I did not build a real multi-zone cluster, distributed object storage or automatic disaster recovery.
- I did not test backups and restores or define recovery targets such as RTO and RPO.
- I did not use an external OpenBao service or build an emergency access process.
- I did not add GitOps, policy checks, full monitoring, SLOs or performance tests.
- I did not build the same solution on EKS or AKS. For a production system running in one cloud, I would first look at the cloud's workload identity, managed databases, object storage and secret services before deciding to run OpenBao myself.

## How I would take this to production

- **Choose how to manage identity and secrets:** I would compare the cloud's own services with a highly available OpenBao setup. Then I would document the choice and make it clear which team owns each part. I would also add TLS, limited access, credential rotation, audit logs, secure unsealing and a tested recovery process.
- **Make the data safe and recoverable:** I would run PostgreSQL and object storage across different zones. I would use managed services when they reduce risk and maintenance. I would add encryption, backups, versioning and retention, then test that the data can really be restored. I would also make retries safe and clean up files left without database records.
- **Create a safe standard for other teams:** I would add reviewed GitOps and CI workflows, security checks for code, dependencies and images, network isolation, metrics, traces and SLOs. I would test capacity and failures, write simple incident runbooks and make it clear who decides what.
- **Keep secrets out of Git:** I would run Gitleaks in a local pre-commit hook and in CI. Branch protection would block a merge when the CI scan fails. A local hook can be skipped, so CI is the real protection. If a secret still reaches Git history, I would rotate it first and then remove it from the history.

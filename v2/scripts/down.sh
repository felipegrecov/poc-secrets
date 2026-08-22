#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND="$(command -v kind || true)"
if [[ -z "$KIND" ]]; then
  KIND="$PROJECT_ROOT/.tools/kind"
fi
"$KIND" delete cluster --name datenna-openbao

if [[ "${1:-}" == "--purge-secrets" ]]; then
  rm -f -- "$PROJECT_ROOT/.secrets.env"
  rm -f -- "$PROJECT_ROOT/.openbao-bootstrap.json"
  echo ".secrets.env and .openbao-bootstrap.json deleted; they cannot be recovered."
fi

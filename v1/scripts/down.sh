#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND="$(command -v kind || true)"
if [[ -z "$KIND" ]]; then
  KIND="$PROJECT_ROOT/.tools/kind"
fi
"$KIND" delete cluster --name datenna-exercise

if [[ "${1:-}" == "--purge-secrets" ]]; then
  rm -f -- "$PROJECT_ROOT/.secrets.env"
  echo ".secrets.env deleted; it cannot be recovered from this project."
fi


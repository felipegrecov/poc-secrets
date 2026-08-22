#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL="$(command -v kubectl || true)"
[[ -n "$KUBECTL" ]] || KUBECTL="$PROJECT_ROOT/.tools/kubectl"
[[ -x "$KUBECTL" ]] || { echo "kubectl was not found" >&2; exit 1; }

current_pod() {
  "$KUBECTL" get pods -n datenna-demo -l app.kubernetes.io/name=datenna-app -o jsonpath='{.items[0].metadata.name}'
}

OLD_POD="$(current_pod)"
OLD_USER="$("$KUBECTL" exec -n datenna-demo "$OLD_POD" -- cat /var/run/secrets/datenna/postgres-username)"
"$KUBECTL" rollout restart deployment/datenna-app -n datenna-demo
"$KUBECTL" rollout status deployment/datenna-app -n datenna-demo --timeout=5m
NEW_POD="$(current_pod)"
NEW_USER="$("$KUBECTL" exec -n datenna-demo "$NEW_POD" -- cat /var/run/secrets/datenna/postgres-username)"
[[ "$NEW_USER" != "$OLD_USER" ]] || { echo "OpenBao returned the same PostgreSQL identity" >&2; exit 1; }
echo "PostgreSQL identity rotated: $OLD_USER -> $NEW_USER"
echo "The old identity remains valid only until its OpenBao lease is revoked or expires."

if [[ "${1:-}" == "--verify-revocation" ]]; then
  echo "Waiting 150 seconds (the configured default lease is 2 minutes)..."
  sleep 150
  EXISTS="$("$KUBECTL" exec -n datenna-demo postgres-1 -- psql -d datenna -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$OLD_USER'")"
  [[ -z "$EXISTS" ]] || { echo "Old PostgreSQL role still exists: $OLD_USER" >&2; exit 1; }
  echo "Verified: the expired PostgreSQL role was revoked and dropped."
fi

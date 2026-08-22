#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL="$(command -v kubectl || true)"
[[ -n "$KUBECTL" ]] || KUBECTL="$PROJECT_ROOT/.tools/kubectl"
[[ -x "$KUBECTL" ]] || { echo "kubectl was not found" >&2; exit 1; }
BOOTSTRAP_FILE="$PROJECT_ROOT/.openbao-bootstrap.json"
[[ -f "$BOOTSTRAP_FILE" ]] || { echo ".openbao-bootstrap.json is required" >&2; exit 1; }
ROOT_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root_token"])' "$BOOTSTRAP_FILE")"

bao() { "$KUBECTL" exec -n openbao openbao-0 -- env "BAO_TOKEN=$ROOT_TOKEN" bao "$@"; }
bao_stdin() { "$KUBECTL" exec -i -n openbao openbao-0 -- env "BAO_TOKEN=$ROOT_TOKEN" bao "$@"; }

minio_operation() {
  local action="$1" access_key="$2" secret_key="$3"
  "$KUBECTL" delete job minio-user-operation -n datenna-demo --ignore-not-found >/dev/null
  "$KUBECTL" create secret generic minio-user-operation -n datenna-demo \
    --from-literal="action=$action" --from-literal="access-key=$access_key" \
    --from-literal="secret-key=$secret_key" --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
  "$KUBECTL" apply -f "$PROJECT_ROOT/k8s/minio-user-operation.yaml" >/dev/null
  "$KUBECTL" wait --for=condition=complete job/minio-user-operation -n datenna-demo --timeout=3m >/dev/null
}

ACTIVE_JSON="$(bao read -format=json kv/data/minio/datenna-app-active)"
OLD_COLOR="$(printf '%s' "$ACTIVE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["color"])')"
OLD_ACCESS_KEY="$(printf '%s' "$ACTIVE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["access-key"])')"
OLD_SECRET_KEY="$(printf '%s' "$ACTIVE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["secret-key"])')"
if [[ "$OLD_COLOR" == "blue" ]]; then NEW_COLOR="green"; else NEW_COLOR="blue"; fi
NEW_ACCESS_KEY="app-$NEW_COLOR-$(openssl rand -hex 8)"
NEW_SECRET_KEY="$(openssl rand -hex 24)"
INACTIVE_JSON="$(bao read -format=json "kv/data/minio/datenna-app-$NEW_COLOR")"
INACTIVE_ACCESS_KEY="$(printf '%s' "$INACTIVE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["access-key"])')"
SWITCHED=false

write_kv() {
  local path="$1" color="$2" access_key="$3" secret_key="$4"
  COLOR="$color" ACCESS_KEY="$access_key" SECRET_KEY="$secret_key" python3 -c 'import json,os; print(json.dumps({"data":{"color":os.environ["COLOR"],"access-key":os.environ["ACCESS_KEY"],"secret-key":os.environ["SECRET_KEY"]}}))' | bao_stdin write "kv/data/minio/$path" - >/dev/null
}

cleanup() { "$KUBECTL" delete secret minio-user-operation -n datenna-demo --ignore-not-found >/dev/null 2>&1 || true; }
rollback() {
  local rc=$?
  if [[ "$SWITCHED" == "true" ]]; then
    echo "Rotation failed after the KV switch; restoring the previous active slot." >&2
    write_kv datenna-app-active "$OLD_COLOR" "$OLD_ACCESS_KEY" "$OLD_SECRET_KEY" || true
    "$KUBECTL" rollout restart deployment/datenna-app -n datenna-demo >/dev/null || true
    "$KUBECTL" rollout status deployment/datenna-app -n datenna-demo --timeout=5m >/dev/null || true
  fi
  minio_operation disable "$NEW_ACCESS_KEY" unused >/dev/null 2>&1 || true
  cleanup
  exit "$rc"
}
trap rollback ERR
trap cleanup EXIT

minio_operation remove "$INACTIVE_ACCESS_KEY" unused
minio_operation create "$NEW_ACCESS_KEY" "$NEW_SECRET_KEY"
write_kv "datenna-app-$NEW_COLOR" "$NEW_COLOR" "$NEW_ACCESS_KEY" "$NEW_SECRET_KEY"
write_kv datenna-app-active "$NEW_COLOR" "$NEW_ACCESS_KEY" "$NEW_SECRET_KEY"
SWITCHED=true
"$KUBECTL" rollout restart deployment/datenna-app -n datenna-demo >/dev/null
"$KUBECTL" rollout status deployment/datenna-app -n datenna-demo --timeout=5m >/dev/null
DEMO_VERIFIED=false
for _ in {1..15}; do
  if curl -fsS -X POST http://127.0.0.1:8080/demo -H 'content-type: application/json' \
    -d '{"content":"MinIO blue-green rotation verification"}' | grep -q '"verified":true'; then
    DEMO_VERIFIED=true
    break
  fi
  sleep 2
done
[[ "$DEMO_VERIFIED" == "true" ]] || { echo "The post-rotation demo failed" >&2; false; }
minio_operation disable "$OLD_ACCESS_KEY" unused
trap - ERR
echo "MinIO switched $OLD_COLOR -> $NEW_COLOR; the old user is disabled."

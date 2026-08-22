#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$PROJECT_ROOT/.tools"
CLUSTER_NAME="datenna-openbao"
NAMESPACE="datenna-demo"
OPENBAO_NAMESPACE="openbao"
KIND_VERSION="v0.32.0"
KUBECTL_VERSION="v1.35.0"
HELM_VERSION="v3.21.0"
CNPG_VERSION="1.30.0"
OPENBAO_CHART_VERSION="0.29.1"
CSI_DRIVER_VERSION="1.6.0"
mkdir -p "$TOOLS_DIR"

verify_sha256() {
  local file="$1" expected="$2" actual
  if command -v sha256sum >/dev/null; then actual="$(sha256sum "$file" | awk '{print $1}')"
  else actual="$(shasum -a 256 "$file" | awk '{print $1}')"; fi
  [[ "$actual" == "$expected" ]] || { echo "SHA-256 verification failed for $file" >&2; exit 1; }
}

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
case "$(uname -s)" in
  Linux) OS="linux" ;;
  Darwin) OS="darwin" ;;
  *) echo "Use scripts/up.ps1 on Windows." >&2; exit 1 ;;
esac

command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required for safe JSON handling." >&2; exit 1; }
docker info >/dev/null

KIND="$(command -v kind || true)"
if [[ -z "$KIND" ]]; then
  KIND="$TOOLS_DIR/kind"
  if [[ ! -x "$KIND" ]]; then
    curl -fsSL -o "$KIND" "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-$OS-$ARCH"
    chmod +x "$KIND"
  fi
  KIND_SHA="$(curl -fsSL "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-$OS-$ARCH.sha256sum" | awk '{print $1}')"
  verify_sha256 "$KIND" "$KIND_SHA"
fi

KUBECTL="$(command -v kubectl || true)"
if [[ -z "$KUBECTL" ]]; then
  KUBECTL="$TOOLS_DIR/kubectl"
  if [[ ! -x "$KUBECTL" ]]; then
    curl -fsSL -o "$KUBECTL" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl"
    chmod +x "$KUBECTL"
  fi
  KUBECTL_SHA="$(curl -fsSL "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl.sha256")"
  verify_sha256 "$KUBECTL" "$KUBECTL_SHA"
fi

HELM="$(command -v helm || true)"
if [[ -z "$HELM" ]]; then
  HELM="$TOOLS_DIR/helm"
  if [[ ! -x "$HELM" ]]; then
    HELM_ARCHIVE="$TOOLS_DIR/helm-$HELM_VERSION-$OS-$ARCH.tar.gz"
    HELM_URL="https://get.helm.sh/helm-$HELM_VERSION-$OS-$ARCH.tar.gz"
    curl -fsSL -o "$HELM_ARCHIVE" "$HELM_URL"
    HELM_SHA="$(curl -fsSL "$HELM_URL.sha256sum" | awk '{print $1}')"
    verify_sha256 "$HELM_ARCHIVE" "$HELM_SHA"
    tar -xzf "$HELM_ARCHIVE" -C "$TOOLS_DIR" "$OS-$ARCH/helm"
    mv "$TOOLS_DIR/$OS-$ARCH/helm" "$HELM"
    rmdir "$TOOLS_DIR/$OS-$ARCH"
    rm -f -- "$HELM_ARCHIVE"
    chmod +x "$HELM"
  fi
fi

SECRETS_FILE="$PROJECT_ROOT/.secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
  umask 077
  {
    printf 'MINIO_ROOT_USER=root-%s\n' "$(openssl rand -hex 8)"
    printf 'MINIO_ROOT_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'MINIO_BLUE_ACCESS_KEY=app-blue-%s\n' "$(openssl rand -hex 8)"
    printf 'MINIO_BLUE_SECRET_KEY=%s\n' "$(openssl rand -hex 24)"
    printf 'MINIO_GREEN_ACCESS_KEY=app-green-%s\n' "$(openssl rand -hex 8)"
    printf 'MINIO_GREEN_SECRET_KEY=%s\n' "$(openssl rand -hex 24)"
  } > "$SECRETS_FILE"
  echo "Generated .secrets.env (Git-ignored; values are not printed)."
fi
set -a
source "$SECRETS_FILE"
set +a
: "${MINIO_ROOT_USER:?}" "${MINIO_ROOT_PASSWORD:?}" "${MINIO_BLUE_ACCESS_KEY:?}" \
  "${MINIO_BLUE_SECRET_KEY:?}" "${MINIO_GREEN_ACCESS_KEY:?}" "${MINIO_GREEN_SECRET_KEY:?}"

if ! "$KIND" get clusters | grep -Fxq "$CLUSTER_NAME"; then
  "$KIND" create cluster --name "$CLUSTER_NAME" --config "$PROJECT_ROOT/infra/kind.yaml" --wait 5m
fi

docker build -t datenna-minio:2025-10-15 "$PROJECT_ROOT/infra/minio"
docker build -t datenna-app:openbao "$PROJECT_ROOT"
"$KIND" load docker-image datenna-minio:2025-10-15 --name "$CLUSTER_NAME"
"$KIND" load docker-image datenna-app:openbao --name "$CLUSTER_NAME"

"$KUBECTL" apply --server-side -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-$CNPG_VERSION.yaml"
"$KUBECTL" rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=5m
"$HELM" upgrade --install secrets-store-csi-driver secrets-store-csi-driver \
  --repo https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts \
  --version "$CSI_DRIVER_VERSION" -n kube-system \
  --set-string 'tokenRequests[0].audience=openbao' --wait --timeout 5m
"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/namespace.yaml"

"$KUBECTL" create secret generic minio-root -n "$NAMESPACE" \
  --from-literal="username=$MINIO_ROOT_USER" --from-literal="password=$MINIO_ROOT_PASSWORD" \
  --dry-run=client -o yaml | "$KUBECTL" apply -f -
MINIO_NEEDS_BOOTSTRAP=false
if ! "$KUBECTL" get configmap minio-bootstrap-state -n "$NAMESPACE" >/dev/null 2>&1; then
  MINIO_NEEDS_BOOTSTRAP=true
  "$KUBECTL" create secret generic minio-app-bootstrap -n "$NAMESPACE" \
    --from-literal="blue-access-key=$MINIO_BLUE_ACCESS_KEY" \
    --from-literal="blue-secret-key=$MINIO_BLUE_SECRET_KEY" \
    --from-literal="green-access-key=$MINIO_GREEN_ACCESS_KEY" \
    --from-literal="green-secret-key=$MINIO_GREEN_SECRET_KEY" \
    --dry-run=client -o yaml | "$KUBECTL" apply -f -
fi

"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/postgres.yaml"
"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/minio.yaml"
"$KUBECTL" rollout status deployment/minio -n "$NAMESPACE" --timeout=5m
if [[ "$MINIO_NEEDS_BOOTSTRAP" == "true" ]]; then
  "$KUBECTL" delete job minio-bootstrap -n "$NAMESPACE" --ignore-not-found
  "$KUBECTL" apply -f "$PROJECT_ROOT/k8s/minio-bootstrap.yaml"
  "$KUBECTL" wait --for=condition=complete job/minio-bootstrap -n "$NAMESPACE" --timeout=3m
  "$KUBECTL" create configmap minio-bootstrap-state -n "$NAMESPACE" --from-literal=complete=true \
    --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
  "$KUBECTL" delete secret minio-app-bootstrap -n "$NAMESPACE" --ignore-not-found >/dev/null
fi
"$KUBECTL" wait --for=condition=Ready cluster/postgres -n "$NAMESPACE" --timeout=5m

"$HELM" upgrade --install openbao openbao --repo https://openbao.github.io/openbao-helm \
  --version "$OPENBAO_CHART_VERSION" -n "$OPENBAO_NAMESPACE" --create-namespace \
  -f "$PROJECT_ROOT/k8s/openbao-values.yaml"
for pod in openbao-0 openbao-1 openbao-2; do
  for _ in $(seq 1 90); do
    [[ "$("$KUBECTL" get pod "$pod" -n "$OPENBAO_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)" == "Running" ]] && break
    sleep 2
  done
  [[ "$("$KUBECTL" get pod "$pod" -n "$OPENBAO_NAMESPACE" -o jsonpath='{.status.phase}')" == "Running" ]]
done

BOOTSTRAP_FILE="$PROJECT_ROOT/.openbao-bootstrap.json"
STATUS_JSON="$("$KUBECTL" exec -n "$OPENBAO_NAMESPACE" openbao-0 -- bao status -format=json 2>/dev/null || true)"
INITIALIZED="$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["initialized"]).lower())')"
if [[ "$INITIALIZED" != "true" ]]; then
  INIT_JSON="$("$KUBECTL" exec -n "$OPENBAO_NAMESPACE" openbao-0 -- bao operator init -format=json -key-shares=1 -key-threshold=1)"
  umask 077
  printf '%s' "$INIT_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); json.dump({"unseal_key":d["unseal_keys_b64"][0],"root_token":d["root_token"]},sys.stdout)' > "$BOOTSTRAP_FILE"
  echo "Stored Git-ignored local OpenBao bootstrap material in .openbao-bootstrap.json."
fi
[[ -f "$BOOTSTRAP_FILE" ]] || { echo "Initialized OpenBao requires .openbao-bootstrap.json" >&2; exit 1; }
UNSEAL_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["unseal_key"])' "$BOOTSTRAP_FILE")"
ROOT_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root_token"])' "$BOOTSTRAP_FILE")"

for pod in openbao-0 openbao-1 openbao-2; do
  POD_STATUS="$("$KUBECTL" exec -n "$OPENBAO_NAMESPACE" "$pod" -- bao status -format=json 2>/dev/null || true)"
  POD_INITIALIZED="$(printf '%s' "$POD_STATUS" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["initialized"]).lower())')"
  if [[ "$pod" != "openbao-0" && "$POD_INITIALIZED" != "true" ]]; then
    "$KUBECTL" exec -n "$OPENBAO_NAMESPACE" "$pod" -- bao operator raft join http://openbao-0.openbao-internal:8200
  fi
  POD_STATUS="$("$KUBECTL" exec -n "$OPENBAO_NAMESPACE" "$pod" -- bao status -format=json 2>/dev/null || true)"
  SEALED="$(printf '%s' "$POD_STATUS" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["sealed"]).lower())')"
  [[ "$SEALED" != "true" ]] || "$KUBECTL" exec -n "$OPENBAO_NAMESPACE" "$pod" -- bao operator unseal "$UNSEAL_KEY" >/dev/null
done
"$KUBECTL" wait --for=condition=Ready pod/openbao-0 pod/openbao-1 pod/openbao-2 -n "$OPENBAO_NAMESPACE" --timeout=5m

bao() { "$KUBECTL" exec -n "$OPENBAO_NAMESPACE" openbao-0 -- env "BAO_TOKEN=$ROOT_TOKEN" bao "$@"; }
bao_stdin() { "$KUBECTL" exec -i -n "$OPENBAO_NAMESPACE" openbao-0 -- env "BAO_TOKEN=$ROOT_TOKEN" bao "$@"; }
bao secrets list -format=json | python3 -c 'import json,sys; raise SystemExit(0 if "database/" in json.load(sys.stdin) else 1)' || bao secrets enable database
bao secrets list -format=json | python3 -c 'import json,sys; raise SystemExit(0 if "kv/" in json.load(sys.stdin) else 1)' || bao secrets enable -path=kv kv-v2
bao auth list -format=json | python3 -c 'import json,sys; raise SystemExit(0 if "kubernetes/" in json.load(sys.stdin) else 1)' || bao auth enable kubernetes

PG_USER_B64="$("$KUBECTL" get secret postgres-superuser -n "$NAMESPACE" -o jsonpath='{.data.username}')"
PG_PASSWORD_B64="$("$KUBECTL" get secret postgres-superuser -n "$NAMESPACE" -o jsonpath='{.data.password}')"
PG_USER="$(printf '%s' "$PG_USER_B64" | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode())')"
PG_PASSWORD="$(printf '%s' "$PG_PASSWORD_B64" | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode())')"

PG_USER="$PG_USER" PG_PASSWORD="$PG_PASSWORD" python3 -c 'import json,os; print(json.dumps({"plugin_name":"postgresql-database-plugin","allowed_roles":["datenna-app"],"connection_url":"postgresql://{{username}}:{{password}}@postgres-rw.datenna-demo.svc.cluster.local:5432/datenna?sslmode=require","username":os.environ["PG_USER"],"password":os.environ["PG_PASSWORD"]}))' | bao_stdin write database/config/postgres - >/dev/null
cat <<'JSON' | bao_stdin write database/roles/datenna-app - >/dev/null
{"db_name":"postgres","default_ttl":"2m","max_ttl":"10m","creation_statements":["CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT datenna_runtime TO \"{{name}}\";"],"revocation_statements":["REASSIGN OWNED BY \"{{name}}\" TO postgres; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";"]}
JSON
printf '%s' '{"kubernetes_host":"https://kubernetes.default.svc:443"}' | bao_stdin write auth/kubernetes/config - >/dev/null
printf '%s' '{"bound_service_account_names":["datenna-app"],"bound_service_account_namespaces":["datenna-demo"],"audience":"openbao","token_policies":["datenna-app"],"token_ttl":"10m"}' | bao_stdin write auth/kubernetes/role/datenna-app - >/dev/null
cat <<'POLICY' | bao_stdin policy write datenna-app - >/dev/null
path "database/creds/datenna-app" {
  capabilities = ["read"]
}
path "kv/data/minio/datenna-app-active" {
  capabilities = ["read"]
}
POLICY

write_minio_kv() {
  local path="$1" color="$2" access_key="$3" secret_key="$4"
  COLOR="$color" ACCESS_KEY="$access_key" SECRET_KEY="$secret_key" python3 -c 'import json,os; print(json.dumps({"data":{"color":os.environ["COLOR"],"access-key":os.environ["ACCESS_KEY"],"secret-key":os.environ["SECRET_KEY"]}}))' | bao_stdin write "kv/data/minio/$path" - >/dev/null
}
if ! bao read -format=json kv/data/minio/datenna-app-active >/dev/null 2>&1; then
  write_minio_kv datenna-app-blue blue "$MINIO_BLUE_ACCESS_KEY" "$MINIO_BLUE_SECRET_KEY"
  write_minio_kv datenna-app-green green "$MINIO_GREEN_ACCESS_KEY" "$MINIO_GREEN_SECRET_KEY"
  write_minio_kv datenna-app-active blue "$MINIO_BLUE_ACCESS_KEY" "$MINIO_BLUE_SECRET_KEY"
else
  echo "Preserving the existing MinIO blue/green KV state."
fi

"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/openbao-secret-provider.yaml"
"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/app.yaml"
"$KUBECTL" set image deployment/datenna-app api=datenna-app:openbao -n "$NAMESPACE"
"$KUBECTL" rollout status deployment/datenna-app -n "$NAMESPACE" --timeout=5m
DEMO_RESPONSE="$(curl -fsS -X POST http://127.0.0.1:8080/demo -H 'content-type: application/json' -d "{\"content\":\"OpenBao end-to-end demo $(date -u +%FT%TZ)\"}")"
printf '%s' "$DEMO_RESPONSE" | grep -q '"verified":true'
echo "Ready: http://127.0.0.1:8080/docs"
echo "PostgreSQL credentials are dynamic; MinIO uses the blue KV slot."

#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$PROJECT_ROOT/.tools"
CLUSTER_NAME="datenna-exercise"
NAMESPACE="datenna-demo"
KIND_VERSION="v0.32.0"
KUBECTL_VERSION="v1.35.0"
CNPG_VERSION="1.30.0"

mkdir -p "$TOOLS_DIR"

verify_sha256() {
  local file="$1" expected="$2" actual
  if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  fi
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

SECRETS_FILE="$PROJECT_ROOT/.secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
  umask 077
  {
    printf 'POSTGRES_USER=datenna_app\n'
    printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'MINIO_ROOT_USER=root-%s\n' "$(openssl rand -hex 8)"
    printf 'MINIO_ROOT_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'MINIO_APP_ACCESS_KEY=app-%s\n' "$(openssl rand -hex 8)"
    printf 'MINIO_APP_SECRET_KEY=%s\n' "$(openssl rand -hex 24)"
  } > "$SECRETS_FILE"
  echo "Generated .secrets.env (Git-ignored; values are not printed)."
fi
set -a
source "$SECRETS_FILE"
set +a

if ! "$KIND" get clusters | grep -Fxq "$CLUSTER_NAME"; then
  "$KIND" create cluster --name "$CLUSTER_NAME" --config "$PROJECT_ROOT/infra/kind.yaml" --wait 5m
fi

docker build -t datenna-minio:2025-10-15 "$PROJECT_ROOT/infra/minio"
docker build -t datenna-app:local "$PROJECT_ROOT"
"$KIND" load docker-image datenna-minio:2025-10-15 --name "$CLUSTER_NAME"
"$KIND" load docker-image datenna-app:local --name "$CLUSTER_NAME"

"$KUBECTL" apply --server-side -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-$CNPG_VERSION.yaml"
"$KUBECTL" rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=5m
"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/namespace.yaml"

"$KUBECTL" create secret generic postgres-app -n "$NAMESPACE" \
  --type=kubernetes.io/basic-auth \
  --from-literal="username=$POSTGRES_USER" \
  --from-literal="password=$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | "$KUBECTL" apply -f -
"$KUBECTL" create secret generic minio-root -n "$NAMESPACE" \
  --from-literal="username=$MINIO_ROOT_USER" \
  --from-literal="password=$MINIO_ROOT_PASSWORD" \
  --dry-run=client -o yaml | "$KUBECTL" apply -f -
"$KUBECTL" create secret generic minio-app -n "$NAMESPACE" \
  --from-literal="access-key=$MINIO_APP_ACCESS_KEY" \
  --from-literal="secret-key=$MINIO_APP_SECRET_KEY" \
  --dry-run=client -o yaml | "$KUBECTL" apply -f -

"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/postgres.yaml"
"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/minio.yaml"
"$KUBECTL" rollout status deployment/minio -n "$NAMESPACE" --timeout=5m
"$KUBECTL" delete job minio-bootstrap -n "$NAMESPACE" --ignore-not-found
"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/minio-bootstrap.yaml"
"$KUBECTL" wait --for=condition=complete job/minio-bootstrap -n "$NAMESPACE" --timeout=3m
"$KUBECTL" wait --for=condition=Ready cluster/postgres -n "$NAMESPACE" --timeout=5m
"$KUBECTL" apply -f "$PROJECT_ROOT/k8s/app.yaml"
"$KUBECTL" rollout status deployment/datenna-app -n "$NAMESPACE" --timeout=5m

DEMO_RESPONSE="$(curl -fsS -X POST http://127.0.0.1:8080/demo \
  -H 'content-type: application/json' \
  -d "{\"content\":\"end-to-end demo $(date -u +%FT%TZ)\"}")"
echo "$DEMO_RESPONSE" | grep -q '"verified":true'
echo "Ready: http://127.0.0.1:8080/docs"

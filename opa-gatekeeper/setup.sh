#!/usr/bin/env bash
# setup.sh - create the demo cluster and install Gatekeeper
# Run this ONCE before the talk. Idempotent: safe to re-run.

set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="opa-demo"
GATEKEEPER_VERSION="3.17.1"

# colors via printf (portable across macOS/Linux)
say()  { printf '\033[36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ---- prerequisites ---------------------------------------------------------
say "Checking prerequisites"
for cmd in kind kubectl helm; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed"
  ok "$cmd: $(command -v "$cmd")"
done

# Detect podman vs docker. Prefer podman if KIND_EXPERIMENTAL_PROVIDER is set.
if [ "${KIND_EXPERIMENTAL_PROVIDER:-}" = "podman" ] || ! command -v docker >/dev/null 2>&1; then
  if command -v podman >/dev/null 2>&1; then
    export KIND_EXPERIMENTAL_PROVIDER=podman
    ok "Using podman provider"
  else
    die "Need either docker or podman"
  fi
else
  ok "Using docker provider"
fi

# ---- cluster ---------------------------------------------------------------
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  warn "Cluster '$CLUSTER_NAME' already exists, reusing it"
else
  say "Creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --name "$CLUSTER_NAME" --config kind-config.yaml
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
ok "Cluster ready"

# ---- gatekeeper ------------------------------------------------------------
say "Installing Gatekeeper ${GATEKEEPER_VERSION}"
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --version "$GATEKEEPER_VERSION" \
  --namespace gatekeeper-system --create-namespace \
  --set replicas=1 \
  --set auditInterval=30 \
  --wait --timeout 5m

ok "Gatekeeper installed"

say "Waiting for Gatekeeper webhook to be ready"
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager --timeout=180s
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-audit --timeout=180s
ok "Gatekeeper is serving"

# ---- demo namespace --------------------------------------------------------
say "Creating opa-demo namespace"
kubectl create namespace opa-demo --dry-run=client -o yaml | kubectl apply -f -
ok "Namespace ready"

printf '\n\033[32m\033[1mSetup complete.\033[0m Now run:  \033[36m./demo.sh\033[0m\n'

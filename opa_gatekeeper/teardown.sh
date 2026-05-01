#!/usr/bin/env bash
# teardown.sh - delete the demo cluster
set -euo pipefail
CLUSTER_NAME="opa-demo"

if [ -z "${KIND_EXPERIMENTAL_PROVIDER:-}" ] && command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
fi

echo "Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "$CLUSTER_NAME"
echo "Done."

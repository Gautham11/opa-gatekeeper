#!/usr/bin/env bash
# demo.sh - the live OPA / Gatekeeper demo
#
# Paces itself between steps so you can talk while it runs.
# Press ENTER to advance, or run with AUTO=1 to play through.
#
#   ./demo.sh           # interactive (recommended for live talk)
#   AUTO=1 ./demo.sh    # automatic, no prompts

set -uo pipefail
cd "$(dirname "$0")"

AUTO="${AUTO:-0}"
NS="opa-demo"

# ---- presentation helpers (portable: printf, not echo -e) ------------------
step() {
  local n="$1"; shift
  printf '\n\033[35m\033[1m━━━ Step %s ━━━\033[0m \033[1m%s\033[0m\n' "$n" "$*"
}

say()    { printf '\033[36m»\033[0m %s\n' "$*"; }
explain(){ printf '\033[2m%s\033[0m\n' "$*"; }
ok()     { printf '\033[32m✓\033[0m %s\n' "$*"; }
err()    { printf '\033[31m✗\033[0m %s\n' "$*"; }

# Show a command, then run it
run() {
  printf '\033[33m$\033[0m \033[1m%s\033[0m\n' "$*"
  eval "$@"
}

# Run a command we expect to FAIL (Gatekeeper denial). Show output, return 0.
run_expect_deny() {
  printf '\033[33m$\033[0m \033[1m%s\033[0m\n' "$*"
  if eval "$@" 2>&1; then
    err "Expected denial but command succeeded — check your constraints"
    return 1
  fi
  return 0
}

pause() {
  if [ "$AUTO" = "1" ]; then
    sleep 1.5
    return
  fi
  printf '\n\033[2m── press ENTER to continue ──\033[0m'
  read -r
}

# ---- preflight -------------------------------------------------------------
kubectl get ns gatekeeper-system >/dev/null 2>&1 \
  || { err "Gatekeeper not installed. Run ./setup.sh first."; exit 1; }

clear
cat <<'BANNER'
   ____  ____   _      ____                          _ _
  / __ \|  _ \ / \    / ___|  ___  ___ _   _ _ __  (_) |_ _   _
 | |  | | |_) / _ \   \___ \ / _ \/ __| | | | '__| | | __| | | |
 | |__| |  __/ ___ \   ___) |  __/ (__| |_| | |    | | |_| |_| |
  \____/|_| /_/   \_\ |____/ \___|\___|\__,_|_|    |_|\__|\__, |
                                                          |___/
              Live demo · Gatekeeper on Kubernetes
BANNER
echo
explain "We'll: install policies → try bad pods → see denials → ship a good pod → look at audit."
pause

# ---------------------------------------------------------------------------
step 1 "Show the cluster and that Gatekeeper is running"

run kubectl get nodes
echo
run kubectl -n gatekeeper-system get pods
explain "Notice: gatekeeper-controller-manager (the webhook) and gatekeeper-audit (background scanner)."
pause

# ---------------------------------------------------------------------------
step 2 "Install ConstraintTemplates — the 'classes' of policy"

# Apply each template explicitly so missing files break early
for f in template-01-required-labels.yaml template-02-allowed-repos.yaml template-03-no-privileged.yaml; do
  run kubectl apply -f "$f"
done
echo
sleep 2  # CRDs need a moment to register
explain "Each template registers a NEW CRD. Watch:"
run kubectl get constrainttemplates
pause

# ---------------------------------------------------------------------------
step 3 "Install Constraints — the 'instances' that enforce"

for f in constraint-01-required-labels.yaml constraint-02-allowed-repos.yaml constraint-03-no-privileged.yaml; do
  run kubectl apply -f "$f"
done
echo
sleep 2
explain "Constraints are scoped to namespace=opa-demo with enforcementAction=deny."
run kubectl get constraints
pause

# ---------------------------------------------------------------------------
step 4 "Try to create a Pod with NO labels (should be DENIED)"

explain "Expected: blocked by must-have-owner-and-env"
run_expect_deny "kubectl apply -f manifest-bad-1-no-labels.yaml"
pause

# ---------------------------------------------------------------------------
step 5 "Try a Pod with a BAD env value (regex violation)"

explain 'env: production violates the allowed regex ^(dev|staging|prod)$'
run_expect_deny "kubectl apply -f manifest-bad-2-wrong-env.yaml"
pause

# ---------------------------------------------------------------------------
step 6 "Try a Pod from an UNTRUSTED registry"

explain "Image pulled from docker.io — not in our allowed-prefix list."
run_expect_deny "kubectl apply -f manifest-bad-3-untrusted-registry.yaml"
pause

# ---------------------------------------------------------------------------
step 7 "Try a PRIVILEGED Pod"

explain "securityContext.privileged=true is blocked by K8sPSPPrivilegedContainer."
run_expect_deny "kubectl apply -f manifest-bad-4-privileged.yaml"
pause

# ---------------------------------------------------------------------------
step 8 "Apply a COMPLIANT Pod (should be admitted)"

run kubectl apply -f manifest-good-pod.yaml
sleep 2
run kubectl -n "$NS" get pod good-pod -o wide
ok "Good pod admitted."
pause

# ---------------------------------------------------------------------------
step 9 "Inspect violations across the cluster (audit)"

explain "Even resources that EXISTED before policies are scanned by the audit loop."
explain "Look at 'totalViolations' on each constraint:"
run "kubectl get k8srequiredlabels must-have-owner-and-env -o jsonpath='{.status.totalViolations}{\"\\n\"}'"
echo
run "kubectl get constraints -o custom-columns=KIND:.kind,NAME:.metadata.name,ACTION:.spec.enforcementAction,VIOLATIONS:.status.totalViolations"
pause

# ---------------------------------------------------------------------------
step 10 "Show a denial reason in detail (for one of the constraints)"

explain "Constraint status carries the actual violation messages from the audit loop:"
run "kubectl get k8srequiredlabels must-have-owner-and-env -o jsonpath='{range .status.violations[*]}{.kind}/{.name}: {.message}{\"\\n\"}{end}'"
pause

# ---------------------------------------------------------------------------
printf '\n\033[32m\033[1mDemo complete.\033[0m\n'
explain "Cleanup with:  ./teardown.sh"
echo

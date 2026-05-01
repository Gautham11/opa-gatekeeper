#!/usr/bin/env bash
# test.sh - run policy tests locally, before touching a cluster.
#
# Three layers, in order:
#   1. opa test       - Rego unit tests
#   2. gator verify   - ConstraintTemplate compilation + their inline tests
#   3. gator test     - end-to-end: real templates + constraints + manifests
#
# Each layer is independent. If `opa` or `gator` isn't installed,
# that layer is skipped with a note (so partial environments still work).

set -uo pipefail
cd "$(dirname "$0")"

header() { printf '\n\033[36m━━━ %s ━━━\033[0m\n' "$*"; }
ok()     { printf '\033[32m✓\033[0m %s\n' "$*"; }
skip()   { printf '\033[33m⊘\033[0m %s \033[2m(skipped)\033[0m\n' "$*"; }
fail()   { printf '\033[31m✗\033[0m %s\n' "$*"; }

failures=0

# ---- layer 1: opa test -----------------------------------------------------
header "Layer 1: opa test (Rego unit tests)"
if command -v opa >/dev/null 2>&1; then
  # opa test takes specific files or a directory; we pass the test files explicitly
  if opa test test-required-labels.rego test-required-labels-cases.rego \
              test-allowed-repos.rego  test-allowed-repos-cases.rego \
              test-no-privileged.rego  test-no-privileged-cases.rego -v; then
    ok "Rego unit tests passed"
  else
    fail "Rego unit tests FAILED"
    failures=$((failures+1))
  fi
else
  skip "opa not installed — install: brew install opa"
fi

# ---- layer 2: gator verify -------------------------------------------------
header "Layer 2: gator verify (templates compile, inline tests pass)"
if command -v gator >/dev/null 2>&1; then
  if gator verify gator-suite.yaml; then
    ok "Gator suite passed"
  else
    fail "Gator suite FAILED"
    failures=$((failures+1))
  fi
else
  skip "gator not installed — see https://open-policy-agent.github.io/gatekeeper/website/docs/gator"
fi

# ---- layer 3: gator test (one-shot dry-run) --------------------------------
header "Layer 3: gator test (manifests vs. real constraints)"
if command -v gator >/dev/null 2>&1; then
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  for f in template-*.yaml constraint-*.yaml manifest-*.yaml; do
    printf '%s\n' '---'  >> "$TMP"
    cat "$f"             >> "$TMP"
  done

  printf '\033[2mRunning:  gator test --filename=<bundle>\033[0m\n\n'
  output=$(gator test --filename="$TMP" 2>&1) || true
  printf '%s\n\n' "$output"

  bad_denied=$(printf '%s' "$output" | grep -cE 'bad-[0-9]+' || true)
  good_denied=$(printf '%s' "$output" | grep -cE 'good-pod' || true)
  if [ "$bad_denied" -ge 4 ] && [ "$good_denied" -eq 0 ]; then
    ok "Expected denials present, good-pod admitted ($bad_denied bad / $good_denied good)"
  else
    fail "Unexpected pattern: $bad_denied bad denials, $good_denied good denials"
    failures=$((failures+1))
  fi
else
  skip "gator not installed"
fi

# ---- summary ---------------------------------------------------------------
echo
if [ "$failures" -eq 0 ]; then
  printf '\033[32m\033[1mAll available test layers passed.\033[0m\n'
  exit 0
else
  printf '\033[31m\033[1m%d layer(s) failed.\033[0m\n' "$failures"
  exit 1
fi

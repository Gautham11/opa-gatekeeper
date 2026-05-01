#!/usr/bin/env bash
# rego-internals.sh - show OPA evaluation WITHOUT Kubernetes.
# Useful for the 'how does OPA actually evaluate?' question.
#
# Requires the `opa` CLI:  https://www.openpolicyagent.org/docs/latest/#1-download-opa

set -euo pipefail
cd "$(dirname "$0")"

command -v opa >/dev/null 2>&1 || {
  echo "Install the opa CLI first:  brew install opa" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/policy.rego" <<'REGO'
package kubernetes.admission

import future.keywords.if
import future.keywords.in

default allow := false

allow if {
  input.request.kind.kind == "Pod"
  not has_privileged_container
  has_required_labels
}

has_privileged_container if {
  some c in input.request.object.spec.containers
  c.securityContext.privileged == true
}

required_labels := {"owner", "env", "cost-center"}

has_required_labels if {
  provided := {l | input.request.object.metadata.labels[l]}
  count(required_labels - provided) == 0
}

deny[msg] if {
  has_privileged_container
  msg := "privileged containers are not allowed"
}

deny[msg] if {
  provided := {l | input.request.object.metadata.labels[l]}
  missing := required_labels - provided
  count(missing) > 0
  msg := sprintf("missing labels: %v", [missing])
}
REGO

cat > "$WORK/input-bad.json" <<'JSON'
{
  "request": {
    "kind": {"kind": "Pod"},
    "object": {
      "metadata": {"name": "bad-pod", "labels": {"owner": "alice"}},
      "spec": {
        "containers": [
          {"name": "app", "image": "nginx", "securityContext": {"privileged": true}}
        ]
      }
    }
  }
}
JSON

cat > "$WORK/input-good.json" <<'JSON'
{
  "request": {
    "kind": {"kind": "Pod"},
    "object": {
      "metadata": {
        "name": "good-pod",
        "labels": {"owner": "alice", "env": "prod", "cost-center": "cc-1234"}
      },
      "spec": {
        "containers": [
          {"name": "app", "image": "nginx", "securityContext": {"privileged": false}}
        ]
      }
    }
  }
}
JSON

hr() { printf '\033[2m────────────────────────────────────────\033[0m\n'; }

printf '\033[1mPolicy under test (Rego):\033[0m\n'
hr; cat "$WORK/policy.rego"; hr

printf '\n\033[1m1) Evaluate the BAD pod\033[0m  \033[2m(privileged + missing labels)\033[0m\n'
printf '\033[36m$ opa eval --format=pretty -d policy.rego -i input-bad.json '"'"'data.kubernetes.admission'"'"'\033[0m\n'
opa eval --format=pretty -d "$WORK/policy.rego" -i "$WORK/input-bad.json" 'data.kubernetes.admission'

printf '\n\033[1m2) Evaluate the GOOD pod\033[0m\n'
printf '\033[36m$ opa eval --format=pretty -d policy.rego -i input-good.json '"'"'data.kubernetes.admission'"'"'\033[0m\n'
opa eval --format=pretty -d "$WORK/policy.rego" -i "$WORK/input-good.json" 'data.kubernetes.admission'

printf '\n\033[1m3) Show the EXECUTION TRACE\033[0m \033[2m(this is the '"'"'internals'"'"' view)\033[0m\n'
printf '\033[36m$ opa eval --explain=fails --format=pretty -d policy.rego -i input-bad.json '"'"'data.kubernetes.admission.allow'"'"'\033[0m\n'
opa eval --explain=fails --format=pretty -d "$WORK/policy.rego" -i "$WORK/input-bad.json" 'data.kubernetes.admission.allow' || true

printf '\n\033[1m4) Show PARTIAL EVALUATION\033[0m \033[2m(how OPA pre-compiles policy for speed)\033[0m\n'
printf '\033[36m$ opa eval --partial --format=pretty -d policy.rego '"'"'data.kubernetes.admission.allow'"'"'\033[0m\n'
opa eval --partial --format=pretty -d "$WORK/policy.rego" 'data.kubernetes.admission.allow' || true

printf '\n\033[32m\033[1mInternals demo complete.\033[0m\n'

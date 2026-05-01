# OPA + Gatekeeper · Live Demo

A self-contained demo for an OPA security talk. Spins up a local Kubernetes
cluster (kind on podman or docker), installs Gatekeeper, applies a set of
real-world security policies, and walks through admission control denials
live in the terminal.

All files live at the project root (flat layout). File names start with a
prefix that tells you what kind of file it is:

- `template-*.yaml`   — ConstraintTemplates (the "classes")
- `constraint-*.yaml` — Constraints (the "instances")
- `manifest-*.yaml`   — Test pods (good and bad)
- `test-*.rego`       — Rego policies and unit tests for `opa test`
- `gator-suite.yaml`  — End-to-end test suite for `gator`
- `*.sh`              — Demo and tooling scripts

## What this demo covers

1. **Required labels** — every Pod must carry `owner`, `env`, `cost-center` (and `env` must match `dev|staging|prod`)
2. **Trusted registries** — only images from approved registries
3. **No privileged containers** — block `securityContext.privileged: true`

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| `kind` | Local K8s cluster | `brew install kind` |
| `kubectl` | Talk to the cluster | `brew install kubectl` |
| `helm` | Install Gatekeeper | `brew install helm` |
| `podman` *or* `docker` | Container runtime kind needs | `brew install podman` |
| `opa` *(optional)* | For the internals demo + Rego unit tests | `brew install opa` |
| `gator` *(optional)* | For end-to-end policy testing | [release page](https://github.com/open-policy-agent/gatekeeper/releases) |

If you're using podman, set this once in your shell:

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman
# on macOS, also:
podman machine init && podman machine start
```

## Quick start

```bash
# 1. one-time: create the cluster + install Gatekeeper (~2 min)
./setup.sh

# 2. the main demo (interactive — press ENTER between steps)
./demo.sh

# 2b. or play it through automatically (good for rehearsal)
AUTO=1 ./demo.sh

# 3. bonus: show OPA internals without K8s
./rego-internals.sh

# 4. run the policy test suite (no cluster needed)
./test.sh

# 5. cleanup
./teardown.sh
```

## File listing

```
setup.sh                                # create cluster + install Gatekeeper
demo.sh                                 # the live demo (paced, colored)
test.sh                                 # run all policy tests locally
rego-internals.sh                       # standalone OPA eval, no K8s
teardown.sh                             # delete cluster

kind-config.yaml                        # 1 control-plane + 1 worker

template-01-required-labels.yaml        # ConstraintTemplates
template-02-allowed-repos.yaml
template-03-no-privileged.yaml

constraint-01-required-labels.yaml      # Constraints (instances of templates)
constraint-02-allowed-repos.yaml
constraint-03-no-privileged.yaml

manifest-bad-1-no-labels.yaml           # Test pods that should be DENIED
manifest-bad-2-wrong-env.yaml
manifest-bad-3-untrusted-registry.yaml
manifest-bad-4-privileged.yaml
manifest-good-pod.yaml                  # Test pod that should be ADMITTED

test-required-labels.rego               # Rego sources + tests for `opa test`
test-required-labels-cases.rego
test-allowed-repos.rego
test-allowed-repos-cases.rego
test-no-privileged.rego
test-no-privileged-cases.rego

gator-suite.yaml                        # End-to-end test suite for `gator verify`

README.md
```

## Testing the policies

Three test layers, all runnable without a cluster:

### Layer 1 — `opa test` (Rego unit tests)

Tests the Rego logic in isolation by stubbing `input` directly. Fast (sub-second) and great for TDD on policy changes.

```bash
opa test test-*.rego -v
```

### Layer 2 — `gator verify` (template compilation)

Confirms each ConstraintTemplate compiles, schemas are valid, and the Rego parses inside Gatekeeper's runtime. Catches issues that `opa test` can't, like CRD schema typos.

```bash
gator verify gator-suite.yaml
```

### Layer 3 — `gator test` (end-to-end)

Runs the *real* templates + constraints + manifests through Gatekeeper's evaluation engine — same code path that runs in-cluster, but offline.

### One-liner for all three

```bash
./test.sh
```

Skips layers gracefully if `opa` or `gator` isn't installed.

## Speaker notes

The `demo.sh` script pauses between every step so you can talk over it. Suggested narration:

- **Step 1** — Show `gatekeeper-controller-manager` and `gatekeeper-audit`. Mention: "the controller is the validating webhook; audit is the background scanner that finds existing violators."
- **Step 2** — When `kubectl get constrainttemplates` returns three CRDs: "These ARE new CRDs now. Anyone in this cluster can create instances of `K8sRequiredLabels`."
- **Steps 4–7** — Each denial. Read the message back to the audience: "see how the message comes from our Rego, not a generic K8s error."
- **Step 8** — The good pod is admitted. Pause for the win.
- **Step 9** — Pivot to audit. "What about resources that already existed before we wrote the policy?" Show `totalViolations` count.

## Common issues

- **Gatekeeper webhook timeouts** — the webhook can take 30–60s to come up after install. `setup.sh` waits for it; if you see flakes during the demo, run `kubectl -n gatekeeper-system get pods` to confirm everything's `Running`.
- **Podman on macOS** — make sure `podman machine` is running.
- **Audit count says 0 right after creation** — audit runs on an interval (we set 30s in setup). Either wait, or trigger it manually: `kubectl -n gatekeeper-system rollout restart deploy/gatekeeper-audit`.

## Going further

- `play.openpolicyagent.org` — interactive Rego playground (good for live Q&A)
- `github.com/open-policy-agent/gatekeeper-library` — 50+ ready-made policies
- `conftest test` — same Rego, but against arbitrary YAML/JSON outside of Kubernetes

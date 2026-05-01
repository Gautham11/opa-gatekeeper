package k8spspprivilegedcontainer

import future.keywords.in

# Policy code
violation[{"msg": msg, "details": {}}] {
  c := input_containers[_]
  c.securityContext.privileged
  msg := sprintf(
    "Privileged container is not allowed: %v, securityContext: %v",
    [c.name, c.securityContext]
  )
}

input_containers[c] {
  c := input.review.object.spec.containers[_]
}

input_containers[c] {
  c := input.review.object.spec.initContainers[_]
}

# Test helpers
mock_pod(containers) := {
  "review": {"object": {"spec": {"containers": containers}}},
}

# Tests
test_non_privileged_passes {
  count(violation) == 0 with input as mock_pod([
    {"name": "app", "image": "nginx",
     "securityContext": {"privileged": false}},
  ])
}

test_no_security_context_passes {
  count(violation) == 0 with input as mock_pod([
    {"name": "app", "image": "nginx"},
  ])
}

test_privileged_true_violates {
  count(violation) == 1 with input as mock_pod([
    {"name": "evil", "image": "nginx",
     "securityContext": {"privileged": true}},
  ])
}

test_violation_names_container {
  some v in violation with input as mock_pod([
    {"name": "rooted", "image": "nginx",
     "securityContext": {"privileged": true}},
  ])
  contains(v.msg, "rooted")
}

test_init_container_privileged_violates {
  count(violation) == 1 with input as {
    "review": {"object": {"spec": {
      "containers":     [{"name": "main", "image": "nginx"}],
      "initContainers": [{"name": "init", "image": "busybox",
                          "securityContext": {"privileged": true}}],
    }}},
  }
}

test_one_of_many_privileged_violates {
  count(violation) == 1 with input as mock_pod([
    {"name": "good", "image": "nginx",
     "securityContext": {"privileged": false}},
    {"name": "bad",  "image": "nginx",
     "securityContext": {"privileged": true}},
  ])
}

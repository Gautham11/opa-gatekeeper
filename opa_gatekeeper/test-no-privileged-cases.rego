package k8spspprivilegedcontainer

mock_pod(containers) := {
  "review": {"object": {"spec": {"containers": containers}}},
}

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

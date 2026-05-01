package k8sallowedrepos

import future.keywords.in

# Policy code
violation[{"msg": msg}] {
  container := input.review.object.spec.containers[_]
  satisfied := [good |
    repo := input.parameters.repos[_]
    good := startswith(container.image, repo)
  ]
  not any(satisfied)
  msg := sprintf(
    "container <%v> uses disallowed image <%v>; allowed prefixes: %v",
    [container.name, container.image, input.parameters.repos]
  )
}

violation[{"msg": msg}] {
  container := input.review.object.spec.initContainers[_]
  satisfied := [good |
    repo := input.parameters.repos[_]
    good := startswith(container.image, repo)
  ]
  not any(satisfied)
  msg := sprintf(
    "init container <%v> uses disallowed image <%v>; allowed prefixes: %v",
    [container.name, container.image, input.parameters.repos]
  )
}

# Test helpers
default_params := {"repos": ["registry.k8s.io/", "quay.io/prometheus/"]}

mock_pod(containers) := {
  "parameters": default_params,
  "review": {"object": {"spec": {"containers": containers}}},
}

# Tests
test_trusted_image_passes {
  count(violation) == 0 with input as mock_pod([
    {"name": "app", "image": "registry.k8s.io/pause:3.9"},
  ])
}

test_untrusted_image_violates {
  count(violation) == 1 with input as mock_pod([
    {"name": "app", "image": "docker.io/library/nginx:1.25"},
  ])
}

test_violation_names_container {
  some v in violation with input as mock_pod([
    {"name": "evil", "image": "ghcr.io/foo/bar:latest"},
  ])
  contains(v.msg, "evil")
  contains(v.msg, "ghcr.io/foo/bar:latest")
}

test_one_bad_in_a_list_violates {
  count(violation) == 1 with input as mock_pod([
    {"name": "good", "image": "registry.k8s.io/pause:3.9"},
    {"name": "bad",  "image": "docker.io/library/nginx:1.25"},
  ])
}

test_init_containers_also_checked {
  count(violation) == 1 with input as {
    "parameters": default_params,
    "review": {"object": {"spec": {
      "containers":     [{"name": "app",  "image": "registry.k8s.io/pause:3.9"}],
      "initContainers": [{"name": "init", "image": "docker.io/busybox"}],
    }}},
  }
}

test_prefix_match_not_substring {
  count(violation) == 1 with input as mock_pod([
    {"name": "app", "image": "evil-registry.k8s.io/foo:1.0"},
  ])
}

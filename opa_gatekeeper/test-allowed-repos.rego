package k8sallowedrepos

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

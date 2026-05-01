package k8srequiredlabels

# Same logic as template-01-required-labels.yaml, in a standalone file
# so `opa test` can load it.

get_message(parameters, _default) := msg {
  not parameters.message
  msg := _default
}

get_message(parameters, _default) := msg {
  msg := parameters.message
}

violation[{"msg": msg, "details": {"missing_labels": missing}}] {
  provided := {label | input.review.object.metadata.labels[label]}
  required := {label | label := input.parameters.labels[_].key}
  missing := required - provided
  count(missing) > 0
  def_msg := sprintf("you must provide labels: %v", [missing])
  msg := get_message(input.parameters, def_msg)
}

violation[{"msg": msg}] {
  value := input.review.object.metadata.labels[key]
  expected := input.parameters.labels[_]
  expected.key == key
  expected.allowedRegex != ""
  not regex.match(expected.allowedRegex, value)
  def_msg := sprintf(
    "label <%v> value %q does not match pattern %q",
    [key, value, expected.allowedRegex]
  )
  msg := get_message(input.parameters, def_msg)
}

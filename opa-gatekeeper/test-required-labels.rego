package k8srequiredlabels

import future.keywords.in

# Unit tests for the required-labels policy.
# Run with:  opa test . -v

# Policy code
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

# Test helpers
default_params := {"labels": [
  {"key": "owner"},
  {"key": "env", "allowedRegex": "^(dev|staging|prod)$"},
  {"key": "cost-center", "allowedRegex": "^cc-[0-9]{4}$"},
]}

mock_input(labels) := {
  "parameters": default_params,
  "review": {"object": {"metadata": {"labels": labels}}},
}

test_all_required_labels_passes {
  count(violation) == 0 with input as mock_input({
    "owner": "alice",
    "env": "prod",
    "cost-center": "cc-1234",
  })
}

test_missing_all_labels_violates {
  count(violation) >= 1 with input as mock_input({})
}

test_missing_one_label_violates {
  count(violation) >= 1 with input as mock_input({
    "owner": "alice",
    "env": "prod",
  })
}

test_missing_label_message_names_label {
  some v in violation with input as mock_input({"owner": "alice"})
  contains(v.msg, "env")
  contains(v.msg, "cost-center")
}

test_invalid_env_value_violates {
  count(violation) >= 1 with input as mock_input({
    "owner": "alice",
    "env": "production",
    "cost-center": "cc-1234",
  })
}

test_invalid_cost_center_format_violates {
  count(violation) >= 1 with input as mock_input({
    "owner": "alice",
    "env": "prod",
    "cost-center": "1234",
  })
}

test_valid_dev_env_passes {
  count(violation) == 0 with input as mock_input({
    "owner": "bob",
    "env": "dev",
    "cost-center": "cc-9999",
  })
}



test_custom_message_used_when_provided {
  some v in violation with input as {
    "parameters": {
      "message": "custom: pod is missing required platform labels",
      "labels": [{"key": "owner"}],
    },
    "review": {"object": {"metadata": {"labels": {}}}},
  }
  contains(v.msg, "custom:")
}

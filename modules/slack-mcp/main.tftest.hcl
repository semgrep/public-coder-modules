mock_provider "coder" {}

run "defaults" {
  command = plan
  variables {
    agent_id = "test-agent"
  }
  assert {
    condition     = output.launcher_command == "coder-slack-mcp"
    error_message = "Clients must receive a stable launcher command."
  }
  assert {
    condition     = strcontains(coder_script.slack_mcp.script, "--frozen-lockfile --ignore-scripts")
    error_message = "The installer must use the frozen dependency graph without lifecycle scripts."
  }
  assert {
    condition     = strcontains(coder_script.slack_mcp.script, "https://mcp.slack.com/mcp")
    error_message = "Only the official Slack endpoint is supported."
  }
}

run "default_read_only" {
  command = plan
  variables {
    agent_id = "test-agent"
  }
  assert {
    condition     = strcontains(coder_script.slack_mcp.script, "'slack' 'read-only'")
    error_message = "Existing consumers must retain read-only access by default."
  }
}

run "custom_provider" {
  command = plan
  variables {
    agent_id         = "test-agent"
    external_auth_id = "slack-secondary"
  }
  assert {
    condition     = strcontains(coder_script.slack_mcp.script, "'slack-secondary'")
    error_message = "The launcher must pass the configured external-auth ID."
  }
}

run "reject_shell_characters" {
  command = plan
  variables {
    agent_id         = "test-agent"
    external_auth_id = "slack;false"
  }
  expect_failures = [var.external_auth_id]
}

run "read_write_mode" {
  command = plan
  variables {
    agent_id    = "test-agent"
    access_mode = "read-write"
  }
  assert {
    condition     = strcontains(coder_script.slack_mcp.script, "'slack' 'read-write'")
    error_message = "The launcher must pass the selected access mode to the adapter."
  }
}

run "reject_invalid_mode" {
  command = plan
  variables {
    agent_id    = "test-agent"
    access_mode = "custom-url"
  }
  expect_failures = [var.access_mode]
}

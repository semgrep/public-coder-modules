mock_provider "coder" {}

run "defaults" {
  command = plan
  variables {
    agent_id = "test-agent"
  }
  assert {
    condition     = output.launcher_command == "coder-linear-mcp"
    error_message = "Clients must receive a stable launcher command."
  }
  assert {
    condition     = strcontains(coder_script.linear_mcp.script, "--frozen-lockfile --ignore-scripts")
    error_message = "The installer must use the frozen dependency graph without lifecycle scripts."
  }
  assert {
    condition     = strcontains(coder_script.linear_mcp.script, "https://mcp.linear.app/mcp/readonly")
    error_message = "Only the official read-only endpoint is supported."
  }
}

run "custom_provider" {
  command = plan
  variables {
    agent_id         = "test-agent"
    external_auth_id = "linear-secondary"
  }
  assert {
    condition     = strcontains(coder_script.linear_mcp.script, "'linear-secondary'")
    error_message = "The launcher must pass the configured external-auth ID."
  }
}

run "reject_shell_characters" {
  command = plan
  variables {
    agent_id         = "test-agent"
    external_auth_id = "linear;false"
  }
  expect_failures = [var.external_auth_id]
}

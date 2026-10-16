mock_provider "coder" {}

run "defaults" {
  command = plan
  variables {
    agent_id = "test-agent"
  }
  assert {
    condition     = output.launcher_command == "coder-notion-mcp"
    error_message = "Clients must receive a stable launcher command."
  }
  assert {
    condition     = strcontains(coder_script.notion_mcp.script, "--frozen-lockfile --ignore-scripts")
    error_message = "The installer must use the frozen dependency graph without lifecycle scripts."
  }
  assert {
    condition     = strcontains(coder_script.notion_mcp.script, "https://mcp.notion.com/mcp")
    error_message = "Only the official Notion endpoint is supported."
  }
}

run "default_read_only" {
  command = plan
  variables {
    agent_id = "test-agent"
  }
  assert {
    condition     = strcontains(coder_script.notion_mcp.script, "'notion' 'read-only'")
    error_message = "The module must default to read-only access."
  }
}

run "custom_provider" {
  command = plan
  variables {
    agent_id         = "test-agent"
    external_auth_id = "notion-secondary"
  }
  assert {
    condition     = strcontains(coder_script.notion_mcp.script, "'notion-secondary'")
    error_message = "The launcher must pass the configured external-auth ID."
  }
}

run "reject_shell_characters" {
  command = plan
  variables {
    agent_id         = "test-agent"
    external_auth_id = "notion;false"
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
    condition     = strcontains(coder_script.notion_mcp.script, "'notion' 'read-write'")
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

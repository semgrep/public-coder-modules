mock_provider "coder" {}

run "defaults" {
  command = plan
  variables {
    agent_id = "test-agent"
  }
  assert {
    condition     = output.launcher_command == "mandoline"
    error_message = "Clients must receive the mandoline binary as the MCP command."
  }
  assert {
    condition     = length(output.launcher_args) == 1 && output.launcher_args[0] == "mcp"
    error_message = "Clients must receive mcp as the Mandoline MCP argument."
  }
  assert {
    condition     = output.launcher_path == "/opt/bin/mandoline"
    error_message = "Clients must receive the /opt/bin Mandoline binary path."
  }
  assert {
    condition     = coder_env.mandoline_mcp_path.name == "PATH" && coder_env.mandoline_mcp_path.merge_strategy == "prepend" && coder_env.mandoline_mcp_path.value == "/opt/bin:$PATH"
    error_message = "The Mandoline install directory must be prepended to PATH."
  }
  assert {
    condition     = strcontains(coder_script.mandoline_mcp.script, "gh release list --repo \"$repo\"") && strcontains(coder_script.mandoline_mcp.script, "gh release download \"$release\" --repo \"$repo\" --pattern \"$asset\"") && strcontains(coder_script.mandoline_mcp.script, "repo='semgrep/mandoline'")
    error_message = "The installer must download private Mandoline releases with an authenticated gh CLI."
  }
  assert {
    condition     = strcontains(coder_script.mandoline_mcp.script, "install_dir=\"/opt/bin\"") && strcontains(coder_script.mandoline_mcp.script, "mktemp -d")
    error_message = "The installer must install into /opt/bin and stage downloads with mktemp -d."
  }
}

run "pinned_version" {
  command = plan
  variables {
    agent_id          = "test-agent"
    mandoline_version = "0.15.0"
  }
  assert {
    condition     = strcontains(coder_script.mandoline_mcp.script, "selector='0.15.0'")
    error_message = "A pinned version must be recorded for idempotent upgrades."
  }
  assert {
    condition     = strcontains(coder_script.mandoline_mcp.script, "release=\"v$${selector}\"")
    error_message = "A pinned version must download the matching Mandoline release tag."
  }
  assert {
    condition     = output.mandoline_version == "0.15.0"
    error_message = "The configured Mandoline version must be exported."
  }
}

run "reject_invalid_version" {
  command = plan
  variables {
    agent_id          = "test-agent"
    mandoline_version = "v0.15.0"
  }
  expect_failures = [var.mandoline_version]
}

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
    condition     = output.launcher_path == "$HOME/.local/bin/mandoline"
    error_message = "Clients must receive the user-scoped Mandoline binary path."
  }
  assert {
    condition     = coder_env.mandoline_mcp_path.name == "PATH" && coder_env.mandoline_mcp_path.merge_strategy == "prepend"
    error_message = "The Mandoline install directory must be prepended to PATH."
  }
  assert {
    condition     = strcontains(coder_script.mandoline_mcp.script, "https://github.com/semgrep/mandoline/releases/latest/download/$asset") && strcontains(coder_script.mandoline_mcp.script, "asset='mandoline-linux-x86_64.tar.gz'")
    error_message = "The default installer must download the latest Linux x86_64 release asset."
  }
  assert {
    condition     = strcontains(coder_script.mandoline_mcp.script, "\"$install_dir/mandoline\"") && !strcontains(coder_script.mandoline_mcp.script, "coder-mandoline-mcp <<")
    error_message = "The installer must place mandoline on PATH without a wrapper launcher."
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
    condition     = strcontains(coder_script.mandoline_mcp.script, "https://github.com/semgrep/mandoline/releases/download/v$${selector}/$asset")
    error_message = "A pinned version must download from the matching GitHub release tag."
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

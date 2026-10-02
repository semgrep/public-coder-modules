run "latest_by_default" {
  command = plan

  variables {
    agent_id = "test-agent-id"
  }

  assert {
    condition     = coder_script.pi.run_on_start && coder_script.pi.start_blocks_login
    error_message = "Pi must be ready before the workspace login completes."
  }

  assert {
    condition     = coder_env.pi_path.name == "PATH" && coder_env.pi_path.merge_strategy == "prepend"
    error_message = "The user-local Pi executable must be on the agent PATH."
  }

  assert {
    condition     = strcontains(coder_env.pi_path.value, "pi-coding-agent/node/current/bin") && strcontains(coder_script.pi.script, "SHASUMS256.txt")
    error_message = "Pi must supply a verified Node runtime when another startup script has not installed one yet."
  }

  assert {
    condition     = strcontains(coder_script.pi.script, "selector='latest'") && strcontains(coder_script.pi.script, "npm view \"$package@latest\" version")
    error_message = "The default configuration must resolve the latest Pi release on startup."
  }

  assert {
    condition     = strcontains(coder_script.pi.script, "@earendil-works/pi-coding-agent") && strcontains(coder_script.pi.script, "--ignore-scripts")
    error_message = "Pi must use the current official npm package and installation guidance."
  }
}

run "pinned_version" {
  command = plan

  variables {
    agent_id   = "test-agent-id"
    pi_version = "1.0.0"
  }

  assert {
    condition     = strcontains(coder_script.pi.script, "selector='1.0.0'") && strcontains(coder_script.pi.script, "installed_version\" != \"$desired_version")
    error_message = "A pinned version must be compared with the installed Pi version."
  }

  assert {
    condition     = strcontains(coder_script.pi.script, "pi --version") && strcontains(coder_script.pi.script, "Node.js 22.19")
    error_message = "Startup must verify Pi and enforce its Node.js minimum."
  }

  assert {
    condition     = strcontains(coder_script.pi.script, "registry.npmjs.org/npm/-/npm-$npm_release.tgz") && strcontains(coder_script.pi.script, "npm-cli.js")
    error_message = "Startup must bootstrap npm if the Node.js installation omitted it."
  }
}

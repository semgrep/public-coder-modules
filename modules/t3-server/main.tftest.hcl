run "default_configuration" {
  command = plan

  variables {
    agent_id = "test-agent-id"
  }

  assert {
    condition     = coder_app.t3.url == "http://127.0.0.1:3773"
    error_message = "The default Coder app URL must use the loopback T3 port."
  }

  assert {
    condition     = coder_app.t3.share == "owner"
    error_message = "The T3 Coder app must remain owner-only."
  }

  assert {
    condition     = coder_env.t3_path.merge_strategy == "prepend"
    error_message = "The T3 installation directory must be prepended to PATH."
  }
}

run "custom_configuration" {
  command = plan

  variables {
    agent_id          = "test-agent-id"
    port              = 9000
    working_directory = "/work/project"
    channel           = "nightly"
    t3_version        = "1.2.3"
    initial_repositories = [
      {
        url       = "https://github.com/example/project.git"
        directory = "project"
      },
    ]
  }

  assert {
    condition     = coder_app.t3.url == "http://127.0.0.1:9000"
    error_message = "The Coder app URL must use the configured port."
  }

  assert {
    condition     = strcontains(coder_script.t3_server.script, "working_directory=\"/work/project\"")
    error_message = "The startup script must use the configured working directory."
  }

  assert {
    condition     = strcontains(coder_script.t3_server.script, "T3CODE_VERSION=1.2.3")
    error_message = "An exact version must take precedence during first installation."
  }
}

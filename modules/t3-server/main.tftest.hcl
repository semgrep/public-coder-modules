mock_provider "coder" {}

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
    error_message = "The default T3 Coder app share setting must remain owner-only."
  }

  assert {
    condition     = coder_env.t3_path.merge_strategy == "prepend"
    error_message = "The T3 installation directory must be prepended to PATH."
  }

  assert {
    condition     = strcontains(coder_script.t3_server.script, "server_backend=\"nohup\"")
    error_message = "Existing users must retain the nohup backend by default."
  }
}

run "openrc_configuration" {
  command = plan

  variables {
    agent_id       = "test-agent-id"
    server_backend = "openrc"
  }

  assert {
    condition     = strcontains(coder_script.t3_server.script, "server_backend=\"openrc\"") && strcontains(coder_script.t3_server.script, "supervisor=supervise-daemon")
    error_message = "OpenRC must select a supervised user service."
  }
}

run "invalid_backend" {
  command = plan

  variables {
    agent_id       = "test-agent-id"
    server_backend = "systemd"
  }

  expect_failures = [var.server_backend]
}

run "rotating_logs" {
  command = plan

  variables {
    agent_id       = "test-agent-id"
    server_backend = "openrc"
    log_directory  = "/var/logs/t3"
    log_rotation   = {}
  }

  assert {
    condition     = output.server_log_path == "/var/logs/t3/current"
    error_message = "Rotated logs must report svlogd's active log in the configured directory."
  }

  assert {
    condition     = strcontains(coder_script.t3_server.script, "rotation_interval=\"86400\"") && strcontains(coder_script.t3_server.script, "rotation_retention=\"7\"")
    error_message = "Default rotation must be daily with seven retained archives."
  }
}

run "rotation_requires_openrc" {
  command = plan

  variables {
    agent_id     = "test-agent-id"
    log_rotation = {}
  }

  expect_failures = [coder_script.t3_server]
}

run "invalid_rotation" {
  command = plan

  variables {
    agent_id       = "test-agent-id"
    server_backend = "openrc"
    log_rotation = {
      retained_files = 0
    }
  }

  expect_failures = [var.log_rotation]
}

run "custom_configuration" {
  command = plan

  variables {
    agent_id          = "test-agent-id"
    port              = 9000
    working_directory = "/work/project"
    channel           = "nightly"
    t3_version        = "1.2.3"
    share             = "authenticated"
    public_domain     = "t3.example.com"
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
    condition     = coder_app.t3.share == "authenticated"
    error_message = "The Coder app must use the configured share setting."
  }

  assert {
    condition     = strcontains(coder_script.t3_server.script, "working_directory=\"/work/project\"")
    error_message = "The startup script must use the configured working directory."
  }

  assert {
    condition     = strcontains(coder_script.t3_server.script, "T3CODE_VERSION=1.2.3")
    error_message = "An exact version must take precedence during first installation."
  }

  assert {
    condition     = strcontains(coder_script.t3_server.script, "t3.example.com") && strcontains(coder_script.t3_server.script, "s|http://127.0.0.1:[0-9][0-9]*|https://$public_domain|g")
    error_message = "The pairing shim must rewrite loopback pairing URLs to the public domain."
  }
}

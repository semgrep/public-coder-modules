run "github_defaults" {
  command = plan

  variables {
    agent_id = "test-agent-id"
  }

  assert {
    condition     = output.credential_scope == "https://github.com"
    error_message = "The default credential scope must cover GitHub HTTPS remotes."
  }

  assert {
    condition     = strcontains(coder_script.git_credential_coder.script, "coder external-auth access-token github")
    error_message = "The helper must request Git credentials directly from Coder."
  }

  assert {
    condition     = strcontains(coder_script.git_credential_coder.script, "git config --global --replace-all")
    error_message = "The module must configure Git's credential helper rather than GIT_ASKPASS."
  }
}

run "custom_provider_and_host" {
  command = plan

  variables {
    agent_id         = "test-agent-id"
    host             = "git.example.com"
    external_auth_id = "gitlab"
    username         = "oauth2"
  }

  assert {
    condition     = output.credential_scope == "https://git.example.com"
    error_message = "The configured host must determine the credential scope."
  }

  assert {
    condition     = strcontains(coder_script.git_credential_coder.script, "coder external-auth access-token gitlab")
    error_message = "The configured Coder external-auth provider must be used."
  }
}

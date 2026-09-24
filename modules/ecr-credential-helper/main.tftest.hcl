run "multiple_registries" {
  command = plan

  variables {
    agent_id = "test-agent-id"
    registries = [
      { account_id = "111122223333", region = "us-east-1" },
      { account_id = "444455556666", region = "us-west-2" },
    ]
  }

  assert {
    condition = toset(output.registry_hosts) == toset([
      "111122223333.dkr.ecr.us-east-1.amazonaws.com",
      "444455556666.dkr.ecr.us-west-2.amazonaws.com",
    ])
    error_message = "Every requested account and region must have an ECR registry host."
  }

  assert {
    condition     = coder_env.ecr_helper_path.merge_strategy == "prepend"
    error_message = "The helper installation directory must be prepended to PATH."
  }

  assert {
    condition     = strcontains(coder_script.ecr_credential_helper.script, "docker-credential-ecr-login.sha256")
    error_message = "The helper download must validate the published SHA256 checksum."
  }
}

run "china_registry_domain" {
  command = plan

  variables {
    agent_id        = "test-agent-id"
    registry_domain = "amazonaws.com.cn"
    registries      = [{ account_id = "111122223333", region = "cn-north-1" }]
  }

  assert {
    condition     = output.registry_hosts[0] == "111122223333.dkr.ecr.cn-north-1.amazonaws.com.cn"
    error_message = "The configured registry domain must be used in Docker helper entries."
  }
}

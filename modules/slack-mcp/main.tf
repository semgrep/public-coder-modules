terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

resource "coder_env" "slack_mcp_path" {
  agent_id       = var.agent_id
  name           = "PATH"
  value          = "$HOME/.local/bin:$PATH"
  merge_strategy = "prepend"
}

resource "coder_script" "slack_mcp" {
  agent_id           = var.agent_id
  display_name       = "Install Slack MCP"
  run_on_start       = true
  start_blocks_login = true
  timeout            = 300
  script = templatefile("${path.module}/scripts/install.sh.tpl", {
    external_auth_id = var.external_auth_id
    access_mode      = var.access_mode
    adapter_js       = file("${path.module}/scripts/slack-mcp.mjs")
    package_json     = file("${path.module}/package.json")
    pnpm_lock        = file("${path.module}/pnpm-lock.yaml")
    dependency_hash  = sha256(file("${path.module}/pnpm-lock.yaml"))
  })
}

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

resource "coder_env" "mandoline_mcp_path" {
  agent_id       = var.agent_id
  name           = "PATH"
  value          = "/usr/local/bin:$PATH"
  merge_strategy = "prepend"
}

resource "coder_script" "mandoline_mcp" {
  agent_id           = var.agent_id
  display_name       = "Install Mandoline MCP"
  run_on_start       = true
  start_blocks_login = true
  timeout            = 300
  script = templatefile("${path.module}/scripts/install.sh.tpl", {
    mandoline_version = var.mandoline_version
  })
}

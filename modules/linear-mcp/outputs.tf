output "launcher_command" {
  description = "MCP stdio command on the agent PATH, usable in Claude Code, Codex, or other clients."
  value       = "coder-linear-mcp"
}

output "launcher_path" {
  description = "User-scoped launcher location. Expand HOME before using this as an absolute client command."
  value       = "$HOME/.local/bin/coder-linear-mcp"
}

output "access_mode" {
  description = "Selected MCP access mode. This does not change OAuth token permissions."
  value       = var.access_mode
}

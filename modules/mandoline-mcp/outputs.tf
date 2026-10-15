output "launcher_command" {
  description = "MCP stdio command on the agent PATH. Pair with launcher_args."
  value       = "mandoline"
}

output "launcher_args" {
  description = "Arguments that start Mandoline as an MCP stdio server."
  value       = ["mcp"]
}

output "launcher_path" {
  description = "Installed Mandoline binary path."
  value       = "/opt/bin/mandoline"
}

output "mandoline_version" {
  description = "Configured Mandoline release selector used by the installer."
  value       = var.mandoline_version
}

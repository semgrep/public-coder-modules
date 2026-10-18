output "claude_post_install_script" {
  description = "Guardian setup script for the Claude Code module's post_install_script input."
  value       = local.claude_post_install_script
}

output "codex_post_install_script" {
  description = "Guardian setup script for the Codex module's post_install_script input."
  value       = local.codex_post_install_script
}

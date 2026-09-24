output "app_id" {
  description = "ID of the owner-only Coder app for T3 Code."
  value       = coder_app.t3.id
}

output "port" {
  description = "Loopback port used by the T3 Code server."
  value       = var.port
}

output "server_log_path" {
  description = "Persistent, private log file for the T3 Code server."
  value       = "$HOME/.t3/logs/server.log"
}

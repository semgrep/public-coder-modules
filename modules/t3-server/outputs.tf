output "app_id" {
  description = "ID of the Coder app for T3 Code."
  value       = coder_app.t3.id
}

output "port" {
  description = "Loopback port used by the T3 Code server."
  value       = var.port
}

output "server_log_path" {
  description = "Active private stderr log file for the T3 Code server."
  value       = "${var.log_directory == null ? "$HOME/.t3/logs" : var.log_directory}/${var.log_rotation == null ? "server.log" : "current"}"
}

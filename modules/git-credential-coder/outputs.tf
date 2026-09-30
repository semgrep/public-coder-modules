output "credential_scope" {
  description = "HTTPS credential scope configured to invoke the Coder helper."
  value       = local.credential_scope
}

output "helper_path" {
  description = "User-scoped Git credential helper installed by this module."
  value       = local.helper_path
}

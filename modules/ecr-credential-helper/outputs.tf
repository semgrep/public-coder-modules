output "registry_hosts" {
  description = "ECR registry hosts configured to use docker-credential-ecr-login."
  value       = local.registry_hosts
}

output "helper_path" {
  description = "User-scoped path where docker-credential-ecr-login is installed."
  value       = "$HOME/.local/bin/docker-credential-ecr-login"
}

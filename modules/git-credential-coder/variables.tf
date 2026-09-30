variable "agent_id" {
  description = "ID of the Coder agent whose Git configuration is updated."
  type        = string
}

variable "host" {
  description = "HTTPS Git host for which Coder supplies credentials."
  type        = string
  default     = "github.com"

  validation {
    condition     = can(regex("^[A-Za-z0-9.-]+$", var.host))
    error_message = "host must be a hostname without a URL scheme, path, or port."
  }
}

variable "external_auth_id" {
  description = "Coder external-auth provider ID used to obtain the Git access token."
  type        = string
  default     = "github"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.external_auth_id))
    error_message = "external_auth_id may contain only letters, numbers, dots, underscores, and hyphens."
  }
}

variable "username" {
  description = "HTTP Basic username to return with the Coder access token. GitHub accepts x-access-token."
  type        = string
  default     = "x-access-token"

  validation {
    condition     = length(var.username) > 0 && !strcontains(var.username, "\n") && !strcontains(var.username, "\r")
    error_message = "username must be non-empty and contain no newlines."
  }
}

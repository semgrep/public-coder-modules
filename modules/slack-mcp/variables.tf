variable "agent_id" {
  description = "Coder agent on which to install the Slack MCP launcher."
  type        = string
}

variable "external_auth_id" {
  description = "ID of the Slack OAuth provider configured on the Coder deployment."
  type        = string
  default     = "slack"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.external_auth_id))
    error_message = "external_auth_id must contain lowercase letters, digits, and hyphens."
  }
}

variable "access_mode" {
  description = "Slack MCP tool access: read-only or read-write. OAuth scopes must also permit writes."
  type        = string
  default     = "read-only"

  validation {
    condition     = contains(["read-only", "read-write"], var.access_mode)
    error_message = "access_mode must be read-only or read-write."
  }
}

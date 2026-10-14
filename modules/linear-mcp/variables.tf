variable "agent_id" {
  description = "Coder agent on which to install the Linear read-only MCP launcher."
  type        = string
}

variable "external_auth_id" {
  description = "ID of the Linear OAuth provider configured on the Coder deployment."
  type        = string
  default     = "linear"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.external_auth_id))
    error_message = "external_auth_id must contain lowercase letters, digits, and hyphens."
  }
}

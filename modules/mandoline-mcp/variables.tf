variable "agent_id" {
  description = "Coder agent on which to install the Mandoline MCP launcher."
  type        = string
}

variable "mandoline_version" {
  description = "Desired Mandoline release, or latest to install from the GitHub latest release asset."
  type        = string
  default     = "latest"

  validation {
    condition     = var.mandoline_version == "latest" || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$", var.mandoline_version))
    error_message = "mandoline_version must be latest or an exact semantic version such as 0.17.0."
  }
}

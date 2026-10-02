variable "agent_id" {
  description = "ID of the Coder agent that installs Pi."
  type        = string
}

variable "pi_version" {
  description = "Desired Pi CLI version, or latest to check npm for updates on each workspace start."
  type        = string
  default     = "latest"

  validation {
    condition     = var.pi_version == "latest" || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$", var.pi_version))
    error_message = "pi_version must be latest or an exact semantic version such as 1.0.0."
  }
}

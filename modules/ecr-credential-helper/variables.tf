variable "agent_id" {
  description = "ID of the Coder agent whose user Docker configuration is updated."
  type        = string
}

variable "registries" {
  description = "Private ECR registries to configure. Each account and region pair gets a Docker credHelpers entry."
  type = list(object({
    account_id = string
    region     = string
  }))

  validation {
    condition = length(var.registries) > 0 && alltrue([
      for registry in var.registries :
      can(regex("^[0-9]{12}$", registry.account_id)) &&
      can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", registry.region))
    ])
    error_message = "registries must contain at least one 12-digit AWS account ID and valid AWS region name."
  }
}

variable "helper_version" {
  description = "Pinned Amazon ECR Docker Credential Helper release version, without a leading v."
  type        = string
  default     = "0.12.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.helper_version))
    error_message = "helper_version must be a semantic version without a leading v."
  }
}

variable "registry_domain" {
  description = "DNS suffix for private ECR registries. Use amazonaws.com.cn for AWS China regions."
  type        = string
  default     = "amazonaws.com"

  validation {
    condition     = can(regex("^[a-z0-9.-]+$", var.registry_domain))
    error_message = "registry_domain must be a DNS suffix."
  }
}

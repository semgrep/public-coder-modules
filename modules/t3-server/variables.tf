variable "agent_id" {
  description = "ID of the Coder agent that runs T3 Code."
  type        = string
}

variable "port" {
  description = "Loopback port for the T3 Code HTTP/WebSocket server."
  type        = number
  default     = 3773

  validation {
    condition     = var.port >= 1 && var.port <= 65535
    error_message = "port must be between 1 and 65535."
  }
}

variable "working_directory" {
  description = "Directory from which T3 Code starts and stores its initial project context."
  type        = string
  default     = "/home/coder"
}

variable "channel" {
  description = "T3 Code release channel used only when T3 is not already installed."
  type        = string
  default     = "stable"

  validation {
    condition     = contains(["stable", "nightly"], var.channel)
    error_message = "channel must be either stable or nightly."
  }
}

variable "t3_version" {
  description = "Optional exact T3 Code version. When null, channel selects the release train on first install."
  type        = string
  default     = null
  nullable    = true
}

variable "initial_repositories" {
  description = "Repositories to clone into $HOME/git and add as T3 projects before the server starts."
  type = list(object({
    url       = string
    directory = string
  }))
  default = []

  validation {
    condition = alltrue([
      for repository in var.initial_repositories :
      can(regex("^[A-Za-z0-9._-]+$", repository.directory)) &&
      can(regex("^https://", repository.url))
    ])
    error_message = "Each initial repository must use an HTTPS URL and a simple directory name."
  }
}

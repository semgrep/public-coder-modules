variable "agent_id" {
  description = "ID of the Coder agent that runs T3 Code."
  type        = string
}

variable "server_backend" {
  description = "Server launcher: nohup or an OpenRC user service with crash recovery. OpenRC must already be installed."
  type        = string
  default     = "nohup"

  validation {
    condition     = contains(["nohup", "openrc"], var.server_backend)
    error_message = "server_backend must be either nohup or openrc."
  }
}

variable "log_directory" {
  description = "Optional dedicated, agent-writable absolute directory for server logs. Defaults to $HOME/.t3/logs."
  type        = string
  default     = null

  validation {
    condition     = var.log_directory == null ? true : can(regex("^/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$", var.log_directory))
    error_message = "log_directory must be null or an absolute directory path using letters, numbers, dots, underscores, and hyphens."
  }
}

variable "log_rotation" {
  description = "Optional OpenRC stderr rotation using svlogd. An empty object selects daily/10 MiB rotation with seven archives. Requires svlogd in the agent image."
  type = object({
    max_size_bytes   = optional(number, 10485760)
    interval_seconds = optional(number, 86400)
    retained_files   = optional(number, 7)
  })
  default = null

  validation {
    condition = var.log_rotation == null ? true : (
      var.log_rotation.max_size_bytes >= 2000 && floor(var.log_rotation.max_size_bytes) == var.log_rotation.max_size_bytes &&
      var.log_rotation.interval_seconds >= 1 && floor(var.log_rotation.interval_seconds) == var.log_rotation.interval_seconds &&
      var.log_rotation.retained_files >= 1 && floor(var.log_rotation.retained_files) == var.log_rotation.retained_files
    )
    error_message = "Rotation requires integer max_size_bytes >= 2000, interval_seconds >= 1, and retained_files >= 1."
  }
}

variable "share" {
  description = "Who can access the T3 Code Coder app."
  type        = string
  default     = "owner"

  validation {
    condition     = contains(["owner", "authenticated", "public"], var.share)
    error_message = "share must be one of: owner, authenticated, or public."
  }
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
  description = "T3 Code release channel to install or select on each start, unless t3_version is set."
  type        = string
  default     = "stable"

  validation {
    condition     = contains(["stable", "nightly"], var.channel)
    error_message = "channel must be either stable or nightly."
  }
}

variable "t3_version" {
  description = "Optional exact T3 Code version for first installation. When set, channel switching is disabled on later starts."
  type        = string
  default     = null
  nullable    = true
}

variable "public_domain" {
  description = "Optional public domain for pairing URLs, without a scheme. The domain must route HTTPS traffic to this T3 app."
  type        = string
  default     = ""

  validation {
    condition     = var.public_domain == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$", var.public_domain))
    error_message = "public_domain must be empty or a domain name without a scheme, path, or port."
  }
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

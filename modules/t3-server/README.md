---
display_name: "T3 Server"
description: "Installs and runs the T3 Code headless server as an owner-only Coder app."
icon: "https://raw.githubusercontent.com/pingdotgg/t3code/main/assets/prod/t3-black-web-favicon-32x32.png"
tags: ["t3-code", "development-tools", "coder"]
---

# T3 Server

This module installs T3 Code when it is not already present and runs its
headless server on a Coder agent. It creates an owner-only Coder app and binds
T3 only to loopback, so the server is available through Coder's authenticated
app proxy rather than directly from the workspace network.

## Usage

```tf
module "t3_server" {
  source = "./modules/t3-server"

  agent_id          = coder_agent.main.id
  working_directory = "/home/coder"

  initial_repositories = [
    {
      url       = "https://github.com/example/project.git"
      directory = "project"
    },
  ]
}
```

## Prerequisites

The agent image must provide `curl`, `git`, `ps`, and a POSIX shell. The first
workspace start needs outbound access to `https://t3.codes/install.sh` unless
T3 is already installed. Repository bootstrap requires that the agent can
authenticate to the supplied HTTPS Git remotes; configure this in the calling
workspace template (for example, with Coder external auth).

This module is intended for Linux Coder agents with persistent home storage.
It does not install a system service because Coder workspace containers often
do not run systemd.

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `agent_id` | ID of the Coder agent that runs T3 Code. | `string` | n/a | yes |
| `port` | Loopback port for the T3 Code HTTP/WebSocket server. | `number` | `3773` | no |
| `working_directory` | Directory from which T3 Code starts. | `string` | `/home/coder` | no |
| `channel` | First-install release channel: `stable` or `nightly`. | `string` | `stable` | no |
| `t3_version` | Optional exact version used only for a first installation. | `string` | `null` | no |
| `initial_repositories` | HTTPS repositories to clone into `$HOME/git` and add as projects. | `list(object({ url = string, directory = string }))` | `[]` | no |

## Outputs

| Name | Description |
| --- | --- |
| `app_id` | ID of the owner-only T3 Code Coder app. |
| `port` | Loopback port used by the server. |
| `server_log_path` | Persistent, private server log path. |

## Behavior and operations

T3 state, sessions, projects, credentials, PID file, and logs live in
`$HOME/.t3`. The module prepends `$HOME/.local/bin` to the agent `PATH`, which
makes the T3 executable available in Coder terminals and SSH sessions.

`initial_repositories` is idempotent: an existing Git checkout is reused and
each project is registered only once. It accepts only HTTPS URLs and simple
directory names to prevent path traversal. A startup waits for a live T3
process identified by its PID file instead of terminating it, avoiding risk to
an unrelated process or active work. Inspect startup failures with:

```sh
tail -f ~/.t3/logs/server.log
```

To pair a native client, run `t3 pair` interactively in the workspace. Do not
put pairing URLs in provisioning scripts or logs.

---
display_name: "T3 Server"
description: "Installs and runs the T3 Code headless server as a configurable Coder app."
icon: "https://raw.githubusercontent.com/pingdotgg/t3code/main/assets/prod/t3-black-web-favicon-32x32.png"
tags: ["t3-code", "development-tools", "coder"]
---

# T3 Server

This module installs T3 Code when it is not already present and runs its
headless server on a Coder agent. By default it creates an owner-only Coder
app and binds T3 only to loopback, so the server is available through Coder's
authenticated app proxy rather than directly from the workspace network.

## Usage

```tf
module "t3_server" {
  source = "./modules/t3-server"

  agent_id          = coder_agent.main.id
  working_directory = "/home/coder"
  share             = "authenticated"
  public_domain     = "t3.example.com"

  initial_repositories = [
    {
      url       = "https://github.com/example/project.git"
      directory = "project"
    },
  ]
}
```

## Prerequisites

The agent image must provide `curl`, `git`, `ps`, `readlink`, and a POSIX shell.
The first workspace start needs outbound access to `https://t3.codes/install.sh`
unless T3 is already installed. Channel switches also need access to T3 release
downloads. Repository bootstrap requires that the agent can
authenticate to the supplied HTTPS Git remotes; configure this in the calling
workspace template (for example, with Coder external auth).

This module is intended for Linux Coder agents with persistent home storage.
It does not install a system service because Coder workspace containers often
do not run systemd.

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `agent_id` | ID of the Coder agent that runs T3 Code. | `string` | n/a | yes |
| `share` | Coder app access: `owner`, `authenticated`, or `public`. | `string` | `owner` | no |
| `port` | Loopback port for the T3 Code HTTP/WebSocket server. | `number` | `3773` | no |
| `working_directory` | Directory from which T3 Code starts. | `string` | `/home/coder` | no |
| `channel` | Release channel selected at each start: `stable` or `nightly`. | `string` | `stable` | no |
| `t3_version` | Optional exact version for first installation; disables channel switching. | `string` | `null` | no |
| `public_domain` | Optional HTTPS public domain used in `t3 pair` links, without a scheme. | `string` | `""` | no |
| `initial_repositories` | HTTPS repositories to clone into `$HOME/git` and add as projects. | `list(object({ url = string, directory = string }))` | `[]` | no |

## Outputs

| Name | Description |
| --- | --- |
| `app_id` | ID of the T3 Code Coder app. |
| `port` | Loopback port used by the server. |
| `server_log_path` | Persistent, private server log path. |

## Behavior and operations

T3 state, sessions, projects, credentials, PID file, and logs live in
`$HOME/.t3`. The module prepends `$HOME/.local/bin` to the agent `PATH`, which
makes the T3 executable available in Coder terminals and SSH sessions.

When `t3_version` is unset, the module installs from `channel` if T3 is absent.
On later starts it reads the installed CLI's `t3 --version` output and switches
to the selected channel only when it differs. A switch uses
`t3 update --channel <channel> --allow-downgrade --yes`, so an ephemeral
nightly selection returns to stable on the next start. An unchanged channel
does not contact the release service or upgrade T3. When `t3_version` is set,
it takes precedence on first install; existing installations are left at their
current version and channel. It does not continuously enforce the exact version.

`initial_repositories` is idempotent: an existing Git checkout is reused and
each project is registered only once. It accepts only HTTPS URLs and simple
directory names to prevent path traversal. For a channel switch, startup stops
the server only when its PID file identifies a live T3 server, then waits for
it to exit before updating and restarting it. This interrupts active work.
If a server responds without a verified PID, startup fails instead of claiming
the new channel is active. Channel detection depends on the CLI's version
format: versions with `-nightly.` are nightly, plain versions are stable, and
unrecognized formats fail startup. Inspect startup failures with:

```sh
tail -f ~/.t3/logs/server.log
```

To pair a native client, run `t3 pair` interactively in the workspace. When
`public_domain` is set, the module's `t3` shim rewrites the loopback address in
the pairing URL to `https://<public_domain>`; configure that domain to proxy to
this app before sharing a link. Do not put pairing URLs in provisioning scripts
or logs.

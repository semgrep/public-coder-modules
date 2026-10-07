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

Terraform 1.3 or later is required (1.7 or later to run the mocked module tests).
The agent image must provide `curl`, `git`, `ps`, `readlink`, and a POSIX shell.
The first workspace start needs outbound access to `https://t3.codes/install.sh`
unless T3 is already installed. Channel switches also need access to T3 release
downloads. Repository bootstrap requires that the agent can
authenticate to the supplied HTTPS Git remotes; configure this in the calling
workspace template (for example, with Coder external auth).

This module is intended for Linux Coder agents with persistent home storage.
The default backend uses `nohup`. The optional `openrc` backend requires OpenRC
with user-service support (`openrc`, `rc-service --user`, `openrc-run`, and
`supervise-daemon`), plus `id`, `env`, `sed`, `sort`, `tr`, and `cksum`. It does not require
root or an OpenRC PID 1. Optional log rotation additionally requires `svlogd`
(provided by the `runit` package on Debian/Ubuntu).

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `agent_id` | ID of the Coder agent that runs T3 Code. | `string` | n/a | yes |
| `server_backend` | Launcher: `nohup` or a supervised OpenRC user service. | `string` | `nohup` | no |
| `log_directory` | Dedicated, agent-writable absolute directory; defaults to `$HOME/.t3/logs`. | `string` | `null` | no |
| `log_rotation` | OpenRC rotation settings: `max_size_bytes`, `interval_seconds`, and `retained_files`. `{}` selects 10 MiB, daily, seven archives. | `object` | `null` | no |
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
| `server_log_path` | Active private server stderr log path. |

## Behavior and operations

T3 state, sessions, projects, credentials, and the `nohup` PID file live in
`$HOME/.t3`. Logs default to `$HOME/.t3/logs/server.log`. The module prepends `$HOME/.local/bin` to the agent `PATH`, which
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
the owned server through its verified PID (`nohup`) or supervisor (`openrc`)
before updating and restarting it. This interrupts active work.
If an unowned server still responds, startup fails instead of claiming
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

## OpenRC supervision and rotating logs

```hcl
module "t3_server" {
  source = "./modules/t3-server"

  agent_id       = coder_agent.main.id
  server_backend = "openrc"
  log_directory  = "/var/logs/t3"
  log_rotation   = {} # daily or 10 MiB, retaining seven archives
}
```

The module creates a private OpenRC user service in
`$HOME/.t3/openrc-config/rc/init.d/t3-server`, with transient runtime state in
`/tmp/t3-openrc-<uid>`. Coder's startup script still installs T3, registers
initial projects, and waits for HTTP readiness. OpenRC supervises the foreground
server, delaying respawns by two seconds and allowing five respawns within
60 seconds. If that budget is exhausted, inspect the logs and restart the
service. HTTP readiness remains separate from process supervision; a live but
unresponsive server is not automatically restarted.

Switching backends stops the module's previous server before starting the new
one. Selecting OpenRC refuses to adopt an already responding server without
module ownership. Channel changes stop the supervisor before updating T3.
Changes to the OpenRC launch or logging configuration also restart its service,
interrupting active work. After switching to `nohup`, leave OpenRC installed
until the workspace has completed that startup so it can stop the old service.

OpenRC preserves the Coder startup environment through an allowlist of variable
names. Credential values remain in the process environment and are not written
to service configuration. The child's original XDG configuration/runtime paths
are restored so provider tools find their normal settings and sockets.

Use a dedicated log directory writable by the agent user. The module sets it
to mode `0700`; do not point it at a shared directory such as `/var/log` itself.
`/var/log` is the conventional Linux location, but `/var/logs/t3` works too.
For example, prepare a Debian/Ubuntu agent image as root:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends openrc runit \
    && install -d -o coder -g coder -m 0700 /var/logs/t3
```

Logs outside persistent home need a volume mount if they should survive
container replacement. The module does not install packages or grant itself
permission to write under `/var`.

With `log_rotation = {}`, OpenRC pipes stderr to `svlogd`, which timestamps
entries and rotates nonempty logs daily or at 10 MiB. It keeps seven archives
plus the active `current` file. The interval, size, and retention can be changed:

```hcl
log_rotation = {
  max_size_bytes   = 20971520
  interval_seconds = 43200
  retained_files   = 14
}
```

The logger rotates its own file descriptors; no cron daemon or `copytruncate`
is needed. Archives use `@<timestamp>.s` names. Without rotation, both backends
append stderr to `server.log`. Stdout is discarded because `t3 serve` prints
pairing details there. These settings cover the module's server stderr and
repository bootstrap output, not any separate internal logs maintained by T3.
`server_log_path` reports the active file for the selected configuration.

```sh
tail -F /var/logs/t3/current

t3_service() {
  XDG_CONFIG_HOME="$HOME/.t3/openrc-config" \
    XDG_RUNTIME_DIR="/tmp/t3-openrc-$(id -u)" \
    rc-service --user t3-server "$@"
}
t3_service status
t3_service restart
t3_service stop
```

Module configuration changes take effect on the next Coder startup; use
`t3_service restart` for an operational restart with the last provisioned
configuration.

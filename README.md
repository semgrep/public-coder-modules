# coder-modules

Reusable Terraform modules for [Coder](https://coder.com/) workspace templates.

## `semgrep-guardian`

[`modules/semgrep-guardian`](modules/semgrep-guardian) exports Guardian setup
scripts for the Claude Code and Codex modules' `post_install_script` inputs.
It installs missing plugins, re-enables disabled plugins, and verifies the
result after each harness installs, without replacing unrelated settings.
Developers still complete Semgrep OAuth and, for Codex hooks, trust review in
a new session. See the module README for template wiring and policy limits.

## `pi-coding-agent`

[`modules/pi-coding-agent`](modules/pi-coding-agent) installs the Pi CLI at
workspace start. Set `pi_version` to an exact release for controlled upgrades,
or leave it at `latest` to update when a new npm release appears. It keeps Pi
state in the Coder user's persistent home and adds `pi` to the agent `PATH`.

```hcl
module "pi_coding_agent" {
  source = "./modules/pi-coding-agent"

  agent_id   = coder_agent.main.id
  pi_version = "1.0.0"
}
```

## `t3-server`

[`modules/t3-server`](modules/t3-server) installs and starts the T3 Code
headless server on a Coder agent. It creates an owner-only **T3 Code** app,
listening on loopback port `3773` by default.

```hcl
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

T3 is installed only when absent. Use `channel` (`stable` or `nightly`) to
choose the release train on every start. It switches an existing installation
only when the installed channel differs, including nightly back to stable;
an unchanged channel does not trigger an upgrade. `t3_version` takes precedence
on first install and disables later channel switching; it does not enforce an
exact version after installation. The module leaves T3 state in `$HOME/.t3`,
adds `$HOME/.local/bin` to the agent `PATH`, and records server logs at
`$HOME/.t3/logs/server.log`.

Set `server_backend = "openrc"` to use an OpenRC user service with crash recovery
instead of `nohup`. Add `log_directory = "/var/logs/t3"` and `log_rotation = {}`
for timestamped logs rotated daily or at 10 MiB, retaining seven archives.
The agent image must provide OpenRC and `svlogd`, and the log directory must be
writable by the agent user. See the module README for image setup and operations.

Repositories supplied through `initial_repositories` are cloned once into
`$HOME/git/<directory>` and registered as T3 projects before the server starts.
Each URL must be HTTPS and each directory must be a simple filename.

## `ecr-credential-helper`

[`modules/ecr-credential-helper`](modules/ecr-credential-helper) installs the
Amazon ECR Docker credential helper for a Coder user and configures named ECR
account/region registries without replacing other Docker credentials.

```hcl
module "ecr_credential_helper" {
  source   = "./modules/ecr-credential-helper"
  agent_id = coder_agent.main.id

  registries = [
    { account_id = "111122223333", region = "us-east-1" },
    { account_id = "444455556666", region = "us-west-2" },
  ]
}
```

The agent user needs AWS credentials with access to the configured ECR
repositories when it runs Docker.

## `git-credential-coder`

[`modules/git-credential-coder`](modules/git-credential-coder) configures a
host-scoped Git HTTPS credential helper that retrieves fresh credentials from
Coder external authentication. It avoids persisting access tokens and works
for Git commands that run outside an interactive shell.

```hcl
module "git_credential_coder" {
  source   = "./modules/git-credential-coder"
  agent_id = coder_agent.main.id
}
```

## `linear-mcp`

[`modules/linear-mcp`](modules/linear-mcp) installs a Linear MCP
launcher backed by Coder external authentication. Unlinked accounts keep a
healthy MCP connection with an empty tool list; tools become available after
linking the account. The module installs the adapter and exposes its launcher
command; the calling template registers it in its coding clients.
`access_mode` defaults to `read-only`; choose `read-write` to expose write tools
with a write-capable OAuth grant.

```hcl
module "linear_mcp" {
  source           = "./modules/linear-mcp"
  agent_id         = coder_agent.main.id
  external_auth_id = "linear"
}
```

## `slack-mcp`

[`modules/slack-mcp`](modules/slack-mcp) installs a Slack MCP launcher backed
by Coder external authentication. Read-only is the default: an explicit tool
allowlist filters discovery and rejects write calls before forwarding them.
Unlinked accounts keep a healthy empty MCP and receive Coder linking guidance.

```hcl
module "slack_mcp" {
  source           = "./modules/slack-mcp"
  agent_id         = coder_agent.main.id
  external_auth_id = "slack"
  access_mode      = "read-only"
}
```

Register the exported launcher command in your clients. Choose `read-write`
to expose all tools permitted by the Slack grant. See the module README for
Codex environment forwarding and runtime requirements.

## `mandoline-mcp`

[`modules/mandoline-mcp`](modules/mandoline-mcp) installs Mandoline on the
agent PATH so clients can run `mandoline mcp` as a local stdio MCP server.
The startup script downloads the Linux x86_64 release from GitHub. The calling
template registers `mandoline` with args `["mcp"]` in its coding clients.

```hcl
module "mandoline_mcp" {
  source   = "./modules/mandoline-mcp"
  agent_id = coder_agent.main.id
}
```

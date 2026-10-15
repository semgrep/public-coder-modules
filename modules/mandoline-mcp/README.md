# Mandoline MCP

Installs [Mandoline](https://github.com/semgrep/mandoline) on the agent PATH
so coding clients can run `mandoline mcp` as a stdio MCP server. The startup
script downloads the Linux x86_64 release archive from GitHub.

## Usage

```hcl
module "mandoline_mcp" {
  source   = "./modules/mandoline-mcp"
  agent_id = coder_agent.main.id
  # Optional: pin an exact release instead of latest.
  # mandoline_version = "0.15.0"
}
```

The module installs `mandoline` in `/opt/bin` and prepends that directory to
the agent PATH. Register `module.mandoline_mcp.launcher_command` with
`module.mandoline_mcp.launcher_args` in your clients' MCP configuration. For
example, Claude Code accepts:

```json
{
  "mcpServers": {
    "mandoline": { "command": "mandoline", "args": ["mcp"] }
  }
}
```

Codex accepts this TOML:

```toml
[mcp_servers.mandoline]
command = "mandoline"
args = ["mcp"]
```

Client registration remains the calling template's responsibility. Registration
applies to the agent on which the module runs; clients in another container need
access to the installed Mandoline binary.

## Installation

The agent image must provide `curl`, `tar`, and a POSIX shell, and the agent
user must be able to write to `/opt/bin`. Initial installation needs outbound
HTTPS access to GitHub releases. The installer targets Linux x86_64 (`amd64`)
only: it creates a temporary directory, downloads and extracts
`mandoline-linux-x86_64.tar.gz`, installs the binary to `/opt/bin/mandoline`,
then removes the temporary directory.

By default `mandoline_version = "latest"` downloads from
`https://github.com/semgrep/mandoline/releases/latest/download/mandoline-linux-x86_64.tar.gz`.
Pin an exact semantic version to install from the matching tagged release and
to reinstall when that pin changes. Changing the selector, or removing
`/opt/bin/mandoline` (and `/opt/bin/mandoline.version`), refreshes the binary
on the next workspace start.

Mandoline analyzes the client's working directory; no Coder external
authentication is required.

| Input | Default | Description |
| --- | --- | --- |
| `agent_id` | Required | Coder agent receiving the installer and PATH entry |
| `mandoline_version` | `latest` | `latest` or an exact release such as `0.15.0` |

Outputs: `launcher_command` is `mandoline`; `launcher_args` is `["mcp"]`;
`launcher_path` is `/opt/bin/mandoline`; `mandoline_version` echoes the
configured selector.

## Validation

```sh
cd modules/mandoline-mcp
terraform init -backend=false
terraform test
```

Terraform tests use a mock Coder provider.

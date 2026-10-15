# Mandoline MCP

Installs [Mandoline](https://github.com/semgrep/mandoline) on the agent PATH
so coding clients can run `mandoline mcp` as a stdio MCP server. The startup
script downloads the Linux x86_64 release archive from the private Mandoline
GitHub repository using the authenticated GitHub CLI.

## Usage

```hcl
module "mandoline_mcp" {
  source   = "./modules/mandoline-mcp"
  agent_id = coder_agent.main.id
  # Optional: pin an exact release instead of latest.
  # mandoline_version = "0.15.0"
}
```

The module installs `mandoline` in `/usr/local/bin` and prepends that directory to
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

The agent image must provide `gh`, `tar`, and a POSIX shell, and the agent user
must be able to write to `/usr/local/bin`. Because Mandoline releases are private,
`gh` must already be authenticated to GitHub with access to
`semgrep/mandoline` (for example via `GH_TOKEN` or `gh auth login`).

The installer targets Linux x86_64 (`amd64`) only. For `latest`, it resolves
the newest non-draft, non-prerelease with `gh release list`, then runs
`gh release download` for `mandoline-linux-x86_64.tar.gz`. It extracts the
archive in a temporary directory, installs `/usr/local/bin/mandoline`, and removes
the temporary files.

Pin an exact semantic version such as `0.15.0` to download the matching
`v0.15.0` release tag and reinstall when that pin changes. Changing the
selector, or removing `/usr/local/bin/mandoline` (and `/usr/local/bin/mandoline.version`),
refreshes the binary on the next workspace start.

Mandoline analyzes the client's working directory; no Coder external
authentication is required for the MCP server itself.

| Input | Default | Description |
| --- | --- | --- |
| `agent_id` | Required | Coder agent receiving the installer and PATH entry |
| `mandoline_version` | `latest` | `latest` or an exact release such as `0.15.0` |

Outputs: `launcher_command` is `mandoline`; `launcher_args` is `["mcp"]`;
`launcher_path` is `/usr/local/bin/mandoline`; `mandoline_version` echoes the
configured selector.

## Validation

```sh
cd modules/mandoline-mcp
terraform init -backend=false
terraform test
```

Terraform tests use a mock Coder provider.

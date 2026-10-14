# Linear read-only MCP

Installs a stdio MCP adapter that connects to [Linear's official read-only
MCP endpoint](https://linear.app/docs/mcp), using the workspace owner's Coder
external-auth token. It exposes Linear's read tools to Claude Code, Codex, or
other MCP clients without a second OAuth login.

## Usage

Configure a Linear OAuth external-auth provider on the Coder deployment first.
The module does not provision OAuth applications, client secrets, or account
links. Linear API authorization uses OAuth 2.0; request the `read` scope.

```hcl
data "coder_external_auth" "linear" {
  id       = "linear"
  optional = true
}

module "linear_mcp" {
  source           = "./modules/linear-mcp"
  agent_id         = coder_agent.main.id
  external_auth_id = "linear"
}
```

The module installs `coder-linear-mcp` in `$HOME/.local/bin` and adds that
location to the agent PATH. Register `module.linear_mcp.launcher_command` in
your clients' MCP configuration. For example, Claude Code accepts:

```json
{
  "mcpServers": {
    "linear": { "command": "coder-linear-mcp" }
  }
}
```

Codex accepts this TOML:

```toml
[mcp_servers.linear]
command = "coder-linear-mcp"
```

Client registration remains the calling template's responsibility. Registration
applies to the agent on which the module runs; clients in another container need
access to the executable, dependencies, and Coder credential context.

## Optional authentication

Without a linked account, MCP initialization and ping succeed, `tools/list`
returns an empty list, and nothing is sent to Linear. The server stays running
without printing an authentication error. A stale tool call returns a normal
MCP tool result with `isError: true` explaining how to link Linear.

The adapter checks authentication every 30 seconds. After linking Linear in
Coder, it sends `notifications/tools/list_changed` when tools become available.
Clients that honor that notification update automatically; clients that cache
tool lists may require a reconnect. Unlinking hides tools again. Rejected
upstream credentials also hide tools while keeping the local MCP healthy.
Network outages return a sanitized MCP error and can recover on later requests.

## Installation and credentials

The agent image must provide **standalone pnpm** on PATH (or at
`/usr/local/share/pnpm/bin/pnpm`) with Node environment management available.
The startup script provisions user-local Node 24 and installs the official
MCP SDK with the checked-in frozen dependency lockfile and lifecycle scripts
disabled. Initial installation needs access to the public Node/npm registries;
later starts reuse dependencies when the lockfile is unchanged. It runs
independently of optional Linear account linking.

Runtime requires Coder's workspace credential context and CLI, available through
`GIT_ASKPASS` or PATH. Each upstream HTTP request retrieves a current token with
`coder external-auth access-token <external_auth_id>`; Coder handles refresh.
The module stores no access or refresh tokens in Terraform, client config,
files, or command arguments. It uses a fixed read-only endpoint, rejects
redirects, and never starts a separate browser OAuth flow. The SDK dependency
lockfile contains only public package locations and integrity hashes.

| Input | Default | Description |
| --- | --- | --- |
| `agent_id` | Required | Coder agent receiving the installer and PATH entry |
| `external_auth_id` | `linear` | Linear external-auth provider ID in Coder |

Outputs: `launcher_command` is the PATH command; `launcher_path` is its
`$HOME`-relative location (expand HOME before using it as an absolute command).

## Validation

```sh
cd modules/linear-mcp
pnpm install --frozen-lockfile --ignore-scripts
node --test tests/adapter.test.mjs
terraform init -backend=false
terraform test
```

Node tests cover skipped auth, linking/unlinking on the same connection,
per-request token acquisition, rejected credentials, sanitized upstream errors,
and the actual stdio subprocess. Terraform tests use a mock Coder provider.

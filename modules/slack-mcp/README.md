# Slack MCP

Installs a stdio MCP adapter backed by the workspace owner's Coder external
authentication. It connects to Slack's [official Streamable HTTP
endpoint](https://docs.slack.dev/ai/slack-mcp-server/),
`https://mcp.slack.com/mcp`, using a user OAuth token from an MCP-enabled
internal or Marketplace Slack app.

## Usage

Configure the Slack user OAuth provider on the Coder deployment first. The
module does not create Slack apps, client secrets, or account links.

```hcl
data "coder_external_auth" "slack" {
  id       = "slack"
  optional = true
}

module "slack_mcp" {
  source           = "./modules/slack-mcp"
  agent_id         = coder_agent.main.id
  external_auth_id = "slack"
  access_mode      = "read-only"
}
```

Register `module.slack_mcp.launcher_command` in each coding client's MCP
configuration. It resolves to `coder-slack-mcp` on the agent PATH. Claude Code
accepts a user-scope MCP entry such as:

```json
{
  "mcpServers": {
    "slack": { "command": "coder-slack-mcp" }
  }
}
```

Codex filters stdio environments; allow forwarding the Coder context by name:

```toml
[mcp_servers.slack]
command = "coder-slack-mcp"
env_vars = ["CODER", "CODER_AGENT_TOKEN", "CODER_AGENT_URL", "GIT_ASKPASS"]
```

Client registration belongs to the calling template. Clients in a different
container need their own registration and access to the launcher, dependencies,
and Coder credential context.

## Read-only enforcement

The default `access_mode = "read-only"` exposes only these reviewed tools:

- `slack_search_public`, `slack_search_public_and_private`
- `slack_search_channels`, `slack_search_users`, `slack_search_emojis`
- `slack_read_channel`, `slack_read_thread`, `slack_read_user_profile`
- `slack_list_channel_members`, `slack_list_user_channels`
- `slack_read_file`, `slack_get_reactions`

The same explicit allowlist is enforced on every incoming `tools/call` before
acquiring credentials or forwarding the request. Direct calls to send,
schedule, draft, or other non-allowlisted tools return `isError: true` without
reaching Slack. Unknown future tools are denied regardless of their name prefix
or `readOnlyHint` annotation. Paginated discovery is traversed so a write-only
page does not hide read tools on later pages.

This controls calls through this adapter, not the underlying user's OAuth
permissions or direct API access. Set `access_mode = "read-write"` to expose
and forward all tools permitted by the Slack OAuth grant. Restart coding
clients after changing mode to load the new launcher and refresh tools.

## Optional authentication and refresh

Unlinked accounts still initialize and respond to ping, with zero tools and
no requests sent to Slack. When Coder returns a linking URL, it is included in
read-tool error replies and printed once to stderr. Only the linking-page URL
is retained; query parameters and raw subprocess diagnostics are not relayed.
If no URL is available, the reply gives the CLI command to obtain one.

The adapter polls authentication every 30 seconds and notifies clients when
linking/unlinking changes tool availability. Clients that cache tools may need
a reconnect. Rejected credentials hide tools while keeping MCP healthy;
upstream outages produce sanitized MCP errors and can recover on later calls.

Each upstream request obtains a current token using
`coder external-auth access-token <external_auth_id>`. Coder manages refresh.
Tokens stay in memory and are not written to files, Terraform values, client
configuration, or command arguments. Credentials go only to Slack's fixed
endpoint; redirects and a separate browser OAuth flow are disabled.

## Installation

The image must include standalone pnpm on PATH or at
`/usr/local/share/pnpm/bin/pnpm`, with Node environment management available.
The startup script provisions user-local Node 24 and the official MCP SDK
using the frozen dependency lockfile with lifecycle scripts disabled. Initial
installation needs public Node/npm registry access. Subsequent starts reuse
dependencies when the lockfile is unchanged. Installation does not require a
linked Slack account.

Inputs: `agent_id` is required; `external_auth_id` defaults to `slack`;
`access_mode` defaults to `read-only` and also accepts `read-write`.
Outputs: `launcher_command`, `$HOME`-relative `launcher_path`, and `access_mode`.

## Validation

```sh
cd modules/slack-mcp
pnpm install --frozen-lockfile --ignore-scripts
node --test tests/adapter.test.mjs
terraform init -backend=false
terraform test
```

Tests cover optional auth and URL guidance, refresh, read-only discovery,
direct/stale/unknown write rejection, pagination, and read-write forwarding to
a simulated upstream. Live validation should discover tools and exercise read
operations first; posting a real message requires an explicit user request.

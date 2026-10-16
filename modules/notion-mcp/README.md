# Notion MCP

Installs a stdio MCP adapter for the workspace owner's optional Coder external
authentication. It connects to the official hosted server at
`https://mcp.notion.com/mcp` using MCP-issued OAuth tokens. A regular Notion
REST API integration token is not a substitute.

## Usage

Configure a generic Notion MCP OAuth provider in Coder first. Register a client
once through Notion's dynamic client registration endpoint and retain its
credentials. Use the advertised MCP authorization/token endpoints, scope
`default`, and S256 PKCE. Coder owns token storage and refresh; this module
creates no OAuth clients or account links. See the
[Notion MCP client guide](https://developers.notion.com/guides/mcp/build-mcp-client).

```hcl
data "coder_external_auth" "notion" {
  id       = "notion"
  optional = true
}

module "notion_mcp" {
  source           = "./modules/notion-mcp"
  agent_id         = coder_agent.main.id
  external_auth_id = data.coder_external_auth.notion.id
  access_mode      = "read-only"
}
```

Register the exported launcher command in your template's clients:

```json
{
  "mcpServers": {
    "notion": { "command": "coder-notion-mcp" }
  }
}
```

Codex filters stdio environments. Forward the Coder context by name:

```toml
[mcp_servers.notion]
command = "coder-notion-mcp"
env_vars = ["CODER", "CODER_AGENT_TOKEN", "CODER_AGENT_URL", "GIT_ASKPASS"]
startup_timeout_sec = 30
```

Only names belong in client configuration, never credential values. Clients
inside another container need access to the launcher and Coder context.
Wait for **Install Notion MCP** to finish before starting clients on first use;
a client that cached a missing-launcher failure needs to reconnect/restart.

## Read-only policy

The default `access_mode = "read-only"` exposes only these reviewed tools when
they are available upstream:

- `notion-search` and `notion-fetch` (plus official `search`/`fetch` aliases)
- `notion-get-comments`
- `notion-query-data-sources` and `notion-query-multiple-data-sources`
- `notion-get-tool-access`

The same allowlist is enforced on every incoming `tools/call` before fetching
credentials or contacting Notion. Unknown tools are denied regardless of name
prefix or `readOnlyHint`. Direct/stale calls to editing, comments writes,
Custom Agent execution, user-directory tools, and other non-allowlisted tools
return `isError: true`. Discovery traverses all pages, including write-only
pages, to find the permitted tools.

Search discovery permits only `query_type: internal`; calls requesting user
lookups or unknown query types are rejected. Omitted query type is explicitly
forwarded as `internal`. The legacy fetch `id: self` identity lookup is blocked.
This narrows tool operations, not all data embedded in page results: page
content and metadata can contain names, emails, comments, or meeting transcripts.

**Content search can include connected sources**, depending on Notion's plan
and search behavior. `internal` distinguishes content search from user lookup;
it does not guarantee Notion-only results. This adapter is not a page-access,
connected-source, or OAuth-scope boundary. Notion enforces the linked user's
permissions. See [Notion's tools](https://developers.notion.com/guides/mcp/mcp-supported-tools).

Setting `access_mode = "read-write"` exposes and forwards all tools permitted
by the grant, including actions that may use Notion credits. Neither mode
changes the underlying OAuth token's permissions. Restart clients after changing
mode. If provider-enforced read-only/page-scoped credentials are required, use
a separately scoped Notion API connection with an API-backed implementation.

## Optional authentication

Unlinked accounts initialize and respond to ping with no tools and no upstream
requests. Allowed calls return guidance linking the account in Coder. When
Coder supplies a linking URL, the adapter includes it in the reply and prints
it once on stderr, stripping query parameters and raw subprocess diagnostics.
Otherwise the reply gives the CLI command to obtain the link.

Authentication is lazy: initialization and idle time do not retrieve credentials
or contact the provider. Listing or calling tools retrieves a current Coder token
for each upstream HTTP request, without a separate preflight check. There is no
background authentication timer or credential cache.

After linking in Coder, refresh the client's tool list or reconnect if it caches
an empty list. Account changes are discovered on the next request, rather than
while idle; unlinking or HTTP 401/403 hides tools and keeps the local MCP healthy.
Tool-list-change notifications are sent when a request connects or disconnects
the upstream client. Upstream outages return sanitized errors and recover on
later requests.

Every upstream request fetches a current token with
`coder external-auth access-token <external_auth_id>`. Tokens remain in memory,
never client config, command arguments, or Terraform values. Coder handles
rotation and reconnect requirements. Requests use only the fixed official MCP
URL; redirects are rejected.

## Installation and interface

Standalone pnpm is required on PATH or at `/usr/local/share/pnpm/bin/pnpm`,
with Node environment management. Both pnpm 10 (`PNPM_HOME/node`) and pnpm 11
(`PNPM_HOME/bin/node`) runtime layouts are supported. The blocking startup script provisions
user-local Node 24 and the official MCP SDK from a frozen lockfile, with
lifecycle scripts disabled. First installation needs Node/npm network access;
subsequent starts reuse dependencies when the lockfile is unchanged. Account
linking is not required for installation.

Inputs: `agent_id` (required), `external_auth_id` (default `notion`),
`access_mode` (default `read-only`, also accepts `read-write`).
Outputs: `launcher_command`, `$HOME`-relative `launcher_path`, `access_mode`.

## Validation

```sh
cd modules/notion-mcp
pnpm install --frozen-lockfile --ignore-scripts
node --test tests/*.test.mjs
terraform init -backend=false
terraform test
```

Installer tests cover both runtime layouts on fresh installs and restarts,
including failure when pnpm produces no usable Node. Adapter tests cover
unlinked/expired authentication, URL guidance, current-token
retrieval, reconnects, discovery pagination, explicit read-only enforcement,
user-lookup rejection, and read-write calls to a simulated upstream. Live
validation should list tools and read a page; never exercise real write or
agent-execution tools merely to test read-only enforcement.

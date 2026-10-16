// A healthy stdio MCP server even when optional Coder external auth is absent.
// Credentials are acquired at runtime and never written to client config.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema, McpError, ErrorCode } from '@modelcontextprotocol/sdk/types.js';

const run = promisify(execFile);
export const NOTION_URL = 'https://mcp.notion.com/mcp';
// Reviewed content-read tools only; never trust prefixes or annotations.
const readTools = new Set([
  'notion-search', 'notion-fetch', 'notion-get-comments',
  'notion-query-data-sources', 'notion-query-multiple-data-sources',
  'notion-get-tool-access',
  // Official aliases for clients identified as OpenAI clients.
  'search', 'fetch',
]);
export function toolAllowed(name, accessMode) {
  return accessMode === 'read-write' || readTools.has(name);
}
function callAllowed(params, accessMode) {
  if (!toolAllowed(params.name, accessMode)) return false;
  if (accessMode === 'read-write') return true;
  const args = params.arguments || {};
  if (['notion-search', 'search'].includes(params.name) &&
      args.query_type !== undefined && args.query_type !== 'internal') return false;
  // Legacy fetch alias for connection identity includes user/email data.
  if (['notion-fetch', 'fetch'].includes(params.name) && args.id === 'self') return false;
  return true;
}
function readTool(tool) {
  const result = { ...tool, annotations: { ...tool.annotations, readOnlyHint: true } };
  if (['notion-search', 'search'].includes(tool.name)) {
    const schema = tool.inputSchema;
    result.inputSchema = { ...schema, properties: { ...schema.properties,
      query_type: { type: 'string', enum: ['internal'], description: 'Content search only; user lookup is disabled.' },
    } };
    result.description = 'Search content (user lookup disabled). Notion may also search connected sources. ' + (tool.description || '');
  }
  return result;
}
export class AuthUnavailable extends Error {
  constructor(authUrl) {
    super('Notion authentication unavailable');
    this.authUrl = authUrl;
  }
}

export function authenticationUrl(stdout, providerId) {
  try {
    const url = new URL(stdout.trim());
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password ||
        url.pathname !== `/external-auth/${providerId}`) return undefined;
    // Only return the Coder linking page, never query parameters or raw
    // subprocess output that could contain credentials or diagnostics.
    url.search = '';
    url.hash = '';
    return url.href;
  } catch { return undefined; }
}

export async function coderToken(providerId) {
  try {
    const { stdout } = await run(process.env.GIT_ASKPASS || 'coder',
      ['external-auth', 'access-token', providerId], { timeout: 10000, maxBuffer: 65536 });
    const token = stdout.trim();
    if (!token || /\s/.test(token)) throw new AuthUnavailable();
    return token;
  } catch (error) {
    // Coder prints the linking URL to stdout and exits 1 when unlinked.
    // Parse only that exact URL shape; never relay raw stdout/stderr.
    throw new AuthUnavailable(authenticationUrl(error.stdout || '', providerId));
  }
}

export function createAdapter({ providerId = 'notion', accessMode = 'read-only', getToken = () => coderToken(providerId), fetchImpl = fetch, log = message => console.error(message) } = {}) {
  const upstreamUrl = NOTION_URL;
  if (!['read-only', 'read-write'].includes(accessMode)) throw new Error('Invalid Notion access mode');
  const server = new Server({ name: 'coder-notion-mcp', version: '1.0.0' }, {
    capabilities: { tools: { listChanged: true } },
  });
  let client;
  let connecting;
  let initialized = false;
  let closed = false;
  let poll;
  let shutdownPromise;
  let reportedAuthUrl;
  const notify = () => {
    if (initialized && !closed) server.sendToolListChanged().catch(() => {});
  };
  const disconnect = async () => {
    const previous = client;
    client = undefined;
    if (previous) {
      await previous.close().catch(() => {});
      notify();
    }
  };
  const authenticatedFetch = async (url, options) => {
    // No configurable upstream and no redirects: credentials go only to the
    // selected official endpoint. No OAuth provider/browser flow is used.
    if (String(url) !== upstreamUrl) throw new Error('Unexpected MCP endpoint');
    const token = await getToken();
    const headers = new Headers(options?.headers);
    headers.set('authorization', `Bearer ${token}`);
    const response = await fetchImpl(url, { ...options, headers, redirect: 'error' });
    if (response.status === 401 || response.status === 403) {
      await response.body?.cancel();
      throw new AuthUnavailable();
    }
    return response;
  };
  const ensureClient = async () => {
    if (closed) throw new Error('Adapter closed');
    // Check even when a session exists: account unlinking must hide tools.
    await getToken();
    if (closed) throw new Error('Adapter closed');
    if (client) return client;
    if (!connecting) connecting = (async () => {
      const candidate = new Client({ name: 'coder-notion-mcp', version: '1.0.0' });
      try {
        await candidate.connect(new StreamableHTTPClientTransport(new URL(upstreamUrl), {
          fetch: authenticatedFetch,
          reconnectionOptions: { maxRetries: 0 },
        }));
        if (closed) throw new Error('Adapter closed');
        client = candidate;
        notify();
        return candidate;
      } catch (error) {
        await candidate.close().catch(() => {});
        throw error;
      }
    })().finally(() => { connecting = undefined; });
    return connecting;
  };
  const reportAuth = error => {
    if (error instanceof AuthUnavailable && error.authUrl && error.authUrl !== reportedAuthUrl) {
      reportedAuthUrl = error.authUrl;
      log(`Notion MCP: link your account at ${error.authUrl}`);
    }
  };
  const unavailable = async error => {
    await disconnect();
    if (error instanceof AuthUnavailable) {
      reportAuth(error);
      return true;
    }
    // Avoid returning SDK errors or upstream response bodies to the client.
    throw new McpError(ErrorCode.InternalError, 'Notion MCP is temporarily unavailable. Try again later.');
  };
  server.setRequestHandler(ListToolsRequestSchema, async (request, extra) => {
    try {
      const remote = await ensureClient();
      if (accessMode === 'read-write') return await remote.listTools(request.params, { signal: extra.signal });
      // A page containing only write tools must not hide later read tools.
      const tools = [];
      const seen = new Set();
      let cursor = request.params?.cursor;
      do {
        const page = await remote.listTools({ ...request.params, cursor }, { signal: extra.signal });
        tools.push(...page.tools.filter(tool => toolAllowed(tool.name, accessMode)).map(readTool));
        cursor = page.nextCursor;
        if (cursor && seen.has(cursor)) throw new Error('Repeated upstream cursor');
        seen.add(cursor);
      } while (cursor);
      return { tools };
    } catch (error) {
      if (await unavailable(error)) return { tools: [] };
    }
  });
  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    // Enforce before acquiring credentials or calling Notion. Hiding a write
    // tool from discovery alone does not stop stale or handcrafted calls.
    if (!callAllowed(request.params, accessMode)) return {
      isError: true,
      content: [{ type: 'text', text: `Tool ${request.params.name} is disabled in Notion MCP read-only mode.` }],
    };
    try {
      const params = accessMode === 'read-only' && ['notion-search', 'search'].includes(request.params.name)
        ? { ...request.params, arguments: { ...request.params.arguments, query_type: 'internal' } }
        : request.params;
      return await (await ensureClient()).callTool(params, undefined, { signal: extra.signal });
    } catch (error) {
      if (await unavailable(error)) return {
        isError: true,
        content: [{ type: 'text', text: error.authUrl
          ? `Open ${error.authUrl} to link Notion in Coder, then retry. Authentication is optional for this workspace.`
          : `Link Notion in Coder to use Notion tools. Run \`coder external-auth access-token ${providerId}\` in the workspace to obtain the authentication URL. Authentication is optional for this workspace.` }],
      };
    }
  });
  // Clients can discover newly linked accounts without restarting. Also
  // detect account removal while idle; revoked tokens are caught by fetch.
  const checkAuth = async () => {
    try { await ensureClient(); } catch (error) { reportAuth(error); await disconnect(); }
  };
  server.oninitialized = () => {
    initialized = true;
    poll = setInterval(() => { checkAuth(); }, 30000);
    poll.unref();
    // Defer until the initial stdio handshake has completed.
    setImmediate(() => { checkAuth(); });
  };
  const close = () => shutdownPromise ??= (async () => {
    closed = true;
    clearInterval(poll);
    await disconnect();
    await connecting?.catch(() => {});
    await server.close();
  })();
  return { server, checkAuth, close };
}

async function main() {
  const providerId = process.argv[2] || 'notion';
  if (!/^[a-z0-9][a-z0-9-]*$/.test(providerId)) throw new Error('Invalid provider ID');
  const adapter = createAdapter({ providerId, accessMode: process.argv[3] || 'read-only' });
  await adapter.server.connect(new StdioServerTransport());
  process.stdin.once('end', () => { adapter.close(); });
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
    adapter.close().finally(() => process.exit(0));
  });
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => {
    console.error('Notion MCP: unable to start the adapter.');
    process.exitCode = 1;
  });
}

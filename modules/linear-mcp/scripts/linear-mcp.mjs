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
export const LINEAR_URL = 'https://mcp.linear.app/mcp/readonly';
export class AuthUnavailable extends Error {}

export async function coderToken(providerId) {
  try {
    const { stdout } = await run(process.env.GIT_ASKPASS || 'coder',
      ['external-auth', 'access-token', providerId], { timeout: 10000, maxBuffer: 65536 });
    const token = stdout.trim();
    if (!token || /\s/.test(token)) throw new AuthUnavailable();
    return token;
  } catch {
    // Subprocess errors may contain stdout/stderr with sensitive credentials.
    throw new AuthUnavailable();
  }
}

export function createAdapter({ providerId = 'linear', getToken = () => coderToken(providerId), fetchImpl = fetch } = {}) {
  const server = new Server({ name: 'coder-linear-mcp', version: '1.0.0' }, {
    capabilities: { tools: { listChanged: true } },
  });
  let client;
  let connecting;
  let initialized = false;
  let closed = false;
  let poll;
  let shutdownPromise;
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
    // official read-only endpoint. No OAuth provider/browser flow is used.
    if (String(url) !== LINEAR_URL) throw new Error('Unexpected MCP endpoint');
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
      const candidate = new Client({ name: 'coder-linear-mcp', version: '1.0.0' });
      try {
        await candidate.connect(new StreamableHTTPClientTransport(new URL(LINEAR_URL), {
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
  const unavailable = async error => {
    await disconnect();
    if (error instanceof AuthUnavailable) return true;
    // Avoid returning SDK errors or upstream response bodies to the client.
    throw new McpError(ErrorCode.InternalError, 'Linear MCP is temporarily unavailable. Try again later.');
  };
  server.setRequestHandler(ListToolsRequestSchema, async request => {
    try {
      return await (await ensureClient()).listTools(request.params);
    } catch (error) {
      if (await unavailable(error)) return { tools: [] };
    }
  });
  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    try {
      return await (await ensureClient()).callTool(request.params, undefined, { signal: extra.signal });
    } catch (error) {
      if (await unavailable(error)) return {
        isError: true,
        content: [{ type: 'text', text: 'Link Linear in Coder to use Linear tools. Authentication is optional for this workspace.' }],
      };
    }
  });
  // Clients can discover newly linked accounts without restarting. Also
  // detect account removal while idle; revoked tokens are caught by fetch.
  const checkAuth = async () => {
    try { await ensureClient(); } catch { await disconnect(); }
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
  const providerId = process.argv[2] || 'linear';
  if (!/^[a-z0-9][a-z0-9-]*$/.test(providerId)) throw new Error('Invalid provider ID');
  const adapter = createAdapter({ providerId });
  await adapter.server.connect(new StdioServerTransport());
  process.stdin.once('end', () => { adapter.close(); });
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
    adapter.close().finally(() => process.exit(0));
  });
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => {
    console.error('Linear MCP: unable to start the adapter.');
    process.exitCode = 1;
  });
}

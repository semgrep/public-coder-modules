import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { ToolListChangedNotificationSchema } from '@modelcontextprotocol/sdk/types.js';
import { AuthUnavailable, authenticationUrl, createAdapter, NOTION_URL } from '../scripts/notion-mcp.mjs';

function fakeNotion(accessMode = 'read-only') {
  const endpoint = NOTION_URL;
  const requests = [];
  const fetchImpl = async (url, options) => {
    assert.equal(String(url), endpoint);
    assert.equal(options.redirect, 'error');
    requests.push({ method: options.method, token: options.headers.get('authorization'), body: options.body });
    if (options.method !== 'POST') return new Response(null, { status: 405 });
    const message = JSON.parse(options.body);
    if (!('id' in message)) return new Response(null, { status: 202 });
    let result;
    if (message.method === 'initialize') result = {
      protocolVersion: message.params.protocolVersion,
      capabilities: { tools: {} }, serverInfo: { name: 'fake-notion', version: '1' },
    };
    else if (message.method === 'tools/list') result = {
      tools: [
        { name: 'notion-fetch', description: 'Read pages', inputSchema: { type: 'object' } },
        { name: 'notion-create-pages', inputSchema: { type: 'object' } },
        { name: 'notion-update-page', inputSchema: { type: 'object' } },
        { name: 'notion-spawn-session', inputSchema: { type: 'object' } },
        { name: 'notion-future-write', annotations: { readOnlyHint: true }, inputSchema: { type: 'object' } },
      ],
    };
    else result = { content: [{ type: 'text', text: 'Example page' }] };
    return Response.json({ jsonrpc: '2.0', id: message.id, result });
  };
  return { fetchImpl, requests };
}

async function connect(t, options) {
  const adapter = createAdapter(options);
  const client = new Client({ name: 'test', version: '1' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await adapter.server.connect(serverTransport);
  await client.connect(clientTransport);
  t.after(async () => { await adapter.close(); await client.close(); });
  return { adapter, client };
}

test('initialization and idle time do not acquire credentials or contact the provider', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let credentials = 0;
  const remote = fakeNotion();
  const { client } = await connect(t, {
    getToken: async () => { credentials++; return 'fake-token'; },
    fetchImpl: remote.fetchImpl,
  });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(credentials, 0);
  assert.equal(remote.requests.length, 0);
  t.mock.timers.tick(120000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(credentials, 0);
  assert.equal(remote.requests.length, 0);

  await client.listTools();
  const used = credentials;
  assert.ok(used > 0);
  t.mock.timers.tick(120000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(credentials, used);
  assert.equal(remote.requests.length, used);
});

test('unlinked accounts initialize successfully and expose zero tools without network calls', async t => {
  const { client } = await connect(t, {
    getToken: async () => { throw new AuthUnavailable(); },
    fetchImpl: async () => assert.fail('unlinked accounts must not contact Notion'),
  });
  assert.deepEqual(await client.listTools(), { tools: [] });
  await client.ping();
  const call = await client.callTool({ name: 'notion-fetch', arguments: {} });
  assert.equal(call.isError, true);
  assert.match(call.content[0].text, /Link Notion in Coder/);
});

test('linking and unlinking update tools on the same MCP connection', async t => {
  let linked = false;
  const remote = fakeNotion();
  const { client } = await connect(t, {
    getToken: async () => { if (!linked) throw new AuthUnavailable(); return 'fake-token'; },
    fetchImpl: remote.fetchImpl,
  });
  assert.deepEqual((await client.listTools()).tools, []);
  let changes = 0;
  client.setNotificationHandler(ToolListChangedNotificationSchema, () => { changes++; });
  linked = true;
  assert.equal((await client.listTools()).tools[0].name, 'notion-fetch');
  assert.equal((await client.callTool({ name: 'notion-fetch', arguments: {} })).content[0].text, 'Example page');
  linked = false;
  assert.equal((await client.callTool({ name: 'notion-search', arguments: {} })).isError, true);
  assert.deepEqual((await client.listTools()).tools, []);
  await client.ping();
  assert.ok(changes >= 2);
});

test('each upstream request retrieves a fresh Coder token, including long sessions', async t => {
  let credentials = 0;
  const remote = fakeNotion();
  const { client } = await connect(t, {
    getToken: async () => `token-${++credentials}`, fetchImpl: remote.fetchImpl,
  });
  await client.listTools();
  await client.callTool({ name: 'notion-fetch', arguments: {} });
  const tokens = remote.requests.map(request => request.token);
  assert.ok(tokens.length >= 3);
  assert.equal(new Set(tokens).size, tokens.length);
  assert.equal(credentials, remote.requests.length, 'no redundant token preflight checks');
});

test('rejected OAuth credentials leave a healthy empty MCP without browser authentication', async t => {
  const { client } = await connect(t, {
    getToken: async () => 'revoked-token',
    fetchImpl: async () => new Response('sensitive upstream body', {
      status: 401, headers: { 'www-authenticate': 'Bearer resource_metadata="https://example.invalid"' },
    }),
  });
  assert.deepEqual((await client.listTools()).tools, []);
  await client.ping();
});

test('upstream outages produce sanitized errors and recover on a subsequent request', async t => {
  const remote = fakeNotion();
  let failing = true;
  const { client } = await connect(t, {
    getToken: async () => 'fake-token',
    fetchImpl: async (...args) => { if (failing) throw new Error('sensitive-error-body'); return remote.fetchImpl(...args); },
  });
  await assert.rejects(client.listTools(), error => {
    assert.match(error.message, /temporarily unavailable/);
    assert.ok(!error.message.includes('sensitive-error-body'));
    return true;
  });
  failing = false;
  assert.equal((await client.listTools()).tools[0].name, 'notion-fetch');
});

test('actual stdio launcher remains healthy when the Coder subprocess is not authenticated', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'coder-notion-unlinked-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const fakeCoder = join(directory, 'coder');
  await writeFile(fakeCoder, '#!/bin/sh\necho sensitive-subprocess-error >&2\nexit 1\n', { mode: 0o700 });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [new URL('../scripts/notion-mcp.mjs', import.meta.url).pathname, 'custom-notion'],
    env: { GIT_ASKPASS: fakeCoder }, stderr: 'pipe',
  });
  let stderr = '';
  transport.stderr.on('data', chunk => { stderr += chunk; });
  const client = new Client({ name: 'stdio-test', version: '1' });
  t.after(() => client.close());
  await client.connect(transport);
  assert.deepEqual((await client.listTools()).tools, []);
  await client.ping();
  await client.close();
  assert.equal(stderr, '');
});

for (const mode of ['read-only', 'read-write']) {
  test(`${mode} selects its fixed official endpoint and corresponding tools`, async t => {
    const remote = fakeNotion(mode);
    const { client } = await connect(t, {
      accessMode: mode, getToken: async () => 'fake-token', fetchImpl: remote.fetchImpl,
    });
    const names = (await client.listTools()).tools.map(tool => tool.name);
    assert.deepEqual(names, mode === 'read-only' ? ['notion-fetch'] : ['notion-fetch', 'notion-create-pages', 'notion-update-page', 'notion-spawn-session', 'notion-future-write']);
  });
}

test('invalid access modes cannot select an arbitrary endpoint', () => {
  assert.throws(() => createAdapter({ accessMode: 'https://example.invalid' }), /Invalid Notion access mode/);
});

test('unlinked tool replies include Coder linking URL and diagnostics are emitted once', async t => {
  const url = 'https://coder.example.test/external-auth/notion';
  const messages = [];
  const { client } = await connect(t, {
    getToken: async () => { throw new AuthUnavailable(url); },
    log: message => messages.push(message),
    fetchImpl: async () => assert.fail('must not contact Notion'),
  });
  assert.deepEqual((await client.listTools()).tools, []);
  const result = await client.callTool({ name: 'notion-fetch', arguments: {} });
  assert.equal(result.isError, true);
  assert.ok(result.content[0].text.includes(url));
  await client.listTools();
  await client.ping();
  assert.deepEqual(messages, [`Notion MCP: link your account at ${url}`]);
});

test('authentication URL parsing strips queries and rejects arbitrary subprocess output', () => {
  assert.equal(authenticationUrl('https://coder.example.test/external-auth/notion?secret=redacted#fragment', 'notion'),
    'https://coder.example.test/external-auth/notion');
  for (const output of ['sensitive-token', 'https://example.test/not-a-link',
    'https://user:password@coder.example.test/external-auth/notion',
    'Error: https://coder.example.test/external-auth/notion']) {
    assert.equal(authenticationUrl(output, 'notion'), undefined);
  }
});

test('real Coder CLI exit-one URL reaches the stdio tool result without leaking diagnostics', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'coder-notion-url-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const fakeCoder = join(directory, 'coder');
  await writeFile(fakeCoder, '#!/bin/sh\necho https://coder.example.test/external-auth/custom-notion?secret=redacted\necho sensitive-error >&2\nexit 1\n', { mode: 0o700 });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [new URL('../scripts/notion-mcp.mjs', import.meta.url).pathname, 'custom-notion'],
    env: { GIT_ASKPASS: fakeCoder }, stderr: 'pipe',
  });
  let stderr = '';
  transport.stderr.on('data', chunk => { stderr += chunk; });
  const client = new Client({ name: 'url-test', version: '1' });
  t.after(() => client.close());
  await client.connect(transport);
  const result = await client.callTool({ name: 'notion-fetch', arguments: {} });
  assert.ok(result.content[0].text.includes('https://coder.example.test/external-auth/custom-notion'));
  assert.ok(!result.content[0].text.includes('secret='));
  await client.close();
  assert.ok(stderr.includes('https://coder.example.test/external-auth/custom-notion'));
  assert.ok(!stderr.includes('secret=') && !stderr.includes('sensitive-error'));
});

test('read-only blocks direct, stale, and unknown write calls before they reach Notion', async t => {
  const remote = fakeNotion();
  const { client } = await connect(t, {
    accessMode: 'read-only', getToken: async () => 'write-capable-fake-token', fetchImpl: remote.fetchImpl,
  });
  assert.deepEqual((await client.listTools()).tools.map(tool => tool.name), ['notion-fetch']);
  for (const name of ['notion-create-pages', 'notion-update-page', 'notion-spawn-session', 'notion-future-write', 'notion-read-and-delete']) {
    const result = await client.callTool({ name, arguments: {} });
    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /disabled.*read-only/);
  }
  assert.equal(remote.requests.filter(r => r.body && JSON.parse(r.body).method === 'tools/call').length, 0);
  assert.equal((await client.callTool({ name: 'notion-fetch', arguments: {} })).content[0].text, 'Example page');
});

test('read-write forwards explicitly enabled write calls to the simulated upstream', async t => {
  const remote = fakeNotion();
  const { client } = await connect(t, {
    accessMode: 'read-write', getToken: async () => 'fake-token', fetchImpl: remote.fetchImpl,
  });
  assert.equal((await client.callTool({ name: 'notion-create-pages', arguments: {} })).isError, undefined);
  assert.ok(remote.requests.some(r => r.body && JSON.parse(r.body).params?.name === 'notion-create-pages'));
});

test('read-only discovery traverses a write-only page to find later read tools', async t => {
  const remote = fakeNotion();
  let pages = 0;
  const { client } = await connect(t, {
    getToken: async () => 'fake-token',
    fetchImpl: async (url, options) => {
      const message = options.body ? JSON.parse(options.body) : undefined;
      if (message?.method !== 'tools/list') return remote.fetchImpl(url, options);
      pages++;
      const result = message.params?.cursor === 'page-two'
        ? { tools: [{ name: 'notion-get-comments', inputSchema: { type: 'object' } }] }
        : { tools: [{ name: 'notion-create-pages', inputSchema: { type: 'object' } }], nextCursor: 'page-two' };
      return Response.json({ jsonrpc: '2.0', id: message.id, result });
    },
  });
  const result = await client.listTools();
  assert.deepEqual(result.tools.map(tool => tool.name), ['notion-get-comments']);
  assert.equal(result.nextCursor, undefined);
  assert.equal(pages, 2);
});

test('read-write discovery sanitizes auth rejection after a session is established', async t => {
  const remote = fakeNotion();
  let revoked = false;
  const { client } = await connect(t, {
    accessMode: 'read-write', getToken: async () => 'fake-token',
    fetchImpl: async (url, options) => revoked
      ? new Response('sensitive Notion response', { status: 401 })
      : remote.fetchImpl(url, options),
  });
  assert.ok((await client.listTools()).tools.length > 1);
  revoked = true;
  assert.deepEqual((await client.listTools()).tools, []);
  await client.ping();
});

test('read-only blocks user lookup and legacy identity fetch before authentication', async t => {
  const { client } = await connect(t, {
    getToken: async () => { throw new Error('must not retrieve credentials'); },
    fetchImpl: async () => assert.fail('must not forward disallowed reads'),
  });
  for (const name of ['notion-search', 'search']) {
    for (const query_type of ['user', 'future-type']) {
      assert.equal((await client.callTool({ name, arguments: { query: 'example', query_type } })).isError, true);
    }
  }
  for (const name of ['notion-fetch', 'fetch']) {
    assert.equal((await client.callTool({ name, arguments: { id: 'self' } })).isError, true);
  }
});

test('read-only excludes identity, agents, memory, and future tools despite annotations', async t => {
  const { client } = await connect(t, {
    getToken: async () => { throw new Error('must not retrieve credentials'); },
    fetchImpl: async () => assert.fail('must not forward blocked tools'),
  });
  for (const name of ['notion-get-users', 'notion-get-self', 'notion-get-teams', 'notion-get-groups',
    'notion-spawn-session', 'notion-send-message-to-session', 'notion-search-agents',
    'notion-memory-search', 'notion-check-mcp-next-steps', 'notion-ai-search', 'ai-search']) {
    assert.equal((await client.callTool({ name, arguments: {} })).isError, true);
  }
});

test('read-only narrows search discovery and forces internal content queries', async t => {
  const remote = fakeNotion();
  const { client } = await connect(t, {
    getToken: async () => 'fake-token',
    fetchImpl: async (url, options) => {
      const msg = options.body ? JSON.parse(options.body) : undefined;
      if (msg?.method !== 'tools/list') return remote.fetchImpl(url, options);
      return Response.json({ jsonrpc: '2.0', id: msg.id, result: { tools:
        ['notion-search', 'search'].map(name => ({ name, inputSchema: { type: 'object',
          properties: { query: { type: 'string' }, query_type: { type: 'string', enum: ['internal', 'user'] } },
          required: ['query'] } })) } });
    },
  });
  const tools = (await client.listTools()).tools;
  assert.equal(tools.length, 2);
  for (const tool of tools) {
    assert.deepEqual(tool.inputSchema.properties.query_type.enum, ['internal']);
    await client.callTool({ name: tool.name, arguments: { query: 'example' } });
  }
  const calls = remote.requests.filter(r => r.body && JSON.parse(r.body).method === 'tools/call');
  assert.equal(calls.length, 2);
  for (const call of calls) assert.equal(JSON.parse(call.body).params.arguments.query_type, 'internal');
});

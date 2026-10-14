import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { ToolListChangedNotificationSchema } from '@modelcontextprotocol/sdk/types.js';
import { AuthUnavailable, createAdapter, LINEAR_URL } from '../scripts/linear-mcp.mjs';

function fakeLinear() {
  const requests = [];
  const fetchImpl = async (url, options) => {
    assert.equal(String(url), LINEAR_URL);
    assert.equal(options.redirect, 'error');
    requests.push({ method: options.method, token: options.headers.get('authorization') });
    if (options.method !== 'POST') return new Response(null, { status: 405 });
    const message = JSON.parse(options.body);
    if (!('id' in message)) return new Response(null, { status: 202 });
    let result;
    if (message.method === 'initialize') result = {
      protocolVersion: message.params.protocolVersion,
      capabilities: { tools: {} }, serverInfo: { name: 'fake-linear', version: '1' },
    };
    else if (message.method === 'tools/list') result = {
      tools: [{ name: 'list_issues', description: 'Read issues', inputSchema: { type: 'object' } }],
    };
    else result = { content: [{ type: 'text', text: 'Example issue' }] };
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

test('unlinked accounts initialize successfully and expose zero tools without network calls', async t => {
  const { client } = await connect(t, {
    getToken: async () => { throw new AuthUnavailable(); },
    fetchImpl: async () => assert.fail('unlinked accounts must not contact Linear'),
  });
  assert.deepEqual(await client.listTools(), { tools: [] });
  await client.ping();
  const call = await client.callTool({ name: 'list_issues', arguments: {} });
  assert.equal(call.isError, true);
  assert.match(call.content[0].text, /Link Linear in Coder/);
});

test('linking and unlinking update tools on the same MCP connection', async t => {
  let linked = false;
  const remote = fakeLinear();
  const { adapter, client } = await connect(t, {
    getToken: async () => { if (!linked) throw new AuthUnavailable(); return 'fake-token'; },
    fetchImpl: remote.fetchImpl,
  });
  assert.deepEqual((await client.listTools()).tools, []);
  let changes = 0;
  client.setNotificationHandler(ToolListChangedNotificationSchema, () => { changes++; });
  linked = true;
  await adapter.checkAuth();
  assert.equal((await client.listTools()).tools[0].name, 'list_issues');
  assert.equal((await client.callTool({ name: 'list_issues', arguments: {} })).content[0].text, 'Example issue');
  linked = false;
  await adapter.checkAuth();
  assert.deepEqual((await client.listTools()).tools, []);
  await client.ping();
  assert.ok(changes >= 2);
});

test('each upstream request retrieves a fresh Coder token, including long sessions', async t => {
  let credentials = 0;
  const remote = fakeLinear();
  const { client } = await connect(t, {
    getToken: async () => `token-${++credentials}`, fetchImpl: remote.fetchImpl,
  });
  await client.listTools();
  await client.callTool({ name: 'list_issues', arguments: {} });
  const tokens = remote.requests.map(request => request.token);
  assert.ok(tokens.length >= 3);
  assert.equal(new Set(tokens).size, tokens.length);
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
  const remote = fakeLinear();
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
  assert.equal((await client.listTools()).tools[0].name, 'list_issues');
});

test('actual stdio launcher remains healthy when the Coder subprocess is not authenticated', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'coder-linear-unlinked-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const fakeCoder = join(directory, 'coder');
  await writeFile(fakeCoder, '#!/bin/sh\necho sensitive-subprocess-error >&2\nexit 1\n', { mode: 0o700 });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [new URL('../scripts/linear-mcp.mjs', import.meta.url).pathname, 'custom-linear'],
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

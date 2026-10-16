import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { test } from 'node:test';

const run = promisify(execFile);
const mockNode = '#!/bin/sh\nprintf "%s\\n" "$@"\n';

async function fixture(t, layout, preinstalled = false) {
  const directory = await mkdtemp(join(tmpdir(), 'notion-installer-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const home = join(directory, 'home');
  const bin = join(directory, 'bin');
  const app = join(home, '.local/share/coder-notion-mcp/app');
  const runtime = join(home, '.local/share/coder-notion-mcp/pnpm', layout === 'v11' ? 'bin/node' : 'node');
  const calls = join(directory, 'pnpm-calls');
  await mkdir(bin, { recursive: true });
  // Fake pnpm models the two documented install layouts without network access.
  await writeFile(join(bin, 'pnpm'), `#!/bin/sh
set -eu
printf '%s\\n' "$*" >> '${calls}'
if [ "$1" = env ]; then
  ${layout === 'missing' ? 'exit 0' : `mkdir -p "$(dirname '${runtime}')"
  cat > '${runtime}' <<'NODE'
${mockNode}NODE
  chmod 0755 '${runtime}'`}
elif [ "$1" = --dir ]; then
  mkdir -p "$2/node_modules/@modelcontextprotocol/sdk"
else
  exit 2
fi
`, { mode: 0o755 });
  if (preinstalled) {
    await mkdir(join(runtime, '..'), { recursive: true });
    await writeFile(runtime, mockNode, { mode: 0o755 });
  }
  let script = await readFile(new URL('../scripts/install.sh.tpl', import.meta.url), 'utf8');
  const values = { package_json: '{}', pnpm_lock: 'lockfileVersion: 9.0',
    adapter_js: '// test adapter', dependency_hash: 'test-lock-hash',
    external_auth_id: 'notion-test', access_mode: 'read-only' };
  for (const [key, value] of Object.entries(values)) script = script.replaceAll('${' + key + '}', value);
  // Isolate filesystem writes without replacing the process HOME environment.
  script = script.replaceAll('$HOME', home)
    .replace('PNPM=/usr/local/share/pnpm/bin/pnpm', `PNPM=${directory}/missing-pnpm`);
  const installer = join(directory, 'install.sh');
  await writeFile(installer, script);
  const install = () => run('sh', [installer], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } });
  return { home, app, calls, install };
}

for (const layout of ['v10', 'v11']) {
  for (const preinstalled of [false, true]) {
    test(`${layout} ${preinstalled ? 'existing' : 'fresh'} runtime launches and is reused on restart`, async t => {
      const f = await fixture(t, layout, preinstalled);
      assert.match((await f.install()).stdout, /Notion MCP installed/);
      const launcher = join(f.home, '.local/bin/coder-notion-mcp');
      const expected = [join(f.app, 'notion-mcp.mjs'), 'notion-test', 'read-only'];
      assert.deepEqual((await run(launcher)).stdout.trim().split('\n'), expected);
      await f.install();
      assert.deepEqual((await run(launcher)).stdout.trim().split('\n'), expected);
      const calls = (await readFile(f.calls, 'utf8')).trim().split('\n');
      assert.equal(calls.filter(c => c === 'env use --global 24').length, preinstalled ? 0 : 1);
      assert.equal(calls.filter(c => c.includes('--frozen-lockfile --ignore-scripts')).length, 1);
    });
  }
}

test('pnpm success without a usable runtime fails installation', async t => {
  const f = await fixture(t, 'missing');
  await assert.rejects(f.install(), error => {
    assert.equal(error.code, 1);
    assert.match(error.stderr, /did not install a usable Node runtime/);
    assert.ok(!error.stdout.includes('Notion MCP installed'));
    return true;
  });
});

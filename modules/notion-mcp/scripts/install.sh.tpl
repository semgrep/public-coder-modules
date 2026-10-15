#!/bin/sh
# Install without requesting credentials; linking Notion is optional.
set -eu
umask 077
PNPM=/usr/local/share/pnpm/bin/pnpm
[ -x "$PNPM" ] || PNPM="$(command -v pnpm)" || { echo 'Standalone pnpm is required to install Notion MCP.' >&2; exit 1; }
notion_dir="$HOME/.local/share/coder-notion-mcp"
export PNPM_HOME="$notion_dir/pnpm"
mkdir -p "$PNPM_HOME/bin" "$HOME/.local/bin" "$notion_dir/app"
export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"
if [ ! -x "$PNPM_HOME/bin/node" ]; then
  "$PNPM" env use --global 24
fi
cat > "$notion_dir/app/package.json" <<'PACKAGE'
${package_json}
PACKAGE
cat > "$notion_dir/app/pnpm-lock.yaml" <<'LOCK'
${pnpm_lock}
LOCK
if [ ! -d "$notion_dir/app/node_modules/@modelcontextprotocol/sdk" ] || \
   [ "$(cat "$notion_dir/dependency-hash" 2>/dev/null || true)" != '${dependency_hash}' ]; then
  "$PNPM" --dir "$notion_dir/app" install --frozen-lockfile --ignore-scripts
  printf '%s\n' '${dependency_hash}' > "$notion_dir/dependency-hash"
fi
cat > "$notion_dir/app/notion-mcp.mjs" <<'ADAPTER'
${adapter_js}
ADAPTER
cat > "$HOME/.local/bin/coder-notion-mcp" <<'LAUNCHER'
#!/bin/sh
exec "$HOME/.local/share/coder-notion-mcp/pnpm/bin/node" \
  "$HOME/.local/share/coder-notion-mcp/app/notion-mcp.mjs" '${external_auth_id}' '${access_mode}'
LAUNCHER
chmod 0755 "$HOME/.local/bin/coder-notion-mcp"
echo 'Notion MCP installed (${access_mode}); unlinked accounts expose no tools.'

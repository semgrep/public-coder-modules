#!/bin/sh
# Install without requesting credentials; linking Linear is optional.
set -eu
umask 077
PNPM=/usr/local/share/pnpm/bin/pnpm
[ -x "$PNPM" ] || PNPM="$(command -v pnpm)" || { echo 'Standalone pnpm is required to install Linear MCP.' >&2; exit 1; }
linear_dir="$HOME/.local/share/coder-linear-mcp"
export PNPM_HOME="$linear_dir/pnpm"
mkdir -p "$PNPM_HOME/bin" "$HOME/.local/bin" "$linear_dir/app"
export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"
if [ ! -x "$PNPM_HOME/bin/node" ]; then
  "$PNPM" env use --global 24
fi
cat > "$linear_dir/app/package.json" <<'PACKAGE'
${package_json}
PACKAGE
cat > "$linear_dir/app/pnpm-lock.yaml" <<'LOCK'
${pnpm_lock}
LOCK
if [ ! -d "$linear_dir/app/node_modules/@modelcontextprotocol/sdk" ] || \
   [ "$(cat "$linear_dir/dependency-hash" 2>/dev/null || true)" != '${dependency_hash}' ]; then
  "$PNPM" --dir "$linear_dir/app" install --frozen-lockfile --ignore-scripts
  printf '%s\n' '${dependency_hash}' > "$linear_dir/dependency-hash"
fi
cat > "$linear_dir/app/linear-mcp.mjs" <<'ADAPTER'
${adapter_js}
ADAPTER
cat > "$HOME/.local/bin/coder-linear-mcp" <<'LAUNCHER'
#!/bin/sh
exec "$HOME/.local/share/coder-linear-mcp/pnpm/bin/node" \
  "$HOME/.local/share/coder-linear-mcp/app/linear-mcp.mjs" '${external_auth_id}' '${access_mode}'
LAUNCHER
chmod 0755 "$HOME/.local/bin/coder-linear-mcp"
echo 'Linear MCP installed (${access_mode}); unlinked accounts expose no tools.'

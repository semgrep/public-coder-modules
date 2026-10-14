#!/bin/sh
# Install without requesting credentials; linking Slack is optional.
set -eu
umask 077
PNPM=/usr/local/share/pnpm/bin/pnpm
[ -x "$PNPM" ] || PNPM="$(command -v pnpm)" || { echo 'Standalone pnpm is required to install Slack MCP.' >&2; exit 1; }
slack_dir="$HOME/.local/share/coder-slack-mcp"
export PNPM_HOME="$slack_dir/pnpm"
mkdir -p "$PNPM_HOME/bin" "$HOME/.local/bin" "$slack_dir/app"
export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"
if [ ! -x "$PNPM_HOME/bin/node" ]; then
  "$PNPM" env use --global 24
fi
cat > "$slack_dir/app/package.json" <<'PACKAGE'
${package_json}
PACKAGE
cat > "$slack_dir/app/pnpm-lock.yaml" <<'LOCK'
${pnpm_lock}
LOCK
if [ ! -d "$slack_dir/app/node_modules/@modelcontextprotocol/sdk" ] || \
   [ "$(cat "$slack_dir/dependency-hash" 2>/dev/null || true)" != '${dependency_hash}' ]; then
  "$PNPM" --dir "$slack_dir/app" install --frozen-lockfile --ignore-scripts
  printf '%s\n' '${dependency_hash}' > "$slack_dir/dependency-hash"
fi
cat > "$slack_dir/app/slack-mcp.mjs" <<'ADAPTER'
${adapter_js}
ADAPTER
cat > "$HOME/.local/bin/coder-slack-mcp" <<'LAUNCHER'
#!/bin/sh
exec "$HOME/.local/share/coder-slack-mcp/pnpm/bin/node" \
  "$HOME/.local/share/coder-slack-mcp/app/slack-mcp.mjs" '${external_auth_id}' '${access_mode}'
LAUNCHER
chmod 0755 "$HOME/.local/bin/coder-slack-mcp"
echo 'Slack MCP installed (${access_mode}); unlinked accounts expose no tools.'

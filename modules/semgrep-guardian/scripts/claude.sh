#!/bin/sh
set -eu

export PATH="$PATH:$HOME/.local/bin"
plugin='semgrep@claude-plugins-official'

fail() {
  echo "Guardian (Claude Code): $1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail 'Run this script after installing Claude Code.'
command -v jq >/dev/null 2>&1 || fail 'jq is required.'

# Use the harness CLI rather than rewriting settings or its plugin registry.
# Run from HOME so repository-local settings do not affect the setup check.
cd "$HOME"
plugins=$(claude plugin list --json) || fail 'Could not list plugins; Claude Code must support plugin commands.'
printf '%s\n' "$plugins" | jq -e 'type == "array"' >/dev/null \
  || fail 'Unexpected plugin list JSON.'

if ! printf '%s\n' "$plugins" | jq -e --arg id "$plugin" \
  'any(.[]; .id == $id and .scope == "user")' >/dev/null; then
  # A fresh CLI may not yet have cached the official marketplace.
  marketplaces=$(claude plugin marketplace list --json) || fail 'Could not list marketplaces.'
  printf '%s\n' "$marketplaces" | jq -e 'type == "array"' >/dev/null \
    || fail 'Unexpected marketplace list JSON.'
  if ! printf '%s\n' "$marketplaces" | jq -e \
    'any(.[]; .name == "claude-plugins-official")' >/dev/null; then
    claude plugin marketplace add anthropics/claude-plugins-official </dev/null \
      || fail 'Could not add the Claude official marketplace.'
  fi
  claude plugin install "$plugin" --scope user </dev/null || fail 'Plugin installation failed.'
fi

# Installation can be an already-installed no-op, so enable explicitly.
claude plugin enable "$plugin" --scope user </dev/null || fail 'Could not enable Guardian.'
plugins=$(claude plugin list --json) || fail 'Could not verify plugins.'
printf '%s\n' "$plugins" | jq -e --arg id "$plugin" \
  'any(.[]; .id == $id and .scope == "user" and .enabled == true and ((.errors // []) | length == 0))' >/dev/null \
  || fail 'Guardian is not installed and enabled at user scope.'

echo 'Guardian is installed and enabled for Claude Code. Sign in to Semgrep in a new session if needed.'

#!/bin/sh
set -eu

export PATH="$PATH:$HOME/.local/bin"
plugin='semgrep@semgrep-marketplace'

fail() {
  echo "Guardian (Codex): $1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail 'Run this script after installing Codex.'
command -v jq >/dev/null 2>&1 || fail 'jq is required.'

cd "$HOME"
plugins=$(codex plugin list --json) || fail 'Could not list plugins; Codex must support plugin commands.'
printf '%s\n' "$plugins" | jq -e '.installed | type == "array"' >/dev/null \
  || fail 'Unexpected plugin list JSON.'

if ! printf '%s\n' "$plugins" | jq -e --arg id "$plugin" \
  'any(.installed[]; .pluginId == $id and .installed == true and .enabled == true)' >/dev/null; then
  # The full Guardian repository history can exceed the marketplace timeout.
  codex plugin marketplace add https://github.com/semgrep/guardian \
    --sparse .claude-plugin --sparse plugin </dev/null || fail 'Could not add the Guardian marketplace.'
  # Adding an installed plugin also re-enables it in Codex's user config.
  codex plugin add "$plugin" </dev/null || fail 'Could not install or enable Guardian.'
fi

plugins=$(codex plugin list --json) || fail 'Could not verify plugins.'
printf '%s\n' "$plugins" | jq -e --arg id "$plugin" \
  'any(.installed[]; .pluginId == $id and .installed == true and .enabled == true)' >/dev/null \
  || fail 'Guardian is not installed and enabled.'

echo 'Guardian is installed and enabled for Codex. Sign in to Semgrep and review plugin hooks in a new session if needed.'

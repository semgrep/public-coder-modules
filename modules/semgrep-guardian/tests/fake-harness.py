#!/usr/bin/env python3
"""Stateful harness fixture; never invokes a real harness or uses its config."""

import json
import os
from pathlib import Path
import sys

root = Path(os.environ["GUARDIAN_TEST_STATE"])
state_path = root / "plugins.json"
state = json.loads(state_path.read_text())
harness = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps([harness, *args]) + "\n")

if args == ["plugin", "list", "--json"]:
    if os.environ.get("GUARDIAN_TEST_LIST_FAIL"):
        sys.exit(1)
    if os.environ.get("GUARDIAN_TEST_BAD_JSON"):
        print('{"unexpected":true}')
    else:
        print(json.dumps(state if harness == "claude" else {"installed": state, "available": []}))
    sys.exit(0)

if os.environ.get("GUARDIAN_TEST_MUTATION_FAIL"):
    sys.exit(1)

if harness == "claude" and args == ["plugin", "marketplace", "list", "--json"]:
    marketplaces = [{"name": "claude-plugins-official"}] if (root / "marketplace").exists() else []
    print(json.dumps(marketplaces))
    sys.exit(0)

if harness == "claude" and args == ["plugin", "marketplace", "add", "anthropics/claude-plugins-official"]:
    (root / "marketplace").touch()
    sys.exit(0)

if harness == "codex" and args == [
    "plugin", "marketplace", "add", "https://github.com/semgrep/guardian",
    "--sparse", ".claude-plugin", "--sparse", "plugin",
]:
    sys.exit(0)

if harness == "claude":
    plugin = "semgrep@claude-plugins-official"
    valid = args in (
        ["plugin", "install", plugin, "--scope", "user"],
        ["plugin", "enable", plugin, "--scope", "user"],
    )
    key = "id"
else:
    plugin = "semgrep@semgrep-marketplace"
    valid = args == ["plugin", "add", plugin]
    key = "pluginId"
if not valid:
    raise SystemExit(f"Unexpected {harness} command: {args}")

if not os.environ.get("GUARDIAN_TEST_NO_EFFECT"):
    record = next((p for p in state if p[key] == plugin and p.get("scope", "user") == "user"), None)
    if record is None:
        record = {key: plugin, "scope": "user", "installed": True, "enabled": False}
        state.append(record)
    record["enabled"] = True
    state_path.write_text(json.dumps(state))

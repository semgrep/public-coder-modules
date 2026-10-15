# Semgrep Guardian

Exports setup scripts for the Claude Code and Codex Coder modules. Pass each
output into the harness module's `post_install_script` input so Guardian setup
runs after that harness installs, on every workspace start. This module creates
no independent startup resources: Terraform `depends_on` alone does not order
scripts running inside an agent.

```hcl
module "semgrep_guardian" {
  source = "git::https://github.com/semgrep/public-coder-modules.git//modules/semgrep-guardian?ref=<commit-sha>"
}

module "claude_code" {
  source  = "registry.coder.com/coder/claude-code/coder"
  version = "5.2.0"

  agent_id            = coder_agent.main.id
  post_install_script = module.semgrep_guardian.claude_post_install_script
  # Keep the template's existing harness settings here.
}

module "codex" {
  source  = "registry.coder.com/coder-labs/codex/coder"
  version = "5.4.0"

  agent_id            = coder_agent.main.id
  post_install_script = module.semgrep_guardian.codex_post_install_script
  # Keep the template's existing harness settings here.
}
```

Use only the output for the harnesses installed in your template. If a harness
already has a post-install script, compose it with `join("\n", [...])`; keep
Guardian in a subshell so its `cd` and shell options do not affect the other
script. For example:

```hcl
post_install_script = join("\n", [
  existing_post_install_script,
  "(\n${module.semgrep_guardian.codex_post_install_script}\n)",
])
```

## Behavior and prerequisites

- The workspace must provide `sh`, `jq`, Git and network access to the plugin
  marketplaces and Semgrep services. The respective harness must already be
  on `PATH`, or installed under `$HOME/.local/bin`.
- Claude Code must support `plugin list --json`, `plugin marketplace list --json`,
  `plugin marketplace add`, `plugin install --scope user`,
  and `plugin enable --scope user`. Codex must support `plugin list --json`,
  `plugin marketplace add --sparse`, and `plugin add`. Older harnesses fail
  with a setup error instead of receiving hand-edited config files.
- Claude installs `semgrep@claude-plugins-official` at user scope when missing
  and enables it on each run. On a fresh CLI it registers the official
  `anthropics/claude-plugins-official` marketplace first. Codex installs or re-enables
  `semgrep@semgrep-marketplace` when it is not already installed and enabled.
  The Codex marketplace uses a sparse clone of `.claude-plugin` and `plugin`
  to avoid downloading Guardian's full binary release history.
- Setup runs from the user's home, avoiding repository-local overrides during
  the verification. It uses harness CLIs to preserve unrelated configuration
  and respects `CLAUDE_CONFIG_DIR` and `CODEX_HOME` through those CLIs.
- Both scripts check the final plugin list and fail if Guardian is not
  installed and enabled. Claude load errors also fail verification. Scripts
  do not start an agent conversation or check authenticated scanner access.
- Existing enabled installations are not upgraded by this module. Initial
  installs use the current marketplace release; the module does not pin the
  plugin or disable Guardian's own updates. Pinning this module pins the
  provisioning scripts, not the downloaded Guardian version.

See the [Semgrep quickstart](https://docs.semgrep.dev/semgrep-guardian/quickstart)
for the official installation commands. No local Semgrep CLI is required for
these plugins.

## Authentication and enforcement

Each developer signs in to Semgrep through Guardian's OAuth flow in a new
harness session. Keep the harness configuration and `~/.semgrep/guardian.yml`
on the user's persistent home volume. These scripts do not read credentials,
provision shared tokens, or attempt interactive login during workspace startup.
See [Guardian authentication](https://docs.semgrep.dev/semgrep-guardian/authentication).

This module provides an installation baseline, not tamper-resistant policy.
Users can disable or remove plugins between starts, and repository settings
can override user defaults. Codex plugin hooks also require review and trust;
setup does not bypass hook trust. Verify that hooks run in an actual session,
including sessions launched through T3, before claiming scanning coverage.

For required policy, separately deploy Claude's
`/etc/claude-code/managed-settings.json` and evaluate Codex managed hooks via
`/etc/codex/requirements.toml`. Keep policy delivery in the template or another
admin-controlled mechanism. See [Semgrep enterprise deployment](https://docs.semgrep.dev/semgrep-guardian/enterprise-deployment)
and [Codex hooks](https://developers.openai.com/codex/hooks).

Template adoption is a separate change. Existing workspaces need the updated
template and a restart; already-running harness sessions need a reload or a
new session. If harnesses run inside a devcontainer, wire the same setup into
that execution environment and persist its configuration there too.

Failures appear in the harness module's post-install logs. The caller controls
startup timeouts and readiness; these script outputs do not themselves block
workspace login or prevent another independently started harness from running.

## Validation

```sh
terraform -chdir=modules/semgrep-guardian init -backend=false
terraform -chdir=modules/semgrep-guardian validate
python3 -m unittest discover -s modules/semgrep-guardian/tests -v
```

The shell tests run the real scripts against fake harness CLIs using their
documented JSON formats. They exercise first install, repeat startup,
disabled/removed plugins, unrelated plugin preservation, and failure handling
without changing a developer's harness installation. Fleet rollout still needs
a live Coder canary with OAuth and scans through each harness.

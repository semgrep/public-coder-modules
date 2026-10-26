---
display_name: "Pi Coding Agent"
description: "Installs and upgrades the Pi CLI for a Coder user at workspace start."
icon: "/icon/code.svg"
tags: ["pi", "coding-agent", "coder"]
---

# Pi Coding Agent

This module installs the [Pi coding agent](https://github.com/earendil-works/pi)
for a Coder user at workspace start. It does not launch a long-running Pi
process. The agent can run `pi` in a Coder terminal or through T3 Code after
the startup script completes.

## Template change

Add this block to the Coder template beside its existing module blocks:

```hcl
module "pi_coding_agent" {
  source = "./modules/pi-coding-agent"

  agent_id   = coder_agent.main.id
  pi_version = "1.0.0"
}
```

Copy `modules/pi-coding-agent` into the template repository if the template
does not already have this relative path. Use the actual Coder agent resource
name if it is not `coder_agent.main`.

Change `pi_version` to the desired published version and apply the template
change. On the next workspace start, the module compares `pi --version` with
the requested version, installs only if they differ, and verifies the result.
The same input can be used to roll back. An exact pin gives repeatable
starts, but upgrades require a template change. Set `pi_version = "latest"`
or omit it to check npm for a newer release on every start; that follows new
releases automatically, but the resulting version can vary between starts.

## Requirements and behavior

The Linux workspace image needs `curl`, `tar`, `sha256sum`, `awk`, and a POSIX
shell. If Node.js 22.19 or newer is unavailable when this module starts, it
downloads and verifies Node.js 24.13.0 from nodejs.org into the user's
persistent `$HOME/.local/share/pi-coding-agent` directory. This avoids relying
on another Coder startup script to install Node first. Installation and upgrades
need outbound HTTPS access to the npm registry; a missing Node runtime also
requires access to nodejs.org. The `latest` setting queries the registry on
every start. If Node is present but npm is missing from `PATH`, the script
downloads the npm CLI into the same persistent directory. It then uses the
[official npm installation command](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/quickstart.md)
with `--ignore-scripts` and a user-local prefix. It does not need root or an
image rebuild.

The module prepends its Node runtime directory and `$HOME/.local/bin` to the Coder agent `PATH`, so both
Coder terminals and the T3 server's agent environment can find `pi`. Pi's
authentication, settings, and sessions stay in its normal `$HOME/.pi/agent`
directory on persistent home storage. Authenticate interactively using Pi's
`/login` command or provide a provider API key through the workspace's normal
runtime environment. This module has no credential inputs.

If installation fails, the Coder startup script prints the failing command's
error and an explicit Pi installation message. The script blocks login until
`pi --version` reports the requested version.

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `agent_id` | Coder agent ID that installs Pi. | `string` | n/a | yes |
| `pi_version` | Exact Pi version, or `latest` for automatic updates at workspace start. | `string` | `latest` | no |

## Outputs

| Name | Description |
| --- | --- |
| `pi_path` | Path used for module-managed installations; an already matching Pi elsewhere on `PATH` is reused. |

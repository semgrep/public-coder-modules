# coder-modules

Reusable Terraform modules for [Coder](https://coder.com/) workspace templates.

## `pi-coding-agent`

[`modules/pi-coding-agent`](modules/pi-coding-agent) installs the Pi CLI at
workspace start. Set `pi_version` to an exact release for controlled upgrades,
or leave it at `latest` to update when a new npm release appears. It keeps Pi
state in the Coder user's persistent home and adds `pi` to the agent `PATH`.

```hcl
module "pi_coding_agent" {
  source = "./modules/pi-coding-agent"

  agent_id   = coder_agent.main.id
  pi_version = "1.0.0"
}
```

## `t3-server`

[`modules/t3-server`](modules/t3-server) installs and starts the T3 Code
headless server on a Coder agent. It creates an owner-only **T3 Code** app,
listening on loopback port `3773` by default.

```hcl
module "t3_server" {
  source = "./modules/t3-server"

  agent_id          = coder_agent.main.id
  working_directory = "/home/coder"
  initial_repositories = [
    {
      url       = "https://github.com/example/project.git"
      directory = "project"
    },
  ]
}
```

T3 is installed only when absent. Use `channel` (`stable` or `nightly`) to
choose the release train on every start. It switches an existing installation
only when the installed channel differs, including nightly back to stable;
an unchanged channel does not trigger an upgrade. `t3_version` takes precedence
on first install and disables later channel switching; it does not enforce an
exact version after installation. The module leaves T3 state in `$HOME/.t3`,
adds `$HOME/.local/bin` to the agent `PATH`, and records server logs at
`$HOME/.t3/logs/server.log`.

Repositories supplied through `initial_repositories` are cloned once into
`$HOME/git/<directory>` and registered as T3 projects before the server starts.
Each URL must be HTTPS and each directory must be a simple filename.

## `ecr-credential-helper`

[`modules/ecr-credential-helper`](modules/ecr-credential-helper) installs the
Amazon ECR Docker credential helper for a Coder user and configures named ECR
account/region registries without replacing other Docker credentials.

```hcl
module "ecr_credential_helper" {
  source   = "./modules/ecr-credential-helper"
  agent_id = coder_agent.main.id

  registries = [
    { account_id = "111122223333", region = "us-east-1" },
    { account_id = "444455556666", region = "us-west-2" },
  ]
}
```

The agent user needs AWS credentials with access to the configured ECR
repositories when it runs Docker.

## `git-credential-coder`

[`modules/git-credential-coder`](modules/git-credential-coder) configures a
host-scoped Git HTTPS credential helper that retrieves fresh credentials from
Coder external authentication. It avoids persisting access tokens and works
for Git commands that run outside an interactive shell.

```hcl
module "git_credential_coder" {
  source   = "./modules/git-credential-coder"
  agent_id = coder_agent.main.id
}
```

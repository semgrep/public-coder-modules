# coder-modules

Reusable Terraform modules for [Coder](https://coder.com/) workspace templates.

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
choose the first-install release train, or `t3_version` to pin an exact first
install. The module leaves T3 state in `$HOME/.t3`, adds `$HOME/.local/bin` to
the agent `PATH`, and records server logs at `$HOME/.t3/logs/server.log`.

Repositories supplied through `initial_repositories` are cloned once into
`$HOME/git/<directory>` and registered as T3 projects before the server starts.
Each URL must be HTTPS and each directory must be a simple filename.

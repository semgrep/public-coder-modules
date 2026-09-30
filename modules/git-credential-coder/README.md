---
display_name: "Coder Git Credential Helper"
description: "Configures Git HTTPS credentials using Coder external authentication."
icon: "/icon/git.svg"
tags: ["git", "github", "authentication"]
---

# Coder Git Credential Helper

Configures a host-scoped Git credential helper that obtains an access token
from `coder external-auth access-token`. It replaces the need for
`GIT_ASKPASS` for HTTPS Git operations while keeping the token out of Git
configuration and credential stores.

## Usage

```hcl
module "git_credential_coder" {
  source = "./modules/git-credential-coder"

  agent_id = coder_agent.main.id
}
```

The workspace template must declare a matching `coder_external_auth` data
source so Coder requires the user to link that account:

```hcl
data "coder_external_auth" "github" {
  id = "github"
}
```

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `agent_id` | Coder agent ID to configure. | `string` | n/a | yes |
| `host` | HTTPS Git hostname for which Coder supplies credentials. | `string` | `github.com` | no |
| `external_auth_id` | Coder external-auth provider ID. | `string` | `github` | no |
| `username` | HTTP Basic username returned with the token. | `string` | `x-access-token` | no |

## Outputs

| Name | Description |
| --- | --- |
| `credential_scope` | HTTPS scope configured to invoke the helper. |
| `helper_path` | User-scoped installed credential-helper path. |

## Operations

On every workspace start, the module writes an owner-only helper under
`~/.local/bin` and configures a host-scoped key such as
`credential.https://github.com.helper`. When Git needs credentials for that
HTTPS host, the helper fetches a fresh token directly from Coder and returns it
through Git's credential-helper protocol. Tokens are never persisted by this
module.

The workspace image needs `git`, the Coder CLI, `base64`, and a POSIX shell.

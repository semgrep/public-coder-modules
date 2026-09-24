---
display_name: "Amazon ECR Credential Helper"
description: "Installs Amazon's ECR Docker credential helper and configures selected private ECR registries."
icon: "https://raw.githubusercontent.com/awslabs/amazon-ecr-credential-helper/main/misc/amazon-ecr.png"
tags: ["aws", "docker", "ecr"]
---

# Amazon ECR Credential Helper

Installs the Amazon ECR Docker credential helper for the Coder user and
configures Docker to use it for the selected private ECR registries. This
avoids putting ECR passwords in `~/.docker/config.json`; Docker obtains a
short-lived token from AWS when it pulls or pushes an image.

## Usage

```hcl
module "ecr_credential_helper" {
  source = "./modules/ecr-credential-helper"

  agent_id = coder_agent.main.id
  registries = [
    { account_id = "111122223333", region = "us-east-1" },
    { account_id = "444455556666", region = "us-west-2" },
  ]
}
```

The module writes per-registry `credHelpers` entries, rather than setting a
global `credsStore`, so existing Docker Hub, GHCR, and other registry
credentials remain usable. Duplicate account/region entries are harmless.

## Prerequisites

The Linux Coder image needs `curl`, `python3`, `sha256sum`, `install`, and a
POSIX shell. On first start it needs outbound access to Amazon's ECR helper
release bucket. The module supports `amd64` and `arm64` agents and downloads a
pinned helper release, validating it against the corresponding published
SHA256 file.

The Coder user must already have AWS credentials available when Docker runs,
such as a workload IAM role, Coder-provided environment credentials, or the
standard AWS shared credentials/configuration files. Those credentials need
the ECR permissions for every configured account and repository. For
cross-account ECR, configure the relevant IAM and repository policies outside
this module.

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `agent_id` | Coder agent ID to configure. | `string` | n/a | yes |
| `registries` | ECR account/region pairs to configure. | `list(object({ account_id = string, region = string }))` | n/a | yes |
| `helper_version` | Pinned helper version, without `v`. | `string` | `0.12.0` | no |
| `registry_domain` | ECR DNS suffix. Use `amazonaws.com.cn` in China. | `string` | `amazonaws.com` | no |

## Outputs

| Name | Description |
| --- | --- |
| `registry_hosts` | ECR hosts configured to use `ecr-login`. |
| `helper_path` | User-scoped installed helper path. |

## Operations

The provisioning script is idempotent. It installs or upgrades the helper
only when `helper_version` changes, and it atomically merges the specified
hosts into `~/.docker/config.json`. If that Docker configuration is malformed
or has a non-object `credHelpers` value, the script exits without replacing it.

The setup applies to Docker commands run as the Coder user. Commands run with
`sudo docker` use root's Docker configuration instead; avoid `sudo` or
configure root separately if that is intentional.

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

locals {
  registry_hosts = distinct([
    for registry in var.registries :
    "${registry.account_id}.dkr.ecr.${registry.region}.${var.registry_domain}"
  ])
}

resource "coder_env" "ecr_helper_path" {
  agent_id       = var.agent_id
  name           = "PATH"
  value          = "$HOME/.local/bin:$PATH"
  merge_strategy = "prepend"
}

resource "coder_script" "ecr_credential_helper" {
  agent_id           = var.agent_id
  display_name       = "Configure Amazon ECR credentials"
  icon               = "https://raw.githubusercontent.com/awslabs/amazon-ecr-credential-helper/main/misc/amazon-ecr.png"
  run_on_start       = true
  start_blocks_login = true
  timeout            = 120

  # This runs as the Coder user so both the helper and Docker configuration
  # are available to terminals without requiring root or a system package
  # manager.
  script = <<-EOT
    #!/bin/sh
    set -eu

    helper_version="${var.helper_version}"
    registry_manifest="${base64encode(jsonencode(local.registry_hosts))}"
    install_dir="$HOME/.local/bin"
    state_dir="$HOME/.local/share/amazon-ecr-credential-helper"
    helper_bin="$install_dir/docker-credential-ecr-login"
    version_file="$state_dir/version"

    case "$(uname -m)" in
      x86_64|amd64) helper_arch="amd64" ;;
      aarch64|arm64) helper_arch="arm64" ;;
      *)
        echo "Unsupported architecture for Amazon ECR Credential Helper: $(uname -m)" >&2
        exit 1
        ;;
    esac

    mkdir -p "$install_dir" "$state_dir" "$HOME/.docker"
    chmod 700 "$HOME/.docker" "$state_dir"

    if [ ! -x "$helper_bin" ] || [ ! -f "$version_file" ] || [ "$(cat "$version_file")" != "$helper_version" ]; then
      download_file="$(mktemp "$state_dir/docker-credential-ecr-login.XXXXXX")"
      checksum_file="$(mktemp "$state_dir/docker-credential-ecr-login.sha256.XXXXXX")"
      trap 'rm -f "$download_file" "$checksum_file"' EXIT HUP INT TERM
      release_base="https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/$helper_version/linux-$helper_arch"

      curl --fail --silent --show-error --location --proto '=https' \
        "$release_base/docker-credential-ecr-login" -o "$download_file"
      curl --fail --silent --show-error --location --proto '=https' \
        "$release_base/docker-credential-ecr-login.sha256" -o "$checksum_file"

      expected_checksum="$(awk 'NR == 1 { print $1 }' "$checksum_file")"
      actual_checksum="$(sha256sum "$download_file" | awk '{ print $1 }')"
      case "$expected_checksum" in
        ????????*) ;;
        *)
          echo "The downloaded ECR helper checksum was invalid." >&2
          exit 1
          ;;
      esac
      if [ "$actual_checksum" != "$expected_checksum" ]; then
        echo "The downloaded ECR helper did not match its published SHA256 checksum." >&2
        exit 1
      fi

      install -m 0755 "$download_file" "$helper_bin"
      printf '%s\n' "$helper_version" > "$version_file"
      chmod 600 "$version_file"
      rm -f "$download_file" "$checksum_file"
      trap - EXIT HUP INT TERM
    fi

    # Merge only this module's registry entries. Existing auths, credential
    # helpers, proxies, and other Docker settings remain intact. Python is
    # deliberately used instead of rewriting JSON with shell substitutions.
    REGISTRY_MANIFEST="$registry_manifest" python3 - <<'PY'
    import base64
    import json
    import os
    import stat
    import tempfile

    config_path = os.path.expanduser("~/.docker/config.json")
    registry_hosts = json.loads(base64.b64decode(os.environ["REGISTRY_MANIFEST"]))

    try:
        with open(config_path, encoding="utf-8") as config_file:
            config = json.load(config_file)
    except FileNotFoundError:
        config = {}
    except json.JSONDecodeError as error:
        raise SystemExit(f"Docker config is not valid JSON: {config_path}: {error}")

    if not isinstance(config, dict):
        raise SystemExit(f"Docker config must be a JSON object: {config_path}")
    helpers = config.setdefault("credHelpers", {})
    if not isinstance(helpers, dict):
        raise SystemExit(f"Docker config credHelpers must be a JSON object: {config_path}")
    helpers.update({host: "ecr-login" for host in registry_hosts})

    directory = os.path.dirname(config_path)
    descriptor, temporary_path = tempfile.mkstemp(prefix="config.json.", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as config_file:
            json.dump(config, config_file, indent=2, sort_keys=True)
            config_file.write("\n")
        os.chmod(temporary_path, stat.S_IRUSR | stat.S_IWUSR)
        os.replace(temporary_path, config_path)
    except BaseException:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
        raise
    PY
  EOT
}

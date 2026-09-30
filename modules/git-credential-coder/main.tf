terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

locals {
  credential_scope = "https://${var.host}"
  helper_name      = "git-credential-coder-${replace(var.host, ".", "-")}"
  helper_path      = "$HOME/.local/bin/${local.helper_name}"
}

resource "coder_script" "git_credential_coder" {
  agent_id           = var.agent_id
  display_name       = "Configure Git credentials"
  icon               = "/icon/git.svg"
  run_on_start       = true
  start_blocks_login = true
  timeout            = 60

  # Git invokes this helper only for credential requests in credential_scope.
  # The Coder token stays in process memory: neither the helper nor Git's
  # configuration writes it to disk.
  script = <<-EOT
    #!/bin/sh
    set -eu

    install_dir="$HOME/.local/bin"
    helper_path="$install_dir/${local.helper_name}"
    credential_key="credential.${local.credential_scope}.helper"

    command -v git >/dev/null 2>&1 || {
      echo "git is not installed; cannot configure a Git credential helper" >&2
      exit 1
    }
    command -v coder >/dev/null 2>&1 || {
      echo "coder is not installed; cannot configure a Coder Git credential helper" >&2
      exit 1
    }

    umask 077
    mkdir -p "$install_dir"
    cat > "$helper_path" <<'HELPER'
    #!/bin/sh
    set -eu

    # Git passes the operation as $1 and the request fields on stdin. This
    # helper supplies credentials only; Git handles erase and store locally.
    [ "$1" = get ] || exit 0
    while IFS= read -r line && [ -n "$line" ]; do :; done

    token="$(coder external-auth access-token ${var.external_auth_id})"
    [ -n "$token" ] || {
      echo "Coder returned an empty external-auth token for ${var.external_auth_id}" >&2
      exit 1
    }

    username="$(printf '%s' '${base64encode(var.username)}' | base64 -d)"
    printf 'username=%s\npassword=%s\n\n' "$username" "$token"
    HELPER
    chmod 0700 "$helper_path"

    # --replace-all makes repeated workspace starts idempotent and ensures
    # this host uses Coder rather than relying on GIT_ASKPASS.
    git config --global --replace-all "$credential_key" "!$helper_path"
  EOT
}

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

resource "coder_env" "pi_path" {
  agent_id       = var.agent_id
  name           = "PATH"
  value          = "$HOME/.local/bin:$PATH"
  merge_strategy = "prepend"
}

resource "coder_script" "pi" {
  agent_id           = var.agent_id
  display_name       = "Install Pi coding agent"
  icon               = "/icon/code.svg"
  run_on_start       = true
  start_blocks_login = true
  timeout            = 300

  script = <<-EOT
    #!/bin/sh
    set -eu

    export PATH="$HOME/.local/bin:$PATH"
    install_dir="$HOME/.local/bin"
    state_dir="$HOME/.local/share/pi-coding-agent"
    npm_dir="$state_dir/npm"
    package='@earendil-works/pi-coding-agent'
    selector='${var.pi_version}'

    fail() {
      echo "Pi installation: $1" >&2
      exit 1
    }

    command -v node >/dev/null 2>&1 || fail 'Node.js 22.19 or newer is required.'
    node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 22 || (major === 22 && minor >= 19) ? 0 : 1)' \
      || fail "Node.js 22.19 or newer is required (found $(node --version))."

    umask 077
    mkdir -p "$install_dir" "$state_dir"
    chmod 700 "$state_dir"

    # Some Coder images expose node without npm. Bootstrap npm from its
    # official registry into the persistent user home only when needed.
    npm_cli=''
    npm_bin=''
    find_npm() {
      if command -v npm >/dev/null 2>&1; then
        npm_bin="$(command -v npm)"
      elif [ -f "$npm_dir/package/bin/npm-cli.js" ]; then
        npm_cli="$npm_dir/package/bin/npm-cli.js"
      else
        command -v curl >/dev/null 2>&1 || fail 'curl is required to bootstrap npm.'
        command -v tar >/dev/null 2>&1 || fail 'tar is required to bootstrap npm.'
        bootstrap_dir="$(mktemp -d "$state_dir/npm.XXXXXX")"
        trap 'rm -rf "$bootstrap_dir"' EXIT HUP INT TERM
        # npm 10 supports the same Node versions required by Pi. Pinning the
        # bootstrap CLI avoids a future npm major raising its Node minimum.
        npm_release='10.9.3'
        curl -fsSL --proto '=https' "https://registry.npmjs.org/npm/-/npm-$npm_release.tgz" -o "$bootstrap_dir/npm.tgz" \
          || fail "Could not download npm $npm_release."
        tar -xzf "$bootstrap_dir/npm.tgz" -C "$bootstrap_dir" \
          || fail "Could not extract npm $npm_release."
        [ -f "$bootstrap_dir/package/bin/npm-cli.js" ] \
          || fail "npm $npm_release archive did not contain its CLI."
        rm -rf "$npm_dir"
        mv "$bootstrap_dir" "$npm_dir" \
          || fail 'Could not save the user-local npm CLI.'
        trap - EXIT HUP INT TERM
        npm_cli="$npm_dir/package/bin/npm-cli.js"
      fi
    }

    run_npm() {
      if [ -n "$npm_cli" ]; then
        node "$npm_cli" "$@"
      else
        "$npm_bin" "$@"
      fi
    }

    if [ "$selector" = latest ]; then
      find_npm
      desired_version="$(run_npm view "$package@latest" version --silent)" \
        || fail 'Could not resolve the latest Pi version from npm.'
      [ -n "$desired_version" ] || fail 'npm returned an empty latest Pi version.'
    else
      desired_version="$selector"
    fi

    installed_version=''
    if command -v pi >/dev/null 2>&1; then
      installed_version="$(pi --version 2>/dev/null || true)"
    fi

    if [ "$installed_version" != "$desired_version" ]; then
      [ -n "$npm_bin" ] || [ -n "$npm_cli" ] || find_npm
      echo "Installing Pi $desired_version (installed: $${installed_version:-none})"
      run_npm install --global --prefix "$HOME/.local" --ignore-scripts --no-audit --no-fund "$package@$desired_version" \
        || fail "npm could not install $package@$desired_version."
    fi

    command -v pi >/dev/null 2>&1 || fail 'Pi installation finished without a pi executable on PATH.'
    actual_version="$(pi --version)" || fail 'pi --version failed after installation.'
    [ "$actual_version" = "$desired_version" ] \
      || fail "Expected Pi $desired_version, but pi --version reported $actual_version."
    echo "Pi $actual_version is ready."
  EOT
}

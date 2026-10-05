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
  value          = "$HOME/.local/share/pi-coding-agent/node/current/bin:$HOME/.local/bin:$PATH"
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

    install_dir="$HOME/.local/bin"
    state_dir="$HOME/.local/share/pi-coding-agent"
    node_install_root="$state_dir/node"
    node_bin_dir="$node_install_root/current/bin"
    npm_dir="$state_dir/npm"
    package='@earendil-works/pi-coding-agent'
    selector='${var.pi_version}'
    export PATH="$node_bin_dir:$install_dir:$PATH"

    fail() {
      echo "Pi installation: $1" >&2
      exit 1
    }

    umask 077
    mkdir -p "$install_dir" "$state_dir"
    chmod 700 "$state_dir"

    node_is_supported() {
      command -v node >/dev/null 2>&1 &&
        node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 22 || (major === 22 && minor >= 19) ? 0 : 1)' >/dev/null 2>&1
    }

    # Coder startup scripts run independently. A different module may install
    # Node later, so Pi must be able to provide its own runtime when needed.
    if ! node_is_supported; then
      command -v curl >/dev/null 2>&1 || fail 'curl is required to install Node.js.'
      command -v tar >/dev/null 2>&1 || fail 'tar is required to install Node.js.'
      command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required to verify Node.js.'
      command -v awk >/dev/null 2>&1 || fail 'awk is required to verify Node.js.'
      [ "$(uname -s)" = Linux ] || fail 'Automatic Node.js installation supports Linux only.'
      case "$(uname -m)" in
        x86_64) node_arch=x64 ;;
        aarch64|arm64) node_arch=arm64 ;;
        *) fail "Unsupported Node.js architecture: $(uname -m)." ;;
      esac
      node_release='24.13.0'
      node_archive="node-v$node_release-linux-$node_arch.tar.gz"
      node_url="https://nodejs.org/dist/v$node_release"
      node_stage="$(mktemp -d "$state_dir/node.XXXXXX")"
      trap 'rm -rf "$node_stage"' EXIT HUP INT TERM
      curl -fsSL --proto '=https' "$node_url/$node_archive" -o "$node_stage/$node_archive" \
        || fail "Could not download Node.js $node_release."
      curl -fsSL --proto '=https' "$node_url/SHASUMS256.txt" -o "$node_stage/SHASUMS256.txt" \
        || fail "Could not download Node.js $node_release checksums."
      node_sha="$(awk -v name="$node_archive" '$2 == name { print $1; exit }' "$node_stage/SHASUMS256.txt")"
      [ -n "$node_sha" ] || fail "No checksum found for $node_archive."
      printf '%s  %s\n' "$node_sha" "$node_stage/$node_archive" | sha256sum -c - >/dev/null \
        || fail "Checksum verification failed for $node_archive."
      mkdir -p "$node_stage/unpacked" "$node_install_root"
      tar -xzf "$node_stage/$node_archive" -C "$node_stage/unpacked" --strip-components=1 \
        || fail "Could not extract $node_archive."
      [ -x "$node_stage/unpacked/bin/node" ] || fail 'Node.js archive did not contain a node executable.'
      rm -rf "$node_install_root/current"
      mv "$node_stage/unpacked" "$node_install_root/current" \
        || fail 'Could not save the user-local Node.js runtime.'
      rm -rf "$node_stage"
      trap - EXIT HUP INT TERM
    fi
    node_is_supported || fail 'Node.js 22.19 or newer is required.'

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

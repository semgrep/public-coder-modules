terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

resource "coder_env" "t3_path" {
  agent_id       = var.agent_id
  name           = "PATH"
  value          = "$HOME/.local/bin:$PATH"
  merge_strategy = "prepend"
}

resource "coder_script" "t3_server" {
  agent_id           = var.agent_id
  display_name       = "Start T3 Code"
  icon               = "https://raw.githubusercontent.com/pingdotgg/t3code/main/assets/prod/t3-black-web-favicon-32x32.png"
  run_on_start       = true
  start_blocks_login = true
  timeout            = 300

  # Install and start together: Terraform resource ordering does not order the
  # runtime execution of separate Coder scripts.
  script = <<-EOT
    #!/bin/sh
    set -eu

    export PATH="$HOME/.local/bin:$PATH"
    t3_home="$HOME/.t3"
    log_dir="$t3_home/logs"
    log_file="$log_dir/server.log"
    pid_file="$t3_home/server.pid"
    port="${var.port}"
    working_directory="${var.working_directory}"
    repository_manifest="${base64encode(join("\n", [for repository in var.initial_repositories : "${repository.url}\t${repository.directory}"]))}"
    selected_channel="${var.channel}"
    exact_version="${var.t3_version == null ? "" : var.t3_version}"

    mkdir -p "$log_dir"
    chmod 700 "$t3_home" "$log_dir"
    : >> "$log_file"
    chmod 600 "$log_file"

    # T3 serves its web UI at /. There is no documented dedicated health
    # endpoint, so a successful, local HTTP response is the least fragile
    # readiness check and avoids logging any pairing information.
    is_healthy() {
      curl -fsS --max-time 2 "http://127.0.0.1:$port/" >/dev/null 2>&1
    }

    first_install=false
    if ! command -v t3 >/dev/null 2>&1; then
      first_install=true
      # The official installer writes the executable symlink to
      # $HOME/.local/bin and the runtime/data under $HOME/.t3. It only runs
      # when absent, so restarts do not upgrade T3 implicitly.
      ${var.t3_version == null ? "curl -fsSL https://t3.codes/install.sh | T3CODE_CHANNEL=${var.channel} sh" : "curl -fsSL https://t3.codes/install.sh | T3CODE_VERSION=${var.t3_version} sh"}
    fi

    t3_bin="$(command -v t3)"
    t3_shim="$HOME/.local/bin/t3"
    t3_real_bin_file="$t3_home/t3-real-bin"
    public_domain_file="$t3_home/pair-public-domain"

    # T3 records its loopback listening address in the running server state,
    # so `t3 pair` would otherwise create a link that is unusable outside the
    # workspace. Install a small PATH-precedence shim which only changes the
    # displayed pairing URL. The real executable is retained separately so
    # all other T3 commands are delegated unchanged.
    if [ -f "$t3_real_bin_file" ]; then
      t3_real_bin="$(cat "$t3_real_bin_file")"
    elif [ "$t3_bin" = "$t3_shim" ]; then
      t3_real_bin="$HOME/.local/bin/t3-real"
      mv "$t3_shim" "$t3_real_bin"
      printf '%s\n' "$t3_real_bin" > "$t3_real_bin_file"
    else
      t3_real_bin="$(readlink -f "$t3_bin")"
      printf '%s\n' "$t3_real_bin" > "$t3_real_bin_file"
    fi
    chmod 600 "$t3_real_bin_file"

    printf '%s\n' "${var.public_domain}" > "$public_domain_file"
    chmod 600 "$public_domain_file"

    # The updater replaces ~/.local/bin/t3 with its own symlink. Restore the
    # pairing shim after a channel change, using the newly installed target.
    install_pairing_shim() {
      rm -f "$t3_shim"
      cat > "$t3_shim" <<'EOF'
    #!/bin/sh
    set -eu

    t3_home="$HOME/.t3"
    t3_real_bin="$(cat "$t3_home/t3-real-bin")"
    public_domain="$(cat "$t3_home/pair-public-domain")"

    if [ "$${1:-}" != "pair" ] || [ -z "$public_domain" ]; then
      exec "$t3_real_bin" "$@"
    fi

    pair_output="$(mktemp)"
    trap 'rm -f "$pair_output"' EXIT HUP INT TERM
    if "$t3_real_bin" "$@" > "$pair_output"; then
      pair_status=0
    else
      pair_status=$?
    fi
    sed "s|http://127.0.0.1:[0-9][0-9]*|https://$public_domain|g" "$pair_output"
    exit "$pair_status"
    EOF
      chmod 755 "$t3_shim"
    }
    install_pairing_shim
    t3_bin="$t3_real_bin"

    version_channel() {
      case "$1" in
        't3 v'[0-9]*.[0-9]*.[0-9]*-nightly.*) printf '%s\n' nightly ;;
        't3 v'[0-9]*.[0-9]*.[0-9]*)
          case "$1" in *-*) return 1 ;; *) printf '%s\n' stable ;; esac
          ;;
        *) return 1 ;;
      esac
    }

    channel_switch_needed=false
    if [ "$first_install" = false ] && [ -z "$exact_version" ]; then
      installed_version="$("$t3_bin" --version)"
      if ! installed_channel="$(version_channel "$installed_version")"; then
        echo "Cannot identify installed T3 channel from: $installed_version" >&2
        exit 1
      fi
      if [ "$installed_channel" != "$selected_channel" ]; then
        channel_switch_needed=true
      fi
    fi

    # The template's GitHub external-auth setup supplies HTTPS credentials to
    # git via GIT_ASKPASS. Clone selected repositories once under ~/git, then
    # register them before T3 serves its first request. The persistent marker
    # prevents duplicate `t3 project add` calls on later workspace starts.
    if [ -n "$repository_manifest" ]; then
      repositories_file="$t3_home/initial-repositories.tsv"
      projects_dir="$t3_home/initial-projects"
      mkdir -p "$HOME/git" "$projects_dir"
      chmod 700 "$projects_dir"
      printf '%s' "$repository_manifest" | base64 -d > "$repositories_file"
      chmod 600 "$repositories_file"

      repository_url=""
      # Terraform's join intentionally does not add a final newline; retain
      # the last repository record when reading that manifest.
      while IFS="$(printf '\t')" read -r repository_url repository_directory || [ -n "$repository_url" ]; do
        [ -n "$repository_url" ] || continue
        repository_path="$HOME/git/$repository_directory"
        project_marker="$projects_dir/$repository_directory"

        if [ -d "$repository_path/.git" ]; then
          :
        elif [ -e "$repository_path" ]; then
          echo "Initial repository path exists but is not a Git checkout: $repository_path" >&2
          exit 1
        else
          git clone --quiet "$repository_url" "$repository_path"
        fi

        if [ ! -f "$project_marker" ]; then
          if "$t3_bin" project add "$repository_path" >>"$log_file" 2>&1; then
            : > "$project_marker"
            chmod 600 "$project_marker"
          else
            echo "Could not add T3 project $repository_path; inspect $log_file" >&2
            exit 1
          fi
        fi
      done < "$repositories_file"
      rm -f "$repositories_file"
    fi

    if ! command -v rc-service >/dev/null 2>&1 || ! command -v openrc-run >/dev/null 2>&1 || ! command -v supervise-daemon >/dev/null 2>&1; then
      echo "OpenRC user services require rc-service, openrc-run, and supervise-daemon" >&2
      exit 1
    fi
    if [ -z "$${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ] || [ ! -w "$XDG_RUNTIME_DIR" ]; then
      echo "OpenRC user services require a writable XDG_RUNTIME_DIR" >&2
      exit 1
    fi

    service_dir="$${XDG_CONFIG_HOME:-$HOME/.config}/rc/init.d"
    service_config="$t3_home/service-config"
    service_restart_needed=false
    if [ ! -f "$service_config" ] || [ "$(cat "$service_config")" != "$port|$working_directory" ]; then
      service_restart_needed=true
    fi
    printf '%s\n' "$port|$working_directory" > "$service_config"
    printf '%s\n' "$port" > "$t3_home/server-port"
    printf '%s\n' "$working_directory" > "$t3_home/server-working-directory"
    chmod 600 "$service_config" "$t3_home/server-port" "$t3_home/server-working-directory"
    mkdir -p "$service_dir"

    # OpenRC supervises the foreground server. The wrapper reads the current
    # binary and settings on each spawn, including after a channel switch.
    cat > "$t3_home/serve-openrc" <<'EOF'
    #!/bin/sh
    set -eu
    t3_home="$HOME/.t3"
    t3_bin="$(cat "$t3_home/t3-real-bin")"
    port="$(cat "$t3_home/server-port")"
    working_directory="$(cat "$t3_home/server-working-directory")"
    cd "$working_directory"
    exec "$t3_bin" serve --host 127.0.0.1 --port "$port" "$working_directory" \
      >/dev/null 2>>"$t3_home/logs/server.log" < /dev/null
    EOF
    chmod 700 "$t3_home/serve-openrc"

    cat > "$service_dir/t3-code" <<'EOF'
    #!/usr/bin/env openrc-run
    description="T3 Code headless server"
    supervisor=supervise-daemon
    command="$HOME/.t3/serve-openrc"
    pidfile="$XDG_RUNTIME_DIR/t3-code.pid"
    respawn_delay=1
    respawn_max=10
    respawn_period=60
    EOF
    chmod 700 "$service_dir/t3-code"

    service_running=false
    if rc-service --user t3-code status >/dev/null 2>&1; then
      service_running=true
    fi

    # One-time handoff from the older PID-managed module. Never kill a PID
    # without checking that it still belongs to a T3 serve process.
    if [ -f "$pid_file" ]; then
      if [ "$service_running" = false ]; then
        old_pid="$(cat "$pid_file" 2>/dev/null || true)"
        case "$old_pid" in
          ''|*[!0-9]*) old_pid="" ;;
          *)
            command_line="$(ps -p "$old_pid" -o args= 2>/dev/null || true)"
            case "$command_line" in *t3*serve*) ;; *) old_pid="" ;; esac
            ;;
        esac
        if [ -n "$old_pid" ]; then
          kill "$old_pid"
          attempt=0
          while kill -0 "$old_pid" 2>/dev/null && [ "$attempt" -lt 30 ]; do
            process_state="$(ps -p "$old_pid" -o stat= 2>/dev/null || true)"
            case "$process_state" in Z*) break ;; esac
            attempt=$((attempt + 1))
            sleep 1
          done
          process_state="$(ps -p "$old_pid" -o stat= 2>/dev/null || true)"
          if kill -0 "$old_pid" 2>/dev/null && [ -n "$process_state" ] && [ "$${process_state#Z}" = "$process_state" ]; then
            echo "Legacy T3 server did not stop; inspect $log_file" >&2
            exit 1
          fi
        fi
      fi
      rm -f "$pid_file"
    fi

    if [ "$service_running" = true ] && { [ "$channel_switch_needed" = true ] || [ "$service_restart_needed" = true ]; }; then
      rc-service --user t3-code stop
      service_running=false
    fi
    if [ "$service_running" = false ] && is_healthy; then
      echo "A server is responding on port $port outside the OpenRC service" >&2
      exit 1
    fi

    if [ "$channel_switch_needed" = true ]; then
      "$t3_bin" update --channel "$selected_channel" --allow-downgrade --yes
      if [ ! -L "$t3_shim" ]; then
        echo "T3 update did not replace its launcher; cannot verify the selected channel" >&2
        exit 1
      fi
      t3_bin="$(readlink -f "$t3_shim")"
      updated_version="$("$t3_bin" --version)"
      if ! updated_channel="$(version_channel "$updated_version")" || [ "$updated_channel" != "$selected_channel" ]; then
        echo "T3 update did not select $selected_channel (got $updated_version)" >&2
        exit 1
      fi
      printf '%s\n' "$t3_bin" > "$t3_real_bin_file"
      install_pairing_shim
    fi

    if [ "$service_running" = false ]; then
      rc-service --user t3-code start
    fi
    attempt=0
    while [ "$attempt" -lt 30 ]; do
      if rc-service --user t3-code status >/dev/null 2>&1 && is_healthy; then
        exit 0
      fi
      attempt=$((attempt + 1))
      sleep 1
    done
    echo "T3 Code OpenRC service did not become ready; inspect $log_file" >&2
    exit 1
  EOT
}

resource "coder_app" "t3" {
  agent_id     = var.agent_id
  slug         = "t3"
  display_name = "T3 Code"
  icon         = "https://raw.githubusercontent.com/pingdotgg/t3code/main/assets/prod/t3-black-web-favicon-32x32.png"
  url          = "http://127.0.0.1:${var.port}"
  share        = var.share
  subdomain    = true

  # T3 has no documented health endpoint; its static web UI responds at /.
  healthcheck {
    url       = "http://127.0.0.1:${var.port}/"
    interval  = 5
    threshold = 12
  }
}

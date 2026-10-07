terraform {
  required_version = ">= 1.3"

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

  lifecycle {
    precondition {
      condition     = var.log_rotation == null || var.server_backend == "openrc"
      error_message = "log_rotation requires server_backend = openrc."
    }
  }

  # Install and start together: Terraform resource ordering does not order the
  # runtime execution of separate Coder scripts.
  script = <<-EOT
    #!/bin/sh
    set -eu

    export PATH="$HOME/.local/bin:$PATH"
    t3_home="$HOME/.t3"
    log_dir="${var.log_directory == null ? "$HOME/.t3/logs" : var.log_directory}"
    log_rotation="${var.log_rotation == null ? "false" : "true"}"
    log_file="$log_dir/${var.log_rotation == null ? "server.log" : "current"}"
    rotation_size="${var.log_rotation == null ? 10485760 : var.log_rotation.max_size_bytes}"
    rotation_interval="${var.log_rotation == null ? 86400 : var.log_rotation.interval_seconds}"
    rotation_retention="${var.log_rotation == null ? 7 : var.log_rotation.retained_files}"
    pid_file="$t3_home/server.pid"
    server_backend="${var.server_backend}"
    backend_file="$t3_home/server-backend"
    port="${var.port}"
    working_directory="${var.working_directory}"
    repository_manifest="${base64encode(join("\n", [for repository in var.initial_repositories : "${repository.url}\t${repository.directory}"]))}"
    selected_channel="${var.channel}"
    exact_version="${var.t3_version == null ? "" : var.t3_version}"

    mkdir -p "$t3_home" "$log_dir"
    chmod 700 "$t3_home" "$log_dir"
    touch "$log_file"
    chmod 600 "$log_file"

    ${file("${path.module}/openrc.sh")}

    previous_backend="$(cat "$backend_file" 2>/dev/null || true)"
    if [ "$server_backend" = openrc ] || [ "$previous_backend" = openrc ]; then
      setup_openrc
    fi

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

    existing_t3_pid=""
    if [ -f "$pid_file" ]; then
      pid="$(cat "$pid_file" 2>/dev/null || true)"
      case "$pid" in
        ''|*[!0-9]*) rm -f "$pid_file" ;;
        *)
          # A PID can be reused. Only retain it when it is still a T3 server;
          # never terminate a process based on a PID file alone.
          command_line="$(ps -p "$pid" -o args= 2>/dev/null || true)"
          case "$command_line" in
            *t3*serve*) existing_t3_pid="$pid" ;;
            *) rm -f "$pid_file" ;;
          esac
          ;;
      esac
    fi

    stop_legacy_server() {
      if [ -n "$existing_t3_pid" ]; then
        kill "$existing_t3_pid"
        attempt=0
        while kill -0 "$existing_t3_pid" 2>/dev/null && [ "$attempt" -lt 30 ]; do
          process_state="$(ps -p "$existing_t3_pid" -o stat= 2>/dev/null || true)"
          case "$process_state" in Z*) break ;; esac
          attempt=$((attempt + 1))
          sleep 1
        done
        process_state="$(ps -p "$existing_t3_pid" -o stat= 2>/dev/null || true)"
        if kill -0 "$existing_t3_pid" 2>/dev/null && [ -n "$process_state" ] && [ "$${process_state#Z}" = "$process_state" ]; then
          echo "Existing T3 Code server did not stop; inspect $log_file" >&2
          exit 1
        fi
        rm -f "$pid_file"
        existing_t3_pid=""
      fi
    }

    # Transfer ownership before readiness can short-circuit startup. Never
    # leave a supervisor able to respawn a server owned by the other backend.
    if [ "$server_backend" = nohup ]; then
      stop_openrc
    elif [ -n "$existing_t3_pid" ]; then
      stop_legacy_server
    fi
    if [ "$server_backend" = openrc ] && [ "$openrc_config_changed" = true ]; then
      stop_openrc
      printf '%s\n' "$openrc_configuration" > "$openrc_config_dir/config-checksum"
      chmod 600 "$openrc_config_dir/config-checksum"
    fi

    if [ "$channel_switch_needed" = false ] && is_healthy; then
      if [ "$server_backend" = nohup ] || openrc_service t3-server status >/dev/null 2>&1; then
        printf '%s\n' "$server_backend" > "$backend_file"
        chmod 600 "$backend_file"
        exit 0
      fi
      echo "A server is listening on port $port outside the OpenRC service; stop it before selecting OpenRC" >&2
      exit 1
    fi

    if [ "$channel_switch_needed" = true ]; then
      stop_openrc
      stop_legacy_server
      if is_healthy; then
        echo "T3 Code is still responding on port $port after stopping its PID; cannot switch channel safely" >&2
        exit 1
      fi

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
    elif [ -n "$existing_t3_pid" ]; then
      attempt=0
      while [ "$attempt" -lt 30 ]; do
        if is_healthy; then
          exit 0
        fi
        if ! kill -0 "$existing_t3_pid" 2>/dev/null; then
          rm -f "$pid_file"
          break
        fi
        attempt=$((attempt + 1))
        sleep 1
      done
      if [ -f "$pid_file" ] && kill -0 "$existing_t3_pid" 2>/dev/null; then
        echo "Existing T3 Code server did not become ready; inspect $log_file" >&2
        exit 1
      fi
    fi

    cd "$working_directory"

    # `serve` prints pairing details to stdout. Both backends discard stdout
    # and retain only private stderr; pairing remains an interactive action.
    printf '%s\n' "$server_backend" > "$backend_file"
    chmod 600 "$backend_file"
    if [ "$server_backend" = openrc ]; then
      if ! openrc_service t3-server status >/dev/null 2>&1; then
        stop_openrc
        openrc_service t3-server start
      fi
    else
      nohup "$t3_bin" serve --host 127.0.0.1 --port "$port" "$working_directory" \
        >/dev/null 2>>"$log_file" < /dev/null &
      t3_pid=$!
      printf '%s\n' "$t3_pid" > "$pid_file"
      chmod 600 "$pid_file"
    fi

    attempt=0
    while [ "$attempt" -lt 30 ]; do
      if is_healthy; then
        exit 0
      fi
      if [ "$server_backend" = openrc ]; then
        if ! openrc_service t3-server status >/dev/null 2>&1; then
          echo "T3 Code OpenRC service exited during startup; inspect $log_file" >&2
          exit 1
        fi
      elif ! kill -0 "$t3_pid" 2>/dev/null; then
        rm -f "$pid_file"
        echo "T3 Code exited during startup; inspect $log_file" >&2
        exit 1
      fi
      attempt=$((attempt + 1))
      sleep 1
    done

    echo "T3 Code did not become ready; inspect $log_file" >&2
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

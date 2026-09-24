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
  timeout            = 120

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

    mkdir -p "$log_dir"
    chmod 700 "$t3_home" "$log_dir"

    # T3 serves its web UI at /. There is no documented dedicated health
    # endpoint, so a successful, local HTTP response is the least fragile
    # readiness check and avoids logging any pairing information.
    is_healthy() {
      curl -fsS --max-time 2 "http://127.0.0.1:$port/" >/dev/null 2>&1
    }

    if ! command -v t3 >/dev/null 2>&1; then
      # The official installer writes the executable symlink to
      # $HOME/.local/bin and the runtime/data under $HOME/.t3. It only runs
      # when absent, so restarts do not upgrade T3 implicitly.
      ${var.t3_version == null ? "curl -fsSL https://t3.codes/install.sh | T3CODE_CHANNEL=${var.channel} sh" : "curl -fsSL https://t3.codes/install.sh | T3CODE_VERSION=${var.t3_version} sh"}
    fi

    t3_bin="$(command -v t3)"

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

    if is_healthy; then
      exit 0
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

    # A just-started server can still be becoming ready. Do not create a
    # second instance when the PID file belongs to a live T3 server; wait for
    # it instead. An unresponsive live process is left untouched rather than
    # risking an unrelated PID or a user's in-flight work.
    if [ -n "$existing_t3_pid" ]; then
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

    # nohup detaches the process from Coder's startup-script session; no
    # systemd service is required in this Kubernetes container.
    # `serve` writes headless pairing details to stdout. Keep stdout out of
    # provisioning and persistent logs; users create pairing links themselves
    # with `t3 pair` in an interactive shell.
    nohup "$t3_bin" serve --host 127.0.0.1 --port "$port" "$working_directory" \
      >/dev/null 2>>"$log_file" < /dev/null &
    t3_pid=$!
    printf '%s\n' "$t3_pid" > "$pid_file"
    chmod 600 "$pid_file" "$log_file"

    attempt=0
    while [ "$attempt" -lt 30 ]; do
      if is_healthy; then
        exit 0
      fi
      if ! kill -0 "$t3_pid" 2>/dev/null; then
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
  share        = "owner"
  subdomain    = true

  # T3 has no documented health endpoint; its static web UI responds at /.
  healthcheck {
    url       = "http://127.0.0.1:${var.port}/"
    interval  = 5
    threshold = 12
  }
}

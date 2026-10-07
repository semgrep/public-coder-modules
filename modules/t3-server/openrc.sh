# Sourced into the Coder startup script. Keep OpenRC's configuration separate
# from the user's other services, and its process state out of persistent home.
openrc_config_dir="$t3_home/openrc-config"
openrc_runtime_dir="/tmp/t3-openrc-$(id -u)"
openrc_available=false
openrc_config_changed=false

openrc_command() {
  XDG_CONFIG_HOME="$openrc_config_dir" XDG_RUNTIME_DIR="$openrc_runtime_dir" "$@"
}

openrc_service() {
  openrc_command rc-service --user "$@"
}

setup_openrc() {
  for tool in openrc rc-service openrc-run supervise-daemon cksum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "The OpenRC backend requires $tool with user-service support installed in the agent image" >&2
      exit 1
    fi
  done

  # Do not follow a pre-existing symlink or use another user's runtime state.
  if ! (umask 077; mkdir "$openrc_runtime_dir") 2>/dev/null; then
    if [ -L "$openrc_runtime_dir" ] || [ ! -d "$openrc_runtime_dir" ] || [ ! -O "$openrc_runtime_dir" ]; then
      echo "Unsafe OpenRC runtime directory: $openrc_runtime_dir" >&2
      exit 1
    fi
  fi
  chmod 700 "$openrc_runtime_dir"
  mkdir -p "$openrc_config_dir/rc/init.d" "$openrc_config_dir/rc/runlevels/default"
  chmod 700 "$openrc_config_dir" "$openrc_config_dir/rc" "$openrc_config_dir/rc/init.d" "$openrc_config_dir/rc/runlevels" "$openrc_config_dir/rc/runlevels/default"

  # Preserve the startup environment in memory, including Coder/Git/provider
  # credentials, by allowing its variable NAMES. Never serialize their values.
  # RC_* is reserved for OpenRC's own service state.
  environment_names="$(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | sed '/^RC_/d' | sort -u | tr '\n' ' ')"
  printf 'rc_env_allow="%s"\n' "$environment_names" > "$openrc_config_dir/rc/rc.conf"
  chmod 600 "$openrc_config_dir/rc/rc.conf"

  # OpenRC needs private XDG paths; restore the agent's original paths only in
  # the child so providers still find their usual configuration and sockets.
  printf '%s\n' "${XDG_CONFIG_HOME:-}" > "$openrc_config_dir/agent-config-home"
  printf '%s\n' "${XDG_RUNTIME_DIR:-}" > "$openrc_config_dir/agent-runtime-dir"
  printf '%s\n' "$port" > "$openrc_config_dir/port"
  printf '%s\n' "$working_directory" > "$openrc_config_dir/working-directory"
  printf '%s\n' "$log_dir" > "$openrc_config_dir/log-directory"
  printf '%s\n' "$log_file" > "$openrc_config_dir/log-file"
  printf '%s\n' "$log_rotation:$rotation_size:$rotation_interval:$rotation_retention" > "$openrc_config_dir/rotation-settings"
  chmod 600 "$openrc_config_dir/agent-config-home" "$openrc_config_dir/agent-runtime-dir" "$openrc_config_dir/port" "$openrc_config_dir/working-directory" "$openrc_config_dir/log-directory" "$openrc_config_dir/log-file" "$openrc_config_dir/rotation-settings"

  if [ "$log_rotation" = true ]; then
    if ! command -v svlogd >/dev/null 2>&1; then
      echo "OpenRC log_rotation requires svlogd installed in the agent image" >&2
      exit 1
    fi
    printf 's%s\nt%s\nn%s\n' "$rotation_size" "$rotation_interval" "$rotation_retention" > "$log_dir/config"
    chmod 600 "$log_dir/config"
    printf '%s\n' "$(command -v svlogd)" > "$openrc_config_dir/svlogd-bin"
    chmod 600 "$openrc_config_dir/svlogd-bin"
    cat > "$openrc_config_dir/logger" <<'OPENRC_LOGGER'
#!/bin/sh
set -eu
config_dir="$HOME/.t3/openrc-config"
exec "$(cat "$config_dir/svlogd-bin")" -tt "$(cat "$config_dir/log-directory")"
OPENRC_LOGGER
    chmod 700 "$openrc_config_dir/logger"
  fi

  cat > "$openrc_config_dir/serve" <<'OPENRC_LAUNCHER'
#!/bin/sh
set -eu
config_dir="$HOME/.t3/openrc-config"
XDG_CONFIG_HOME="$(cat "$config_dir/agent-config-home")"
XDG_RUNTIME_DIR="$(cat "$config_dir/agent-runtime-dir")"
if [ -n "$XDG_CONFIG_HOME" ]; then export XDG_CONFIG_HOME; else unset XDG_CONFIG_HOME; fi
if [ -n "$XDG_RUNTIME_DIR" ]; then export XDG_RUNTIME_DIR; else unset XDG_RUNTIME_DIR; fi
t3_bin="$(cat "$HOME/.t3/t3-real-bin")"
port="$(cat "$config_dir/port")"
working_directory="$(cat "$config_dir/working-directory")"
cd "$working_directory"
exec "$t3_bin" serve --host 127.0.0.1 --port "$port" "$working_directory"
OPENRC_LAUNCHER
  chmod 700 "$openrc_config_dir/serve"

  printf '#!%s\n' "$(command -v openrc-run)" > "$openrc_config_dir/rc/init.d/t3-server"
  cat >> "$openrc_config_dir/rc/init.d/t3-server" <<'OPENRC_SERVICE'
description="T3 Code headless server"
supervisor=supervise-daemon
command="\"$HOME/.t3/openrc-config/serve\""
pidfile="$XDG_RUNTIME_DIR/t3-server-supervisor.pid"
input_file=/dev/null
output_log=/dev/null
umask=077
respawn_delay=2
respawn_max=5
respawn_period=60
retry=TERM/30
OPENRC_SERVICE
  if [ "$log_rotation" = true ]; then
    printf '%s\n' 'error_logger="$HOME/.t3/openrc-config/logger"' >> "$openrc_config_dir/rc/init.d/t3-server"
  else
    printf '%s\n' 'error_log="\"$(cat "$HOME/.t3/openrc-config/log-file")\""' >> "$openrc_config_dir/rc/init.d/t3-server"
  fi
  chmod 700 "$openrc_config_dir/rc/init.d/t3-server"

  openrc_configuration="$(cksum "$openrc_config_dir/rc/init.d/t3-server" "$openrc_config_dir/serve" "$openrc_config_dir/port" "$openrc_config_dir/working-directory" "$openrc_config_dir/log-file" "$openrc_config_dir/rotation-settings" "$openrc_config_dir/agent-config-home" "$openrc_config_dir/agent-runtime-dir" "$openrc_config_dir/rc/rc.conf")"
  if [ "$openrc_configuration" != "$(cat "$openrc_config_dir/config-checksum" 2>/dev/null || true)" ]; then
    openrc_config_changed=true
  fi

  if [ ! -f "$openrc_runtime_dir/openrc/softlevel" ]; then
    openrc_command openrc --user default
  fi
  openrc_available=true
}

stop_openrc() {
  if [ "$openrc_available" = true ]; then
    openrc_service --ifstarted t3-server stop
  fi
}

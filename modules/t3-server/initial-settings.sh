# Run in a subshell so locks and traps do not affect the server launcher.
initialize_t3_settings() (
  set -eu
  umask 077
  settings_home="${T3CODE_HOME:-$t3_home}"
  settings_state="$settings_home/userdata"
  settings_marker="$settings_home/initial-settings-initialized"
  settings_lock="$settings_home/initial-settings.lock"

  mkdir -p "$settings_home"
  if [ -e "$settings_marker" ] || [ -L "$settings_marker" ]; then
    return
  fi

  # The kernel releases this lock even if initialization is interrupted.
  # Do not unlink it: waiters must all keep locking the same inode.
  exec 9>"$settings_lock"
  if ! flock -w 30 9; then
    echo "Cannot acquire T3 settings lock; inspect $settings_lock" >&2
    exit 1
  fi

  if [ -e "$settings_marker" ] || [ -L "$settings_marker" ]; then
    return
  fi

  # Even an empty, unreadable, or linked userdata path belongs to an existing
  # installation. Missing JSON keys can represent deliberate user resets.
  if [ -n "$initial_settings" ] && [ ! -e "$settings_state" ] && [ ! -L "$settings_state" ]; then
    settings_temp="$(mktemp "$settings_home/initial-settings.XXXXXX")"
    trap 'rm -f "$settings_temp"' 0
    trap 'exit 1' 1 2 15
    printf '%s' "$initial_settings" | base64 -d > "$settings_temp"
    if mkdir "$settings_state" 2>/dev/null; then
      # A hard link publishes the complete private file without replacing a
      # file (or symlink) created by another process in the meantime.
      if ! ln -T "$settings_temp" "$settings_state/settings.json"; then
        if [ ! -e "$settings_state/settings.json" ] && [ ! -L "$settings_state/settings.json" ]; then
          rmdir "$settings_state"
          exit 1
        fi
      fi
    elif [ ! -e "$settings_state" ] && [ ! -L "$settings_state" ]; then
      echo "Could not create T3 user data directory: $settings_state" >&2
      exit 1
    fi
  fi

  # Also remember skipped/disabled initialization. A later deletion or input
  # change must not resurrect defaults after the user has customized T3.
  : > "$settings_marker"
)

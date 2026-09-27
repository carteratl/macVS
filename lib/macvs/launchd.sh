# shellcheck shell=bash
# launchd.sh - run a VM as a macOS launchd job.
#
# Two flavours:
#   system : /Library/LaunchDaemons (needs sudo). Starts at boot before anyone
#            logs in; QEMU still runs as your user thanks to UserName.
#   agent  : ~/Library/LaunchAgents (no sudo). Starts when you log in.
#
# KeepAlive is {SuccessfulExit = false}: launchd restarts QEMU only if it exits
# with a non-zero status (crash). A guest that powers itself off (exit 0), e.g.
# after `macvs stop`, stays off until `macvs start` or the next boot/login.

launchd_label()       { printf '%s.%s\n' "$MACVS_LAUNCHD_PREFIX" "$1"; }
launchd_agent_plist() { printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(launchd_label "$1")"; }
launchd_system_plist(){ printf '/Library/LaunchDaemons/%s.plist\n' "$(launchd_label "$1")"; }

# Print "system", "agent", or nothing.
launchd_kind() {
  if [ -f "$(launchd_system_plist "$1")" ]; then echo system
  elif [ -f "$(launchd_agent_plist "$1")" ]; then echo agent
  fi
}

launchd_domain() { # kind
  case "$1" in system) echo system ;; agent) echo "gui/$(id -u)" ;; *) return 1 ;; esac
}

launchd_plist_path() { # name kind
  case "$2" in system) launchd_system_plist "$1" ;; agent) launchd_agent_plist "$1" ;; esac
}

launchd_sudo() { # kind cmd...
  local kind="$1"; shift
  if [ "$kind" = system ]; then sudo "$@"; else "$@"; fi
}

# launchd's view of the job: running | spawn scheduled | not running | waiting | (empty if not loaded)
launchd_state() { # name
  local kind domain
  kind="$(launchd_kind "$1")"; [ -n "$kind" ] || return 1
  domain="$(launchd_domain "$kind")"
  launchctl print "$domain/$(launchd_label "$1")" 2>/dev/null | awk -F' = ' '/^[[:space:]]+state = /{print $2; exit}'
}

# Paths macOS privacy controls (TCC) keep launchd jobs out of.
tcc_protected_path() { # path
  case "$1" in
    "$HOME"/Documents|"$HOME"/Documents/*|"$HOME"/Desktop|"$HOME"/Desktop/*|"$HOME"/Downloads|"$HOME"/Downloads/*|"$HOME/Library/Mobile Documents"*)
      return 0 ;;
  esac
  return 1
}

launchd_render_plist() { # kind  (uses loaded VM_* vars)
  local kind="$1" label path_env
  label="$(launchd_label "$VM_NAME")"
  path_env="$(dirname "$MACVS_QEMU_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"
  cat <<EOT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$MACVS_BIN_DIR/macvs")</string>
    <string>run</string>
    <string>$(xml_escape "$VM_NAME")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(xml_escape "$path_env")</string>
    <key>HOME</key>
    <string>$(xml_escape "$HOME")</string>
    <key>MACVS_HOME</key>
    <string>$(xml_escape "$MACVS_HOME")</string>
  </dict>
EOT
  if [ "$kind" = system ]; then
    cat <<EOT
  <key>UserName</key>
  <string>$(id -un)</string>
  <key>GroupName</key>
  <string>$(id -gn)</string>
EOT
  fi
  cat <<EOT
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$VM_DIR")</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>15</integer>
  <key>ExitTimeOut</key>
  <integer>$((MACVS_STOP_TIMEOUT + 30))</integer>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$VM_LAUNCHD_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$VM_LAUNCHD_LOG")</string>
</dict>
</plist>
EOT
}

# Things that must hold before we hand a job to launchd.
launchd_preflight() {
  if tcc_protected_path "$MACVS_BIN_DIR"; then
    die "macvs is running from $MACVS_BIN_DIR, inside a folder macOS privacy controls hide from launchd." \
        "Run ./install.sh and use the installed 'macvs' command (it lives under ~/.macvs/app)."
  fi
  if tcc_protected_path "$MACVS_HOME"; then
    die "MACVS_HOME=$MACVS_HOME is inside a folder macOS privacy controls hide from launchd; use the default ~/.macvs"
  fi
}

launchd_install() { # kind
  local kind="$1" existing label plist tmp domain t
  qemu_detect
  launchd_preflight
  label="$(launchd_label "$VM_NAME")"
  plist="$(launchd_plist_path "$VM_NAME" "$kind")"
  domain="$(launchd_domain "$kind")"
  existing="$(launchd_kind "$VM_NAME")"
  if [ -n "$existing" ] && [ "$existing" != "$kind" ]; then
    die "$VM_NAME is already installed as a $existing job; run 'macvs daemon uninstall $VM_NAME' first"
  fi
  if vm_is_running; then
    info "stopping the running instance so launchd can take over"
    vm_stop
  fi
  mkdir -p "$VM_LOG_DIR"; touch "$VM_LAUNCHD_LOG"
  tmp="$(mktemp -t macvs-plist)"
  launchd_render_plist "$kind" > "$tmp"
  plutil -lint -s "$tmp" >/dev/null || { rm -f "$tmp"; die "generated plist failed validation"; }

  if [ "$kind" = system ]; then
    info "installing LaunchDaemon $plist (sudo will prompt for your password)"
    sudo install -o root -g wheel -m 0644 "$tmp" "$plist"
  else
    mkdir -p "$HOME/Library/LaunchAgents"
    install -m 0644 "$tmp" "$plist"
    info "installed LaunchAgent $plist"
  fi
  rm -f "$tmp"
  launchd_sudo "$kind" launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  launchd_sudo "$kind" launchctl enable "$domain/$label" 2>/dev/null || true
  launchd_sudo "$kind" launchctl bootstrap "$domain" "$plist" || die "launchctl bootstrap failed"

  # Verify the job really brought QEMU up. A wrapper that cannot even start would
  # otherwise sit in launchd's KeepAlive loop forever, so roll back instead.
  t=0
  until vm_is_running || [ "$t" -ge 15 ]; do sleep 1; t=$((t + 1)); done
  if ! vm_is_running; then
    err "launchd loaded the job but QEMU did not start; rolling back. Last log lines ($VM_LAUNCHD_LOG):"
    tail -n 5 "$VM_LAUNCHD_LOG" >&2 || true
    launchd_sudo "$kind" launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    launchd_sudo "$kind" rm -f "$plist"
    exit 1
  fi
  ok "$VM_NAME is now managed by launchd ($kind): label $label, pid $(vm_pid)"
}

launchd_uninstall() {
  local kind label plist domain
  kind="$(launchd_kind "$VM_NAME")"
  [ -n "$kind" ] || { info "$VM_NAME has no launchd job"; return 0; }
  label="$(launchd_label "$VM_NAME")"
  plist="$(launchd_plist_path "$VM_NAME" "$kind")"
  domain="$(launchd_domain "$kind")"
  if vm_is_running; then vm_stop; fi
  [ "$kind" = system ] && info "removing LaunchDaemon (sudo will prompt for your password)"
  launchd_sudo "$kind" launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  launchd_sudo "$kind" rm -f "$plist"
  ok "removed launchd job for $VM_NAME ($kind)"
}

launchd_kickstart() {
  local kind label domain
  kind="$(launchd_kind "$VM_NAME")"
  label="$(launchd_label "$VM_NAME")"
  domain="$(launchd_domain "$kind")"
  [ "$kind" = system ] && info "starting via launchd (sudo may prompt for your password)"
  launchd_sudo "$kind" launchctl kickstart "$domain/$label" || die "launchctl kickstart failed"
}

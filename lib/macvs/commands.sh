# shellcheck shell=bash
# shellcheck disable=SC2034  # VM_* variables are consumed by the other lib files
# commands.sh - CLI command implementations and dispatch.

usage() {
  cat <<EOT
macvs $MACVS_VERSION - Debian virtual servers on Apple Silicon (QEMU + Hypervisor.framework + launchd)

Usage: macvs <command> [options]

VM lifecycle
  create <name> [options]     Create a Debian server (see 'macvs create --help')
  start <name>                Boot a VM (via launchd if a daemon is installed)
  stop <name> [--force]       Power a VM off cleanly (ACPI), escalating if needed
  restart <name>
  destroy <name> [--yes]      Stop, remove its launchd job, and delete all its files
  run <name>                  Run QEMU in the foreground (what launchd executes)

Inspect and connect
  list                        All VMs and their state
  status <name>               Details for one VM
  ssh <name> [command]        SSH in as the admin user
  ssh-config <name>           Print an ~/.ssh/config Host block
  console <name>              Attach to the serial console (Ctrl-] detaches)
  logs <name> [-f] [--qemu|--launchd]
  wait <name>                 Block until SSH and cloud-init are ready
  reseed <name>               Rebuild the cloud-init seed from vm.conf (VM must be stopped)

Deployment
  daemon install <name> [--system|--agent]   Register with launchd (system needs sudo)
  daemon uninstall <name>
  daemon status <name>
  daemon plist <name> [--system|--agent]     Print the plist without installing it

Images
  image pull [--release R] [--variant V] [--refresh]
  image list
  image rm <release>

Other
  doctor                      Check this Mac for everything macvs needs
  version | help

Environment: MACVS_HOME (default ~/.macvs) holds images, VMs, and an optional 'config'.
EOT
}

usage_create() {
  cat <<EOT
Usage: macvs create <name> [options]

  --cpus N             vCPUs                          (default $MACVS_DEFAULT_CPUS)
  --memory MiB         RAM in MiB                     (default $MACVS_DEFAULT_MEMORY)
  --disk SIZE          Virtual disk size, e.g. 25G    (default $MACVS_DEFAULT_DISK)
  --ssh-port PORT      Host port forwarded to guest 22 (default: first free from $MACVS_DEFAULT_SSH_PORT_BASE)
  --forward H:G        Extra TCP forward host:guest; repeatable or comma-separated
  --bind ADDR          Host address forwards bind to  (default $MACVS_DEFAULT_BIND; 0.0.0.0 = LAN)
  --user NAME          Admin user created in the guest (default $MACVS_DEFAULT_USER)
  --ssh-key FILE.pub   Public key to authorise        (default: ~/.ssh/id_{ed25519,ecdsa,rsa}.pub, else a new per-VM key)
  --password           Prompt for a console password for the admin user (SSH stays key-only)
  --timezone TZ        Guest timezone                 (default: this Mac's, $(host_timezone))
  --release NAME       Debian release codename        (default $MACVS_DEFAULT_RELEASE = Debian 13)
  --variant NAME       Cloud image variant            (default $MACVS_DEFAULT_VARIANT)
  --cache MODE         QEMU disk cache mode           (default $MACVS_DEFAULT_DISK_CACHE)
  --start              Boot after creating and wait until SSH + cloud-init are ready
  --daemon [system|agent]  Also register with launchd and start it (system needs sudo)
EOT
}

# ---------------------------------------------------------------------------
cmd_create() {
  local name="" cpus="$MACVS_DEFAULT_CPUS" memory="$MACVS_DEFAULT_MEMORY" disk="$MACVS_DEFAULT_DISK"
  local ssh_port="" forwards="" bind="$MACVS_DEFAULT_BIND" user="$MACVS_DEFAULT_USER" sshkey=""
  local want_password="" tz="" release="$MACVS_DEFAULT_RELEASE" variant="$MACVS_DEFAULT_VARIANT"
  local cache="$MACVS_DEFAULT_DISK_CACHE" do_start="" daemon_kind="" f pw pw2 hash

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage_create; return 0 ;;
      --cpus)     cpus="$2"; shift 2 ;;
      --memory)   memory="$2"; shift 2 ;;
      --disk)     disk="$2"; shift 2 ;;
      --ssh-port) ssh_port="$2"; shift 2 ;;
      --forward)  forwards="$forwards ${2//,/ }"; shift 2 ;;
      --bind)     bind="$2"; shift 2 ;;
      --user)     user="$2"; shift 2 ;;
      --ssh-key)  sshkey="$2"; shift 2 ;;
      --password) want_password=1; shift ;;
      --timezone) tz="$2"; shift 2 ;;
      --release)  release="$2"; shift 2 ;;
      --variant)  variant="$2"; shift 2 ;;
      --cache)    cache="$2"; shift 2 ;;
      --start)    do_start=1; shift ;;
      --daemon)
        do_start=1
        case "${2:-}" in system|agent) daemon_kind="$2"; shift 2 ;; *) daemon_kind=system; shift ;; esac ;;
      -*) die "unknown option for create: $1 (try: macvs create --help)" ;;
      *)  [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { usage_create; die "a VM name is required"; }
  validate_name "$name"
  vm_exists "$name" && die "VM '$name' already exists"
  is_int "$cpus"   && [ "$cpus" -ge 1 ]   || die "--cpus must be a positive integer"
  is_int "$memory" && [ "$memory" -ge 512 ] || die "--memory must be an integer >= 512 (MiB)"
  [[ "$disk" =~ ^[0-9]+[GgMm]$ ]] || die "--disk must look like 25G"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--user must be a lowercase unix username"
  [[ "$cache" =~ ^(writeback|writethrough|none|unsafe|directsync)$ ]] || die "--cache must be a QEMU cache mode"

  require_cmd hdiutil; require_cmd nc; require_cmd ssh; require_cmd ssh-keygen
  qemu_detect
  hvf_available || die "Hypervisor.framework not available (kern.hv_support != 1); macvs needs Apple Silicon with virtualization enabled"

  # Ports
  if [ -n "$ssh_port" ]; then
    is_int "$ssh_port" || die "--ssh-port must be an integer"
    check_forward "$ssh_port:22"
  else
    ssh_port="$(pick_free_port "$MACVS_DEFAULT_SSH_PORT_BASE")"
  fi
  for f in $forwards; do check_forward "$f"; done
  forwards="$(printf '%s\n' $forwards | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  if [ "$bind" != 0.0.0.0 ] && [ "$bind" != 127.0.0.1 ]; then
    [[ "$bind" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--bind must be an IPv4 address"
  fi

  # Console password (optional)
  hash=""
  if [ -n "$want_password" ]; then
    [ -t 0 ] || die "--password needs an interactive terminal"
    printf 'Console password for %s: ' "$user" >&2; read -r -s pw; echo >&2
    printf 'Repeat password: ' >&2; read -r -s pw2; echo >&2
    [ "$pw" = "$pw2" ] || die "passwords do not match"
    [ -n "$pw" ] || die "empty password"
    hash="$(password_hash "$pw")" || die "cannot hash password: need an OpenSSL with 'passwd -6' (brew install openssl@3)"
    unset pw pw2
  fi

  # Base image (network only if not cached)
  image_ensure "$release" "$variant"

  # Create the VM directory; clean it up if anything below fails.
  VM_DIR="$(vm_dir "$name")"
  [ -e "$VM_DIR" ] && die "$VM_DIR already exists but has no vm.conf; remove it manually"
  mkdir -p "$VM_DIR/run" "$VM_DIR/logs" "$VM_DIR/ssh" "$VM_DIR/cloud-init"
  chmod 700 "$VM_DIR"
  CREATE_DONE=""
  trap '[ -n "$CREATE_DONE" ] || { err "create failed; removing $VM_DIR"; rm -rf "$VM_DIR"; }' EXIT

  # SSH key
  local identity=""
  if [ -n "$sshkey" ]; then
    [ -f "$sshkey" ] || die "--ssh-key file not found: $sshkey"
    grep -qE '^(ssh-|ecdsa-|sk-)' "$sshkey" || die "$sshkey does not look like an OpenSSH public key"
    [ -f "${sshkey%.pub}" ] && identity="${sshkey%.pub}"
  elif sshkey="$(find_default_pubkey)"; then
    info "authorising your default key $sshkey"
    [ -f "${sshkey%.pub}" ] && identity="${sshkey%.pub}"
  else
    info "no default SSH key found; generating a dedicated key for this VM"
    ssh-keygen -q -t ed25519 -N '' -C "macvs-$name" -f "$VM_DIR/ssh/id_ed25519"
    sshkey="$VM_DIR/ssh/id_ed25519.pub"; identity="$VM_DIR/ssh/id_ed25519"
  fi

  VM_NAME="$name"; VM_CREATED="$(now_iso)"; VM_RELEASE="$release"; VM_VARIANT="$variant"
  VM_IMAGE="$IMG_FILE"; VM_IMAGE_SHA512="$IMG_SHA"; VM_CPUS="$cpus"; VM_MEMORY="$memory"
  VM_DISK="$disk"; VM_DISK_CACHE="$cache"; VM_MACHINE=virt; VM_BIND="$bind"; VM_SSH_PORT="$ssh_port"
  VM_FORWARDS="$forwards"; VM_USER="$user"; VM_SSH_PUBKEY="$sshkey"; VM_SSH_IDENTITY="$identity"
  VM_TIMEZONE="${tz:-$(host_timezone)}"; VM_PASSWORD_HASH="$hash"; VM_EXTRA_ARGS=""
  save_vm_conf
  load_vm "$name"

  # Disk: clone the verified base image (instant on APFS) and grow it.
  info "creating ${disk} disk from $IMG_FILE"
  cp -c "$IMG_PATH" "$VM_DISK_PATH" 2>/dev/null || cp "$IMG_PATH" "$VM_DISK_PATH"
  "$MACVS_QEMU_IMG" resize -q "$VM_DISK_PATH" "$disk" || die "qemu-img resize failed"
  chmod 600 "$VM_DISK_PATH"

  # UEFI variable store, one per VM.
  cp "$MACVS_FW_VARS" "$VM_NVRAM_PATH"; chmod 600 "$VM_NVRAM_PATH"

  # cloud-init seed
  info "building cloud-init seed (user '$user', hostname '${name%%.*}')"
  cloudinit_generate

  CREATE_DONE=1
  trap - EXIT
  ok "created $name in $VM_DIR"
  echo
  cmd_status "$name"

  if [ -n "$daemon_kind" ]; then
    echo
    launchd_install "$daemon_kind"
    vm_wait_ssh; vm_wait_cloudinit; print_connect_hint
  elif [ -n "$do_start" ]; then
    echo
    vm_start_direct; vm_wait_ssh; vm_wait_cloudinit; print_connect_hint
  else
    echo
    printf 'Next:  macvs start %s        (or: macvs daemon install %s)\n' "$name" "$name" >&2
  fi
}

print_connect_hint() {
  echo >&2
  printf '%sConnect:%s  macvs ssh %s\n' "$C_BOLD" "$C_RST" "$VM_NAME" >&2
  printf '          ssh %s -p %s %s\n' "${VM_SSH_IDENTITY:+-i $VM_SSH_IDENTITY}" "$VM_SSH_PORT" "$VM_SSH_DEST" >&2
}

# ---------------------------------------------------------------------------
cmd_start() {
  [ $# -eq 1 ] || die "usage: macvs start <name>"
  load_vm "$1"
  if vm_is_running; then info "$VM_NAME is already running (pid $(vm_pid))"; return 0; fi
  if [ -n "$(launchd_kind "$VM_NAME")" ]; then
    launchd_kickstart
    sleep 2
    if vm_is_running; then ok "$VM_NAME running (pid $(vm_pid)) under launchd"
    else warn "launchd was asked to start $VM_NAME; check 'macvs status $VM_NAME' and $VM_LAUNCHD_LOG"; fi
  else
    vm_start_direct
  fi
}

cmd_stop() {
  local name="" force=""
  while [ $# -gt 0 ]; do
    case "$1" in --force|-f) force=1 ;; -*) die "unknown option: $1" ;; *) name="$1" ;; esac; shift
  done
  [ -n "$name" ] || die "usage: macvs stop <name> [--force]"
  load_vm "$name"
  vm_stop "$MACVS_STOP_TIMEOUT" "$force"
}

cmd_restart() {
  [ $# -eq 1 ] || die "usage: macvs restart <name>"
  cmd_stop "$1"
  cmd_start "$1"
}

cmd_run() {
  [ $# -eq 1 ] || die "usage: macvs run <name>"
  load_vm "$1"
  vm_run_foreground || exit $?
}

cmd_wait() {
  [ $# -eq 1 ] || die "usage: macvs wait <name>"
  load_vm "$1"
  vm_wait_ssh; vm_wait_cloudinit
}

cmd_reseed() {
  [ $# -eq 1 ] || die "usage: macvs reseed <name>"
  load_vm "$1"
  vm_is_running && die "stop $VM_NAME before reseeding"
  cloudinit_generate
  ok "rebuilt $VM_SEED_PATH (cloud-init will re-run per-instance modules on next boot)"
}

# ---------------------------------------------------------------------------
cmd_status() {
  [ $# -eq 1 ] || die "usage: macvs status <name>"
  load_vm "$1"
  local pid state kind lstate disk_used f
  if pid="$(vm_pid)"; then state="${C_GRN}running${C_RST} (pid $pid, up $(vm_uptime "$pid"))"; else state="${C_DIM}stopped${C_RST}"; fi
  kind="$(launchd_kind "$VM_NAME")"
  if [ -n "$kind" ]; then lstate="$(launchd_state "$VM_NAME" || true)"; kind="$kind (${lstate:-not loaded})"; else kind="none (direct start)"; fi
  disk_used="$(du -h "$VM_DISK_PATH" 2>/dev/null | awk '{print $1}')"
  printf '%s%s%s\n' "$C_BOLD" "$VM_NAME" "$C_RST"
  printf '  state      %b\n' "$state"
  printf '  image      %s (%s)\n' "$VM_IMAGE" "$VM_RELEASE"
  printf '  resources  %s vCPU, %s MiB RAM, %s disk (%s used)\n' "$VM_CPUS" "$VM_MEMORY" "$VM_DISK" "${disk_used:-?}"
  printf '  ssh        %s@%s -p %s\n' "$VM_USER" "$VM_SSH_HOST" "$VM_SSH_PORT"
  if [ -n "$VM_FORWARDS" ]; then
    for f in $VM_FORWARDS; do printf '  forward    %s:%s -> guest:%s\n' "$VM_BIND" "${f%%:*}" "${f##*:}"; done
  fi
  printf '  bind       %s\n' "$VM_BIND"
  printf '  launchd    %s\n' "$kind"
  printf '  files      %s\n' "$VM_DIR"
}

cmd_list() {
  local d n pid state kind
  printf '%-24s %-10s %-8s %-8s %-6s %-8s %s\n' NAME STATE PID SSH CPUS MEM LAUNCHD
  for d in "$MACVS_HOME"/vms/*/; do
    [ -f "$d/vm.conf" ] || continue
    n="$(basename "$d")"
    load_vm "$n"
    if pid="$(vm_pid)"; then state=running; else state=stopped; pid=-; fi
    kind="$(launchd_kind "$n")"
    printf '%-24s %-10s %-8s %-8s %-6s %-8s %s\n' "$n" "$state" "$pid" "$VM_SSH_PORT" "$VM_CPUS" "$VM_MEMORY" "${kind:--}"
  done
}

cmd_ssh() {
  [ $# -ge 1 ] || die "usage: macvs ssh <name> [command...]"
  load_vm "$1"; shift
  vm_is_running || die "$VM_NAME is not running"
  exec ssh "${SSH_OPTS[@]}" "$VM_SSH_DEST" "$@"
}

cmd_ssh_config() {
  [ $# -eq 1 ] || die "usage: macvs ssh-config <name>"
  load_vm "$1"
  cat <<EOT
Host $VM_NAME
    HostName $VM_SSH_HOST
    Port $VM_SSH_PORT
    User $VM_USER
    UserKnownHostsFile $VM_KNOWN_HOSTS
    StrictHostKeyChecking accept-new
EOT
  if [ -n "$VM_SSH_IDENTITY" ]; then
    printf '    IdentityFile %s\n    IdentitiesOnly yes\n' "$VM_SSH_IDENTITY"
  fi
}

cmd_console() {
  [ $# -eq 1 ] || die "usage: macvs console <name>"
  load_vm "$1"
  vm_console
}

cmd_logs() {
  local name="" follow="" which=console
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow) follow=1 ;; --qemu) which=qemu ;; --launchd) which=launchd ;; --console) which=console ;;
      -*) die "unknown option: $1" ;; *) name="$1" ;;
    esac; shift
  done
  [ -n "$name" ] || die "usage: macvs logs <name> [-f] [--console|--qemu|--launchd]"
  load_vm "$name"
  local file
  case "$which" in console) file="$VM_CONSOLE_LOG" ;; qemu) file="$VM_QEMU_LOG" ;; launchd) file="$VM_LAUNCHD_LOG" ;; esac
  [ -f "$file" ] || die "no log yet: $file"
  if [ -n "$follow" ]; then tail -n 50 -f "$file"; else tail -n 50 "$file"; fi
}

cmd_destroy() {
  local name="" yes=""
  while [ $# -gt 0 ]; do
    case "$1" in --yes|-y) yes=1 ;; -*) die "unknown option: $1" ;; *) name="$1" ;; esac; shift
  done
  [ -n "$name" ] || die "usage: macvs destroy <name> [--yes]"
  load_vm "$name"
  if [ -z "$yes" ]; then
    confirm "Permanently delete VM '$VM_NAME' and everything in $VM_DIR?" || die "aborted"
  fi
  launchd_uninstall
  if vm_is_running; then vm_stop; fi
  rm -rf "$VM_DIR"
  ok "destroyed $VM_NAME"
}

# ---------------------------------------------------------------------------
cmd_daemon() {
  local sub="${1:-}" name="" kind="" a
  shift || true
  for a in "$@"; do
    case "$a" in --system) kind=system ;; --agent) kind=agent ;; -*) die "unknown option: $a" ;; *) name="$a" ;; esac
  done
  case "$sub" in
    install)
      [ -n "$name" ] || die "usage: macvs daemon install <name> [--system|--agent]"
      load_vm "$name"; launchd_install "${kind:-system}" ;;
    uninstall)
      [ -n "$name" ] || die "usage: macvs daemon uninstall <name>"
      load_vm "$name"; launchd_uninstall ;;
    status)
      [ -n "$name" ] || die "usage: macvs daemon status <name>"
      load_vm "$name"
      kind="$(launchd_kind "$VM_NAME")"
      [ -n "$kind" ] || { echo "no launchd job for $VM_NAME"; return 0; }
      printf 'kind:   %s\nlabel:  %s\nplist:  %s\nstate:  %s\n' "$kind" "$(launchd_label "$VM_NAME")" \
        "$(launchd_plist_path "$VM_NAME" "$kind")" "$(launchd_state "$VM_NAME" || echo 'not loaded')" ;;
    plist)
      [ -n "$name" ] || die "usage: macvs daemon plist <name> [--system|--agent]"
      load_vm "$name"; qemu_detect; launchd_render_plist "${kind:-system}" ;;
    *) die "usage: macvs daemon <install|uninstall|status|plist> <name>" ;;
  esac
}

cmd_image() {
  local sub="${1:-}" release="$MACVS_DEFAULT_RELEASE" variant="$MACVS_DEFAULT_VARIANT" force=""
  shift || true
  case "$sub" in
    pull)
      while [ $# -gt 0 ]; do
        case "$1" in
          --release) release="$2"; shift 2 ;; --variant) variant="$2"; shift 2 ;;
          --refresh|--force) force=force; shift ;; *) die "unknown option: $1" ;;
        esac
      done
      image_pull "$release" "$variant" "$force" ;;
    list) image_list ;;
    rm)   [ $# -eq 1 ] || die "usage: macvs image rm <release>"; image_remove "$1" ;;
    *)    die "usage: macvs image <pull|list|rm>" ;;
  esac
}

cmd_doctor() {
  local fails=0
  check() { # label ok? detail
    if [ "$2" = 0 ]; then printf '  %sok%s   %-28s %s\n' "$C_GRN" "$C_RST" "$1" "$3"
    else printf '  %sFAIL%s %-28s %s\n' "$C_RED" "$C_RST" "$1" "$3"; fails=$((fails + 1)); fi
  }
  note() { printf '  %snote%s %-28s %s\n' "$C_YEL" "$C_RST" "$1" "$2"; }
  echo "macvs doctor"
  [ "$(uname -s)" = Darwin ] && r=0 || r=1; check "macOS" $r "$(sw_vers -productVersion 2>/dev/null)"
  [ "$(uname -m)" = arm64 ] && r=0 || r=1; check "Apple Silicon (arm64)" $r "$(uname -m)"
  hvf_available && r=0 || r=1; check "Hypervisor.framework" $r "kern.hv_support=$(sysctl -n kern.hv_support 2>/dev/null)"
  local q; q="$(command -v qemu-system-aarch64 2>/dev/null || true)"
  [ -n "$q" ] && r=0 || r=1; check "qemu-system-aarch64" $r "${q:-missing: brew install qemu} $("$q" --version 2>/dev/null | head -n 1 | awk '{print $4}')"
  command -v qemu-img >/dev/null 2>&1 && r=0 || r=1; check "qemu-img" $r "$(command -v qemu-img 2>/dev/null)"
  if [ -n "$q" ]; then
    ( qemu_detect ) >/dev/null 2>&1 && r=0 || r=1
    ( qemu_detect >/dev/null 2>&1; check "UEFI firmware" $r "${MACVS_QEMU_SHARE:-not found}" )
  fi
  for t in hdiutil curl shasum ssh ssh-keygen nc plutil launchctl; do
    command -v "$t" >/dev/null 2>&1 && r=0 || r=1; check "$t" $r "$(command -v "$t" 2>/dev/null)"
  done
  mkdir -p "$MACVS_HOME" 2>/dev/null && [ -w "$MACVS_HOME" ] && r=0 || r=1; check "MACVS_HOME writable" $r "$MACVS_HOME"
  if tcc_protected_path "$MACVS_HOME"; then r=1; else r=0; fi
  check "MACVS_HOME outside TCC folders" $r "$MACVS_HOME"
  if tcc_protected_path "$MACVS_BIN_DIR"; then r=1; else r=0; fi
  if [ $r = 1 ]; then check "macvs outside TCC folders" 1 "$MACVS_BIN_DIR (launchd cannot run it here; use ./install.sh)"; else check "macvs outside TCC folders" 0 "$MACVS_BIN_DIR"; fi
  if password_hash x >/dev/null 2>&1; then r=0; else r=1; fi
  [ $r = 0 ] && check "openssl passwd -6 (optional)" 0 "available for --password" || note "openssl passwd -6 (optional)" "brew install openssl@3 to use --password"
  if sudo -n true 2>/dev/null; then note "sudo" "passwordless"; else note "sudo" "will prompt when installing a system LaunchDaemon"; fi
  echo
  if [ "$fails" = 0 ]; then ok "this Mac is ready for macvs"; else die "$fails problem(s) found"; fi
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    create)      cmd_create "$@" ;;
    start)       cmd_start "$@" ;;
    stop)        cmd_stop "$@" ;;
    restart)     cmd_restart "$@" ;;
    run)         cmd_run "$@" ;;
    destroy|rm)  cmd_destroy "$@" ;;
    list|ls)     cmd_list "$@" ;;
    status)      cmd_status "$@" ;;
    ssh)         cmd_ssh "$@" ;;
    ssh-config)  cmd_ssh_config "$@" ;;
    console)     cmd_console "$@" ;;
    logs)        cmd_logs "$@" ;;
    wait)        cmd_wait "$@" ;;
    reseed)      cmd_reseed "$@" ;;
    daemon)      cmd_daemon "$@" ;;
    image)       cmd_image "$@" ;;
    doctor)      cmd_doctor "$@" ;;
    version|--version|-v) echo "macvs $MACVS_VERSION" ;;
    help|--help|-h) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

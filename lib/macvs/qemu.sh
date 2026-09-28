# shellcheck shell=bash
# qemu.sh - QEMU runtime: argument building, process control, QMP, SSH, console.

# ---------------------------------------------------------------------------
# Locate QEMU and its UEFI firmware
# ---------------------------------------------------------------------------
qemu_detect() {
  MACVS_QEMU_BIN="${MACVS_QEMU_BIN:-$(command -v qemu-system-aarch64 2>/dev/null || true)}"
  [ -n "$MACVS_QEMU_BIN" ] || die "qemu-system-aarch64 not found; install it with: brew install qemu"
  MACVS_QEMU_IMG="${MACVS_QEMU_IMG:-$(command -v qemu-img 2>/dev/null || true)}"
  [ -n "$MACVS_QEMU_IMG" ] || die "qemu-img not found; install it with: brew install qemu"

  if [ -z "${MACVS_QEMU_SHARE:-}" ]; then
    local prefix real cand
    prefix="$(dirname "$(dirname "$MACVS_QEMU_BIN")")"        # e.g. /opt/homebrew
    real="$(resolve_path "$MACVS_QEMU_BIN")"                   # e.g. /opt/homebrew/Cellar/qemu/X/bin/...
    for cand in "$prefix/share/qemu" "$(dirname "$(dirname "$real")")/share/qemu" \
                /opt/homebrew/share/qemu /usr/local/share/qemu; do
      if [ -f "$cand/edk2-aarch64-code.fd" ] && [ -f "$cand/edk2-arm-vars.fd" ]; then
        MACVS_QEMU_SHARE="$cand"; break
      fi
    done
  fi
  [ -n "${MACVS_QEMU_SHARE:-}" ] || die "cannot locate QEMU UEFI firmware (edk2-aarch64-code.fd); set MACVS_QEMU_SHARE"
  MACVS_FW_CODE="$MACVS_QEMU_SHARE/edk2-aarch64-code.fd"
  MACVS_FW_VARS="$MACVS_QEMU_SHARE/edk2-arm-vars.fd"
}

hvf_available() { [ "$(sysctl -n kern.hv_support 2>/dev/null)" = 1 ]; }

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------
# The host port QEMU actually binds for a forward. Ports below 1024 on a specific
# address (the default 127.0.0.1) cannot be bound by a non-root process on macOS, so
# those are bound on a relay port and a launchd job owns the real port (see launchd.sh).
host_bind_port() { # hostport
  if forward_needs_relay "$1" "$VM_BIND"; then relay_port "$1"; else printf '%s\n' "$1"; fi
}

qemu_build_args() {
  local net f
  net="user,id=net0,hostfwd=tcp:${VM_BIND}:$(host_bind_port "$VM_SSH_PORT")-:22"
  for f in $VM_FORWARDS; do
    net="$net,hostfwd=tcp:${VM_BIND}:$(host_bind_port "${f%%:*}")-:${f##*:}"
  done
  # PCI slots are pinned so guest interface names never change when devices are
  # added. NIC in slot 1 (enp0s1) and disk in slot 2 reproduce what the classic
  # "-drive if=virtio ... -device virtio-net-pci" command line yields (explicit
  # -device arguments are realised before the if=virtio disk), so hand-built VMs
  # import without touching their network configuration. Seed 3, balloon 4, rng 5.
  QEMU_ARGS=(
    -name "$VM_NAME"
    -machine "$VM_MACHINE" -accel hvf -cpu host
    -smp "$VM_CPUS" -m "$VM_MEMORY"
    -drive "if=pflash,format=raw,readonly=on,file=$MACVS_FW_CODE"
    -drive "if=pflash,format=raw,file=$VM_NVRAM_PATH"
    -drive "file=$VM_DISK_PATH,if=none,id=disk0,format=qcow2,cache=$VM_DISK_CACHE,discard=unmap"
    -device "virtio-net-pci,netdev=net0,addr=0x1"
    -device "virtio-blk-pci,drive=disk0,addr=0x2"
    -netdev "$net"
  )
  if [ "$VM_PROVISION" = cloud-init ]; then
    QEMU_ARGS+=(-drive "file=$VM_SEED_PATH,if=none,id=seed0,format=raw,readonly=on"
                -device "virtio-blk-pci,drive=seed0,addr=0x3")
  fi
  if [ "$VM_BALLOON" = on ]; then
    # Guest hands freed pages back to macOS within seconds instead of pinning them.
    QEMU_ARGS+=(-device "virtio-balloon-pci,free-page-reporting=on,deflate-on-oom=on,addr=0x4")
  fi
  QEMU_ARGS+=(
    -device "virtio-rng-pci,addr=0x5"
    -chardev "socket,id=con0,path=$VM_CONSOLE_SOCK,server=on,wait=off,logfile=$VM_CONSOLE_LOG,logappend=on"
    -serial chardev:con0
    -qmp "unix:$VM_QMP_SOCK,server=on,wait=off"
    -pidfile "$VM_PIDFILE"
    -display none
  )
  if [ -n "$VM_EXTRA_ARGS" ]; then
    # shellcheck disable=SC2206
    QEMU_ARGS+=($VM_EXTRA_ARGS)
  fi
}

# ---------------------------------------------------------------------------
# Process state
# ---------------------------------------------------------------------------
# Print the QEMU pid if this VM is running (cleans up stale pidfiles).
vm_pid() {
  local pid
  [ -f "$VM_PIDFILE" ] || return 1
  pid="$(tr -d '[:space:]' < "$VM_PIDFILE")"
  [ -n "$pid" ] || return 1
  if ps -p "$pid" -o command= 2>/dev/null | grep -qF -- "-name $VM_NAME "; then
    printf '%s\n' "$pid"
    return 0
  fi
  rm -f "$VM_PIDFILE"
  return 1
}

vm_is_running() { vm_pid >/dev/null 2>&1; }

vm_uptime() { # pid
  ps -p "$1" -o etime= 2>/dev/null | tr -d ' '
}

vm_prepare_runtime() {
  mkdir -p "$VM_RUN_DIR" "$VM_LOG_DIR"
  rm -f "$VM_QMP_SOCK" "$VM_CONSOLE_SOCK"
  [ -f "$VM_DISK_PATH" ]  || die "disk image missing: $VM_DISK_PATH"
  [ -f "$VM_NVRAM_PATH" ] || die "UEFI variable store missing: $VM_NVRAM_PATH"
  if [ "$VM_PROVISION" = cloud-init ]; then
    [ -f "$VM_SEED_PATH" ] || die "cloud-init seed missing: $VM_SEED_PATH (run: macvs reseed $VM_NAME)"
  fi
  hvf_available || die "Hypervisor.framework is not available on this Mac"
}

# ---------------------------------------------------------------------------
# QMP (QEMU machine protocol) over the per-VM unix socket
# ---------------------------------------------------------------------------
qmp_send() { # json-command
  [ -S "$VM_QMP_SOCK" ] || return 1
  printf '%s\n%s\n' '{"execute":"qmp_capabilities"}' "$1" | nc -U -w 3 "$VM_QMP_SOCK" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Start / run / stop
# ---------------------------------------------------------------------------
# Detached start (QEMU daemonizes itself). Used when no launchd job manages the VM.
vm_start_direct() {
  local pid
  if pid="$(vm_pid)"; then info "$VM_NAME is already running (pid $pid)"; return 0; fi
  qemu_detect
  vm_prepare_runtime
  qemu_build_args
  info "starting $VM_NAME ($VM_CPUS vCPU, ${VM_MEMORY} MiB, ssh ${VM_SSH_HOST}:${VM_SSH_PORT})"
  printf '%s starting (direct): %s\n' "$(now_iso)" "$MACVS_QEMU_BIN ${QEMU_ARGS[*]}" >> "$VM_QEMU_LOG"
  # QEMU's stderr goes straight to the log. (A process substitution here makes bash 3.2
  # wait on the tee child, which never exits when our stdout is a pipe.)
  if ! "$MACVS_QEMU_BIN" "${QEMU_ARGS[@]}" -daemonize 2>>"$VM_QEMU_LOG"; then
    err "QEMU failed to start; last lines of $VM_QEMU_LOG:"
    tail -n 5 "$VM_QEMU_LOG" >&2
    exit 1
  fi
  sleep 1
  pid="$(vm_pid)" || die "QEMU exited immediately after start (see $VM_QEMU_LOG and $VM_CONSOLE_LOG)"
  ok "$VM_NAME running (pid $pid)"
  if [ -z "$(launchd_kind "$VM_NAME")" ] && [ -n "$(vm_relayed_ports)" ]; then
    warn "no launchd job, so the relays for port(s) $(vm_relayed_ports | tr '\n' ' ')are not running;" \
         "reach them on $(vm_relayed_ports | while read -r p; do printf '%s ' "$(relay_port "$p")"; done)until 'macvs daemon install $VM_NAME'"
  fi
}

# Host ports of this VM that need a launchd relay (one per line).
vm_relayed_ports() {
  local f p
  for p in "$VM_SSH_PORT" $(for f in $VM_FORWARDS; do printf '%s\n' "${f%%:*}"; done); do
    forward_needs_relay "$p" "$VM_BIND" && printf '%s\n' "$p"
  done
  return 0
}

# Foreground run used by launchd. QEMU is a child so that SIGTERM/SIGINT from
# launchd (shutdown, bootout) or the terminal (Ctrl-C) becomes a clean ACPI
# power-off of the guest instead of an abrupt kill.
vm_run_foreground() {
  local pid child rc=0 signalled=""
  if pid="$(vm_pid)"; then
    # Exit 0 so a KeepAlive job does not spin; the VM is already up elsewhere.
    warn "$VM_NAME is already running (pid $pid); nothing to do"
    return 0
  fi
  qemu_detect
  vm_prepare_runtime
  qemu_build_args
  printf '%s starting (foreground): %s\n' "$(now_iso)" "$MACVS_QEMU_BIN ${QEMU_ARGS[*]}" >> "$VM_QEMU_LOG"

  "$MACVS_QEMU_BIN" "${QEMU_ARGS[@]}" &
  child=$!

  on_signal() {
    signalled=1
    info "$(now_iso) signal received; powering off $VM_NAME gracefully"
    qmp_send '{"execute":"system_powerdown"}' >/dev/null 2>&1 || kill -TERM "$child" 2>/dev/null || true
    # Watchdog: force QEMU to quit if the guest ignores ACPI.
    ( sleep "$MACVS_STOP_TIMEOUT"
      if kill -0 "$child" 2>/dev/null; then
        printf '%s guest did not power off in %ss; forcing quit\n' "$(now_iso)" "$MACVS_STOP_TIMEOUT" >&2
        qmp_send '{"execute":"quit"}' >/dev/null 2>&1 || kill -KILL "$child" 2>/dev/null || true
      fi ) &
  }
  trap on_signal TERM INT HUP

  while :; do
    # Capture wait's status directly; '$?' after an 'if' is always 0.
    wait "$child" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then break; fi
    kill -0 "$child" 2>/dev/null || break   # child really exited with $rc
    # otherwise wait was interrupted by a trapped signal; keep waiting
  done
  trap - TERM INT HUP
  rm -f "$VM_PIDFILE"
  printf '%s QEMU exited with status %s%s\n' "$(now_iso)" "$rc" "${signalled:+ (after signal)}" >> "$VM_QEMU_LOG"
  # A guest that powered off after we asked it to is a successful exit.
  if [ -n "$signalled" ] && [ "$rc" -gt 128 ]; then rc=0; fi
  return "$rc"
}

# Graceful stop: ACPI power-off via QMP, then escalate.
vm_stop() { # [timeout] [force]
  local timeout="${1:-$MACVS_STOP_TIMEOUT}" force="${2:-}" pid waited=0
  pid="$(vm_pid)" || { info "$VM_NAME is not running"; return 0; }
  if [ -z "$force" ]; then
    info "powering off $VM_NAME (pid $pid) via ACPI; waiting up to ${timeout}s"
    if ! qmp_send '{"execute":"system_powerdown"}' >/dev/null; then
      warn "QMP socket unreachable; sending SIGTERM instead"
      kill -TERM "$pid" 2>/dev/null || true
    fi
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$timeout" ]; do
      sleep 1; waited=$((waited + 1))
    done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    [ -n "$force" ] || warn "guest did not power off in time; forcing QEMU to quit"
    qmp_send '{"execute":"quit"}' >/dev/null || kill -TERM "$pid" 2>/dev/null || true
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; sleep 1; fi
  fi
  rm -f "$VM_PIDFILE"
  ok "$VM_NAME stopped"
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
# Non-interactive ssh for scripting: vm_ssh <remote command...>
vm_ssh() {
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$VM_SSH_DEST" "$@"
}

# Is sshd answering behind the forward? (A bare TCP connect is not enough: slirp
# accepts the host-side connection before it knows whether the guest port is open.)
ssh_banner_up() {
  local line
  line="$(nc -w 3 "$VM_SSH_HOST" "$VM_SSH_PORT" </dev/null 2>/dev/null | head -n 1 || true)"
  case "$line" in SSH-*) return 0 ;; *) return 1 ;; esac
}

vm_wait_ssh() { # [timeout]
  local timeout="${1:-$MACVS_SSH_TIMEOUT}" t=0 banner_at="" auth_grace=45
  info "waiting for SSH at ${VM_SSH_HOST}:${VM_SSH_PORT} (up to ${timeout}s)"
  while [ "$t" -lt "$timeout" ]; do
    vm_is_running || die "$VM_NAME is no longer running (see $VM_CONSOLE_LOG)"
    if [ -z "$banner_at" ] && ssh_banner_up; then
      banner_at="$t"
      if [ "$VM_PROVISION" != cloud-init ] && [ -z "$VM_SSH_IDENTITY" ]; then
        ok "SSH is answering after ${t}s (no key configured; 'macvs ssh' will ask for a password)"
        return 0
      fi
    fi
    if [ -n "$banner_at" ]; then
      if vm_ssh true 2>/dev/null; then ok "SSH is up after ${t}s"; return 0; fi
      # Imported systems: we cannot know the key is right, so do not block forever.
      if [ "$VM_PROVISION" != cloud-init ] && [ $((t - banner_at)) -ge "$auth_grace" ]; then
        warn "SSH answers but key authentication as $VM_USER failed; check --user/--ssh-key (macvs ssh will prompt)"
        return 0
      fi
    fi
    sleep 3; t=$((t + 3))
  done
  die "timed out waiting for SSH (see $VM_CONSOLE_LOG)"
}

vm_wait_cloudinit() {
  info "waiting for cloud-init to finish first-boot configuration"
  local status
  status="$(vm_ssh 'sudo cloud-init status --wait >/dev/null 2>&1; cloud-init status 2>/dev/null | head -n 1' 2>/dev/null || true)"
  case "$status" in
    *done*)  ok "cloud-init: ${status#status: }" ;;
    "")      warn "could not read cloud-init status" ;;
    *)       warn "cloud-init: ${status#status: } (see: macvs ssh $VM_NAME sudo cloud-init status --long)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Serial console
# ---------------------------------------------------------------------------
vm_console() {
  local saved
  vm_is_running || die "$VM_NAME is not running"
  [ -S "$VM_CONSOLE_SOCK" ] || die "console socket not found: $VM_CONSOLE_SOCK"
  [ -t 0 ] || die "console needs an interactive terminal"
  info "attached to serial console of $VM_NAME. Press Enter for a prompt; Ctrl-] to detach."
  saved="$(stty -g)"
  # Raw terminal, but keep signal generation with Ctrl-] as the interrupt key so
  # Ctrl-C/Ctrl-Z pass through to the guest.
  trap 'stty "$saved"; trap - INT TERM EXIT' INT TERM EXIT
  stty raw -echo isig intr '^]' quit undef susp undef
  nc -U "$VM_CONSOLE_SOCK" || true
  stty "$saved"
  trap - INT TERM EXIT
  echo
  info "detached from $VM_NAME"
}

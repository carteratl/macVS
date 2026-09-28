# shellcheck shell=bash
# shellcheck disable=SC2034  # VM_* variables are consumed by the other lib files
# commands.sh - CLI command implementations and dispatch.

usage() {
  cat <<EOT
macvs $MACVS_VERSION - durable Debian servers on Apple Silicon (QEMU + Hypervisor.framework + launchd)

Usage: macvs <command> [options]

VM lifecycle
  create <name> [options]     New Debian server: image, cloud-init, launchd job, boot (create --help)
  import <name> --disk FILE   Adopt an existing qcow2 as a macvs-managed server (import --help)
  start <name>                Boot a VM (via launchd if it has a job)
  stop <name> [--force]       Power a VM off cleanly (ACPI), escalating if needed
  restart <name>
  autostart <name> [on|off]   Show or set whether the VM boots with the Mac (default on)
  destroy <name> [--yes]      Stop, remove its launchd job, and delete all its files
  run <name>                  Run QEMU in the foreground (what launchd executes)

Inspect and connect
  list                        All VMs and their state
  status <name>               Details for one VM
  ssh <name> [command]        SSH in as the admin user
  ssh-config <name>           Print an ~/.ssh/config Host block
  console <name>              Attach to the serial console (Ctrl-] detaches)
  logs <name> [-f] [--qemu|--launchd]
  wait <name>                 Block until SSH (and cloud-init, if any) are ready
  reseed <name>               Rebuild the cloud-init seed from vm.conf (VM must be stopped)

Provisioning (inside a running VM, over SSH)
  deploy webroot <name> [options]   Web server: base tools, Apache, PHP-FPM, MariaDB, certbot (deploy webroot --help)
  deploy website <fqdn> <name>      A site on it: user, PHP-FPM pool, vhost, Hello World, database (deploy website --help)
  deploy list                       Available profiles

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

By default the new server gets the web ports (${MACVS_DEFAULT_WEB_FORWARDS// /, }) and SSH forwarded
on ${MACVS_DEFAULT_BIND} (127.0.0.1 = this Mac only), is registered as a launchd ${MACVS_DEFAULT_DAEMON} job that
boots with the Mac, and is started right away.

  --cpus N             vCPUs                          (default $MACVS_DEFAULT_CPUS)
  --memory MiB         RAM in MiB; freed guest memory is returned to macOS (default $MACVS_DEFAULT_MEMORY)
  --disk SIZE          Virtual disk size, e.g. 25G    (default $MACVS_DEFAULT_DISK)
  --ssh-port PORT      Host port forwarded to guest 22 (default: first free from $MACVS_DEFAULT_SSH_PORT_BASE)
  --forward H:G        Extra TCP forward host:guest; repeatable or comma-separated
  --no-web             Do not forward the default web ports
  --bind ADDR          Address forwards bind to       (default $MACVS_DEFAULT_BIND)
  --user NAME          Admin user created in the guest (default $MACVS_DEFAULT_USER)
  --ssh-key FILE.pub   Public key to authorise        (default: ~/.ssh/id_{ed25519,ecdsa,rsa}.pub, else a new per-VM key)
  --password           Prompt for a console password for the admin user (SSH stays key-only)
  --timezone TZ        Guest timezone                 (default: this Mac's, $(host_timezone))
  --release NAME       Debian release codename        (default $MACVS_DEFAULT_RELEASE = Debian 13)
  --variant NAME       Cloud image variant            (default $MACVS_DEFAULT_VARIANT)
  --cache MODE         QEMU disk cache mode           (default $MACVS_DEFAULT_DISK_CACHE)
  --no-balloon         Disable the virtio memory balloon
  --agent              Register as a per-user LaunchAgent (starts at login, no sudo)
  --no-daemon          Only create the VM; do not register with launchd or start it
  --no-wait            Do not wait for SSH and cloud-init
EOT
}

usage_import() {
  cat <<EOT
Usage: macvs import <name> --disk FILE.qcow2 [options]

Adopts an existing Debian/Linux disk image as a macvs-managed server. The disk is
cloned into ~/.macvs/vms/<name> (instant on APFS), no cloud-init seed is attached,
and the VM is registered with launchd and started like a created one.

  --disk FILE          Existing qcow2 image (required; must not be in use)
  --nvram FILE         Existing UEFI variable store; strongly recommended for systems
                       installed from an installer ISO, whose boot entry lives there
  --move               Remove the source files after a successful import
  --resize SIZE        Grow the virtual disk, e.g. 40G (never shrinks)
  --user NAME          Guest login user for 'macvs ssh' (default $MACVS_DEFAULT_USER)
  --ssh-key FILE       Private key (or its .pub) that user accepts
  --cpus N | --memory MiB | --ssh-port PORT | --forward H:G | --no-web | --bind ADDR
  --cache MODE | --no-balloon | --agent | --no-daemon | --no-wait   (as for create)
EOT
}

# ---------------------------------------------------------------------------
# Shared pieces for create and import
# ---------------------------------------------------------------------------
# Parse options common to create and import into OPT_* variables. Prints unknown
# options back (one per line) for the caller to handle.
parse_common_opt() { # option [value] -> returns 0 if consumed 2 args, 1 if consumed 1, 2 if not ours
  case "$1" in
    --cpus)      OPT_CPUS="$2"; return 0 ;;
    --memory)    OPT_MEMORY="$2"; return 0 ;;
    --ssh-port)  OPT_SSH_PORT="$2"; return 0 ;;
    --forward)   OPT_FORWARDS="$OPT_FORWARDS ${2//,/ }"; return 0 ;;
    --bind)      OPT_BIND="$2"; return 0 ;;
    --user)      OPT_USER="$2"; return 0 ;;
    --ssh-key)   OPT_SSHKEY="$2"; return 0 ;;
    --cache)     OPT_CACHE="$2"; return 0 ;;
    --no-web)    OPT_WEB=no; return 1 ;;
    --no-balloon) OPT_BALLOON=off; return 1 ;;
    --agent)     OPT_DAEMON=agent; return 1 ;;
    --no-daemon) OPT_DAEMON=none; return 1 ;;
    --no-wait)   OPT_WAIT=no; return 1 ;;
    *) return 2 ;;
  esac
}

init_common_opts() {
  OPT_CPUS="$MACVS_DEFAULT_CPUS"; OPT_MEMORY="$MACVS_DEFAULT_MEMORY"; OPT_SSH_PORT=""; OPT_FORWARDS=""
  OPT_BIND="$MACVS_DEFAULT_BIND"; OPT_USER="$MACVS_DEFAULT_USER"; OPT_SSHKEY=""; OPT_CACHE="$MACVS_DEFAULT_DISK_CACHE"
  OPT_WEB=yes; OPT_BALLOON=on; OPT_DAEMON="$MACVS_DEFAULT_DAEMON"; OPT_WAIT=yes
}

validate_common_opts() {
  is_int "$OPT_CPUS"   && [ "$OPT_CPUS" -ge 1 ]     || die "--cpus must be a positive integer"
  is_int "$OPT_MEMORY" && [ "$OPT_MEMORY" -ge 512 ] || die "--memory must be an integer >= 512 (MiB)"
  [[ "$OPT_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--user must be a lowercase unix username"
  [[ "$OPT_CACHE" =~ ^(writeback|writethrough|none|unsafe|directsync)$ ]] || die "--cache must be a QEMU cache mode"
  [[ "$OPT_DAEMON" =~ ^(system|agent|none)$ ]] || die "MACVS_DEFAULT_DAEMON must be system, agent, or none"
  if [ "$OPT_BIND" != 0.0.0.0 ] && [ "$OPT_BIND" != 127.0.0.1 ]; then
    [[ "$OPT_BIND" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--bind must be an IPv4 address"
  fi
}

# Resolve SSH port and forwards (with web defaults) into OPT_SSH_PORT / OPT_FORWARDS.
resolve_ports() {
  local f hint
  if [ -n "$OPT_SSH_PORT" ]; then
    is_int "$OPT_SSH_PORT" || die "--ssh-port must be an integer"
    check_forward "$OPT_SSH_PORT:22"
  else
    OPT_SSH_PORT="$(pick_free_port "$MACVS_DEFAULT_SSH_PORT_BASE")"
  fi
  for f in $OPT_FORWARDS; do check_forward "$f"; done
  if [ "$OPT_WEB" = yes ]; then
    hint="the web ports are forwarded by default; pass --no-web, or --forward to pick others"
    for f in $(merge_web_forwards "$OPT_FORWARDS"); do
      case " $OPT_FORWARDS " in *" $f "*) ;; *) check_forward "$f" "$hint" ;; esac
    done
    OPT_FORWARDS="$(merge_web_forwards "$OPT_FORWARDS")"
  fi
  # shellcheck disable=SC2086
  OPT_FORWARDS="$(printf '%s\n' $OPT_FORWARDS | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  # Privileged ports on a specific address are served through a relay port; it must be free too.
  local h r owner
  for h in "$OPT_SSH_PORT" $(for f in $OPT_FORWARDS; do printf '%s\n' "${f%%:*}"; done); do
    forward_needs_relay "$h" "$OPT_BIND" || continue
    r="$(relay_port "$h")"
    if owner="$(port_used_by_vm "$r")"; then die "relay port $r (for $h) is already assigned to VM '$owner'"; fi
    if port_listening "$r"; then die "relay port $r (for $h) is already in use on this Mac"; fi
  done
  return 0
}

# Register with launchd (or not), wait for the guest, print how to connect.
bringup_vm() {
  echo
  if [ "$OPT_DAEMON" = none ]; then
    printf 'Created without a launchd job. Boot it with:  macvs start %s\n' "$VM_NAME" >&2
    return 0
  fi
  launchd_install "$OPT_DAEMON"
  if [ "$OPT_WAIT" = yes ]; then
    vm_wait_ssh
    [ "$VM_PROVISION" = cloud-init ] && vm_wait_cloudinit
    print_connect_hint
  fi
}

print_connect_hint() {
  echo >&2
  printf '%sConnect:%s  macvs ssh %s\n' "$C_BOLD" "$C_RST" "$VM_NAME" >&2
  printf '          ssh %s-p %s %s\n' "${VM_SSH_IDENTITY:+-i $VM_SSH_IDENTITY }" "$VM_SSH_PORT" "$VM_SSH_DEST" >&2
}

# Guard: remove a half-created VM directory if the command dies before CREATE_DONE=1.
arm_create_cleanup() {
  CREATE_DONE=""
  trap '[ -n "$CREATE_DONE" ] || { err "aborted; removing $VM_DIR"; rm -rf "$VM_DIR"; }' EXIT
}
disarm_create_cleanup() { CREATE_DONE=1; trap - EXIT; }

# ---------------------------------------------------------------------------
cmd_create() {
  local name="" disk="$MACVS_DEFAULT_DISK" want_password="" tz="" release="$MACVS_DEFAULT_RELEASE"
  local variant="$MACVS_DEFAULT_VARIANT" pw pw2 hash identity=""
  init_common_opts
  while [ $# -gt 0 ]; do
    if parse_common_opt "$@"; then shift 2; continue; else case $? in 1) shift; continue ;; esac; fi
    case "$1" in
      -h|--help)  usage_create; return 0 ;;
      --disk)     disk="$2"; shift 2 ;;
      --password) want_password=1; shift ;;
      --timezone) tz="$2"; shift 2 ;;
      --release)  release="$2"; shift 2 ;;
      --variant)  variant="$2"; shift 2 ;;
      -*) die "unknown option for create: $1 (try: macvs create --help)" ;;
      *)  [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { usage_create; die "a VM name is required"; }
  validate_name "$name"
  vm_exists "$name" && die "VM '$name' already exists"
  validate_common_opts
  [[ "$disk" =~ ^[0-9]+[GgMm]$ ]] || die "--disk must look like 25G"

  require_cmd hdiutil; require_cmd nc; require_cmd ssh; require_cmd ssh-keygen
  qemu_detect
  hvf_available || die "Hypervisor.framework not available (kern.hv_support != 1)"
  [ "$OPT_DAEMON" = none ] || launchd_preflight
  resolve_ports

  hash=""
  if [ -n "$want_password" ]; then
    [ -t 0 ] || die "--password needs an interactive terminal"
    printf 'Console password for %s: ' "$OPT_USER" >&2; read -r -s pw; echo >&2
    printf 'Repeat password: ' >&2; read -r -s pw2; echo >&2
    [ "$pw" = "$pw2" ] || die "passwords do not match"
    [ -n "$pw" ] || die "empty password"
    hash="$(password_hash "$pw")" || die "cannot hash password: need an OpenSSL with 'passwd -6' (brew install openssl@3)"
    unset pw pw2
  fi

  image_ensure "$release" "$variant"

  VM_DIR="$(vm_dir "$name")"
  [ -e "$VM_DIR" ] && die "$VM_DIR already exists but has no vm.conf; remove it manually"
  mkdir -p "$VM_DIR/run" "$VM_DIR/logs" "$VM_DIR/ssh" "$VM_DIR/cloud-init"
  chmod 700 "$VM_DIR"
  arm_create_cleanup

  local sshkey="$OPT_SSHKEY"
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
  VM_IMAGE="$IMG_FILE"; VM_IMAGE_SHA512="$IMG_SHA"; VM_CPUS="$OPT_CPUS"; VM_MEMORY="$OPT_MEMORY"
  VM_DISK="$disk"; VM_DISK_CACHE="$OPT_CACHE"; VM_MACHINE=virt; VM_BIND="$OPT_BIND"; VM_SSH_PORT="$OPT_SSH_PORT"
  VM_FORWARDS="$OPT_FORWARDS"; VM_USER="$OPT_USER"; VM_SSH_PUBKEY="$sshkey"; VM_SSH_IDENTITY="$identity"
  VM_TIMEZONE="${tz:-$(host_timezone)}"; VM_PASSWORD_HASH="$hash"; VM_EXTRA_ARGS=""
  VM_PROVISION=cloud-init; VM_BALLOON="$OPT_BALLOON"; VM_AUTOSTART=on; VM_ORIGIN=""; VM_PROFILES=""; VM_SITES=""
  save_vm_conf
  load_vm "$name"

  info "creating ${disk} disk from $IMG_FILE"
  cp -c "$IMG_PATH" "$VM_DISK_PATH" 2>/dev/null || cp "$IMG_PATH" "$VM_DISK_PATH"
  "$MACVS_QEMU_IMG" resize -q "$VM_DISK_PATH" "$disk" || die "qemu-img resize failed"
  chmod 600 "$VM_DISK_PATH"
  cp "$MACVS_FW_VARS" "$VM_NVRAM_PATH"; chmod 600 "$VM_NVRAM_PATH"

  info "building cloud-init seed (user '$OPT_USER', hostname '${name%%.*}')"
  cloudinit_generate

  disarm_create_cleanup
  ok "created $name in $VM_DIR"
  echo
  cmd_status "$name"
  bringup_vm
}

# ---------------------------------------------------------------------------
cmd_import() {
  local name="" src_disk="" src_nvram="" move="" resize="" identity="" pubkey="" vbytes vsize
  init_common_opts
  while [ $# -gt 0 ]; do
    if parse_common_opt "$@"; then shift 2; continue; else case $? in 1) shift; continue ;; esac; fi
    case "$1" in
      -h|--help) usage_import; return 0 ;;
      --disk)    src_disk="$2"; shift 2 ;;
      --nvram)   src_nvram="$2"; shift 2 ;;
      --move)    move=1; shift ;;
      --resize)  resize="$2"; shift 2 ;;
      -*) die "unknown option for import: $1 (try: macvs import --help)" ;;
      *)  [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { usage_import; die "a VM name is required"; }
  validate_name "$name"
  vm_exists "$name" && die "VM '$name' already exists"
  [ -n "$src_disk" ] || die "--disk FILE is required"
  [ -f "$src_disk" ] || die "disk image not found: $src_disk"
  [ -z "$src_nvram" ] || [ -f "$src_nvram" ] || die "NVRAM file not found: $src_nvram"
  [ -z "$resize" ] || [[ "$resize" =~ ^[0-9]+[GgMm]$ ]] || die "--resize must look like 40G"
  validate_common_opts
  require_cmd nc; require_cmd ssh
  qemu_detect
  hvf_available || die "Hypervisor.framework not available (kern.hv_support != 1)"
  [ "$OPT_DAEMON" = none ] || launchd_preflight

  # The image must be qcow2 and not opened by a running QEMU (its lock would make us fail).
  local fmt
  if ! fmt="$("$MACVS_QEMU_IMG" info "$src_disk" 2>&1)"; then
    case "$fmt" in
      *lock*) die "$src_disk is in use by a running VM; shut that VM down first" ;;
      *)      die "qemu-img cannot read $src_disk: $fmt" ;;
    esac
  fi
  printf '%s\n' "$fmt" | grep -q '^file format: qcow2$' \
    || die "$src_disk is not qcow2 (convert first: qemu-img convert -O qcow2 IN OUT)"
  vbytes="$(printf '%s\n' "$fmt" | sed -n 's/^virtual size:.*(\([0-9]*\) bytes).*/\1/p')"
  if [ -n "$vbytes" ] && [ $((vbytes % 1073741824)) -eq 0 ]; then vsize="$((vbytes / 1073741824))G"
  elif [ -n "$vbytes" ]; then vsize="$((vbytes / 1048576))M"; else vsize="unknown"; fi

  if [ -n "$OPT_SSHKEY" ]; then
    [ -f "$OPT_SSHKEY" ] || die "--ssh-key file not found: $OPT_SSHKEY"
    case "$OPT_SSHKEY" in
      *.pub) pubkey="$OPT_SSHKEY"; [ -f "${OPT_SSHKEY%.pub}" ] && identity="${OPT_SSHKEY%.pub}" ;;
      *)     identity="$OPT_SSHKEY"; [ -f "$OPT_SSHKEY.pub" ] && pubkey="$OPT_SSHKEY.pub" ;;
    esac
  fi
  resolve_ports

  VM_DIR="$(vm_dir "$name")"
  [ -e "$VM_DIR" ] && die "$VM_DIR already exists but has no vm.conf; remove it manually"
  mkdir -p "$VM_DIR/run" "$VM_DIR/logs" "$VM_DIR/ssh"
  chmod 700 "$VM_DIR"
  arm_create_cleanup

  VM_NAME="$name"; VM_CREATED="$(now_iso)"; VM_RELEASE=imported; VM_VARIANT=imported
  VM_IMAGE="$(basename "$src_disk")"; VM_IMAGE_SHA512=""; VM_CPUS="$OPT_CPUS"; VM_MEMORY="$OPT_MEMORY"
  VM_DISK="${resize:-$vsize}"; VM_DISK_CACHE="$OPT_CACHE"; VM_MACHINE=virt; VM_BIND="$OPT_BIND"
  VM_SSH_PORT="$OPT_SSH_PORT"; VM_FORWARDS="$OPT_FORWARDS"; VM_USER="$OPT_USER"
  VM_SSH_PUBKEY="$pubkey"; VM_SSH_IDENTITY="$identity"; VM_TIMEZONE=""; VM_PASSWORD_HASH=""
  VM_EXTRA_ARGS=""; VM_PROVISION=none; VM_BALLOON="$OPT_BALLOON"; VM_AUTOSTART=on
  VM_ORIGIN="$(resolve_path "$src_disk")"; VM_PROFILES=""; VM_SITES=""
  save_vm_conf
  load_vm "$name"

  info "cloning $src_disk ($vsize)"
  cp -c "$src_disk" "$VM_DISK_PATH" 2>/dev/null || cp "$src_disk" "$VM_DISK_PATH"
  chmod 600 "$VM_DISK_PATH"
  if [ -n "$resize" ]; then
    info "growing virtual disk to $resize (grow the guest filesystem yourself afterwards)"
    "$MACVS_QEMU_IMG" resize -q "$VM_DISK_PATH" "$resize" || die "qemu-img resize failed"
  fi
  if [ -n "$src_nvram" ]; then
    cp "$src_nvram" "$VM_NVRAM_PATH"
  else
    warn "no --nvram given: using a blank UEFI variable store. Systems installed from an ISO usually" \
         "need their original NVRAM to find GRUB; if it does not boot, re-import with --nvram."
    cp "$MACVS_FW_VARS" "$VM_NVRAM_PATH"
  fi
  chmod 600 "$VM_NVRAM_PATH"

  disarm_create_cleanup
  if [ -n "$move" ]; then
    rm -f "$src_disk"; [ -z "$src_nvram" ] || rm -f "$src_nvram"
    info "removed source files (--move)"
  fi
  ok "imported $name into $VM_DIR"
  echo
  cmd_status "$name"
  bringup_vm
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

cmd_autostart() {
  local name="${1:-}" mode="${2:-}"
  [ -n "$name" ] || die "usage: macvs autostart <name> [on|off]"
  load_vm "$name"
  if [ -z "$mode" ]; then echo "$VM_AUTOSTART"; return 0; fi
  [[ "$mode" =~ ^(on|off)$ ]] || die "usage: macvs autostart <name> [on|off]"
  if [ "$VM_AUTOSTART" = "$mode" ]; then info "autostart for $VM_NAME is already $mode"; return 0; fi
  VM_AUTOSTART="$mode"
  save_vm_conf
  launchd_refresh_plist
  if [ "$mode" = on ]; then ok "$VM_NAME will boot with the Mac and restart after a crash"
  else ok "$VM_NAME will stay off until 'macvs start $VM_NAME' (launchd job kept)"; fi
}

cmd_run() {
  [ $# -eq 1 ] || die "usage: macvs run <name>"
  load_vm "$1"
  vm_run_foreground || exit $?
}

cmd_wait() {
  [ $# -eq 1 ] || die "usage: macvs wait <name>"
  load_vm "$1"
  vm_wait_ssh
  [ "$VM_PROVISION" = cloud-init ] && vm_wait_cloudinit
  return 0
}

cmd_reseed() {
  [ $# -eq 1 ] || die "usage: macvs reseed <name>"
  load_vm "$1"
  [ "$VM_PROVISION" = cloud-init ] || die "$VM_NAME was imported and has no cloud-init seed"
  vm_is_running && die "stop $VM_NAME before reseeding"
  cloudinit_generate
  ok "rebuilt $VM_SEED_PATH (cloud-init will re-run per-instance modules on next boot)"
}

# ---------------------------------------------------------------------------
cmd_status() {
  [ $# -eq 1 ] || die "usage: macvs status <name>"
  load_vm "$1"
  local pid state kind lstate disk_used f prov
  if pid="$(vm_pid)"; then state="${C_GRN}running${C_RST} (pid $pid, up $(vm_uptime "$pid"))"; else state="${C_DIM}stopped${C_RST}"; fi
  kind="$(launchd_kind "$VM_NAME")"
  if [ -n "$kind" ]; then lstate="$(launchd_state "$VM_NAME" || true)"; kind="$kind (${lstate:-not loaded}), autostart $VM_AUTOSTART"
  else kind="none (direct start)"; fi
  disk_used="$(du -h "$VM_DISK_PATH" 2>/dev/null | awk '{print $1}')"
  if [ "$VM_PROVISION" = cloud-init ]; then prov="$VM_IMAGE ($VM_RELEASE), cloud-init"
  else prov="imported from $VM_ORIGIN"; fi
  printf '%s%s%s\n' "$C_BOLD" "$VM_NAME" "$C_RST"
  printf '  state      %b\n' "$state"
  printf '  image      %s\n' "$prov"
  printf '  resources  %s vCPU, %s MiB RAM%s, %s disk (%s used)\n' "$VM_CPUS" "$VM_MEMORY" \
    "$([ "$VM_BALLOON" = on ] && echo ' (balloon)')" "$VM_DISK" "${disk_used:-?}"
  printf '  ssh        %s@%s -p %s\n' "$VM_USER" "$VM_SSH_HOST" "$VM_SSH_PORT"
  for f in $VM_FORWARDS; do
    if forward_needs_relay "${f%%:*}" "$VM_BIND"; then
      printf '  forward    %s:%s -> guest:%s  (relay via %s: %s)\n' "$VM_BIND" "${f%%:*}" "${f##*:}" "$(relay_port "${f%%:*}")" "$(relay_state "${f%%:*}")"
    else
      printf '  forward    %s:%s -> guest:%s\n' "$VM_BIND" "${f%%:*}" "${f##*:}"
    fi
  done
  printf '  bind       %s\n' "$VM_BIND"
  printf '  launchd    %s\n' "$kind"
  if [ -n "$VM_PROFILES" ]; then printf '  profiles   %s\n' "$VM_PROFILES"; fi
  if [ -n "$VM_SITES" ]; then printf '  sites      %s\n' "$VM_SITES"; fi
  printf '  files      %s\n' "$VM_DIR"
}

cmd_list() {
  local d n pid state kind
  printf '%-24s %-9s %-7s %-6s %-5s %-6s %-8s %s\n' NAME STATE PID SSH CPUS MEM LAUNCHD AUTOSTART
  for d in "$MACVS_HOME"/vms/*/; do
    [ -f "$d/vm.conf" ] || continue
    n="$(basename "$d")"
    load_vm "$n"
    if pid="$(vm_pid)"; then state=running; else state=stopped; pid=-; fi
    kind="$(launchd_kind "$n")"
    printf '%-24s %-9s %-7s %-6s %-5s %-6s %-8s %s\n' "$n" "$state" "$pid" "$VM_SSH_PORT" "$VM_CPUS" "$VM_MEMORY" "${kind:--}" "$VM_AUTOSTART"
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
      printf 'kind:       %s\nlabel:      %s\nplist:      %s\nstate:      %s\nautostart:  %s\n' "$kind" "$(launchd_label "$VM_NAME")" \
        "$(launchd_plist_path "$VM_NAME" "$kind")" "$(launchd_state "$VM_NAME" || echo 'not loaded')" "$VM_AUTOSTART"
      for a in $(vm_relayed_ports); do
        printf 'relay:      %s:%s -> %s  %s  (%s)\n' "$VM_BIND" "$a" "$(relay_port "$a")" "$(relay_state "$a")" "$(relay_label "$VM_NAME" "$a")"
      done ;;
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
  local fails=0 r q t o
  check() { # label ok? detail
    if [ "$2" = 0 ]; then printf '  %sok%s   %-30s %s\n' "$C_GRN" "$C_RST" "$1" "$3"
    else printf '  %sFAIL%s %-30s %s\n' "$C_RED" "$C_RST" "$1" "$3"; fails=$((fails + 1)); fi
  }
  note() { printf '  %snote%s %-30s %s\n' "$C_YEL" "$C_RST" "$1" "$2"; }
  echo "macvs doctor"
  [ "$(uname -s)" = Darwin ] && r=0 || r=1; check "macOS" "$r" "$(sw_vers -productVersion 2>/dev/null)"
  [ "$(uname -m)" = arm64 ] && r=0 || r=1; check "Apple Silicon (arm64)" "$r" "$(uname -m)"
  hvf_available && r=0 || r=1; check "Hypervisor.framework" "$r" "kern.hv_support=$(sysctl -n kern.hv_support 2>/dev/null)"
  q="$(command -v qemu-system-aarch64 2>/dev/null || true)"
  [ -n "$q" ] && r=0 || r=1; check "qemu-system-aarch64" "$r" "${q:-missing: brew install qemu} $("$q" --version 2>/dev/null | head -n 1 | awk '{print $4}')"
  command -v qemu-img >/dev/null 2>&1 && r=0 || r=1; check "qemu-img" "$r" "$(command -v qemu-img 2>/dev/null)"
  if [ -n "$q" ]; then
    ( qemu_detect ) >/dev/null 2>&1 && r=0 || r=1
    ( qemu_detect >/dev/null 2>&1; check "UEFI firmware" "$r" "${MACVS_QEMU_SHARE:-not found}" )
  fi
  for t in hdiutil curl shasum ssh ssh-keygen nc plutil launchctl; do
    command -v "$t" >/dev/null 2>&1 && r=0 || r=1; check "$t" "$r" "$(command -v "$t" 2>/dev/null)"
  done
  mkdir -p "$MACVS_HOME" 2>/dev/null && [ -w "$MACVS_HOME" ] && r=0 || r=1; check "MACVS_HOME writable" "$r" "$MACVS_HOME"
  if tcc_protected_path "$MACVS_HOME"; then r=1; else r=0; fi
  check "MACVS_HOME outside TCC folders" "$r" "$MACVS_HOME"
  if tcc_protected_path "$MACVS_BIN_DIR"; then
    check "macvs outside TCC folders" 1 "$MACVS_BIN_DIR (launchd cannot run it here; use ./install.sh)"
  else
    check "macvs outside TCC folders" 0 "$MACVS_BIN_DIR"
  fi
  # Web ports: informational, since only one VM can own them.
  for t in ${MACVS_DEFAULT_WEB_FORWARDS}; do
    t="${t%%:*}"
    if o="$(port_used_by_vm "$t")"; then note "host port $t" "used by VM '$o'"
    elif port_listening "$t"; then note "host port $t" "in use by something else on this Mac; new VMs need --no-web or --forward"
    else note "host port $t" "free"; fi
  done
  note "privileged ports" "on $MACVS_DEFAULT_BIND ports below 1024 are served via launchd relays (bound as $MACVS_RELAY_BASE+port)"
  if password_hash x >/dev/null 2>&1; then check "openssl passwd -6 (optional)" 0 "available for --password"
  else note "openssl passwd -6 (optional)" "brew install openssl@3 to use --password"; fi
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
    import)      cmd_import "$@" ;;
    start)       cmd_start "$@" ;;
    stop)        cmd_stop "$@" ;;
    restart)     cmd_restart "$@" ;;
    autostart)   cmd_autostart "$@" ;;
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
    deploy)      cmd_deploy "$@" ;;
    image)       cmd_image "$@" ;;
    doctor)      cmd_doctor "$@" ;;
    version|--version|-v) echo "macvs $MACVS_VERSION" ;;
    help|--help|-h) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

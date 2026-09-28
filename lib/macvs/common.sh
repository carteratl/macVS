# shellcheck shell=bash
# common.sh - shared helpers for macvs. Written for the bash 3.2 that ships with macOS.

# ---------------------------------------------------------------------------
# Configuration: defaults, overridable from $MACVS_HOME/config (a shell file)
# ---------------------------------------------------------------------------
MACVS_HOME="${MACVS_HOME:-$HOME/.macvs}"

if [ -f "$MACVS_HOME/config" ]; then
  # shellcheck disable=SC1091
  . "$MACVS_HOME/config"
fi

MACVS_DEFAULT_RELEASE="${MACVS_DEFAULT_RELEASE:-trixie}"        # Debian 13
MACVS_DEFAULT_VARIANT="${MACVS_DEFAULT_VARIANT:-generic}"       # generic | genericcloud
MACVS_DEFAULT_CPUS="${MACVS_DEFAULT_CPUS:-2}"
MACVS_DEFAULT_MEMORY="${MACVS_DEFAULT_MEMORY:-2048}"            # MiB
MACVS_DEFAULT_DISK="${MACVS_DEFAULT_DISK:-25G}"
MACVS_DEFAULT_USER="${MACVS_DEFAULT_USER:-admin}"
MACVS_DEFAULT_BIND="${MACVS_DEFAULT_BIND:-127.0.0.1}"           # 127.0.0.1 = this Mac only; 0.0.0.0 = reachable from the LAN
MACVS_DEFAULT_WEB_FORWARDS="${MACVS_DEFAULT_WEB_FORWARDS:-80:80 443:443}"  # added to every VM unless --no-web
MACVS_DEFAULT_DAEMON="${MACVS_DEFAULT_DAEMON:-system}"          # system | agent | none: how create/import register with launchd
MACVS_DEFAULT_SSH_PORT_BASE="${MACVS_DEFAULT_SSH_PORT_BASE:-2222}"
MACVS_DEFAULT_DISK_CACHE="${MACVS_DEFAULT_DISK_CACHE:-writeback}"
MACVS_IMAGE_BASE_URL="${MACVS_IMAGE_BASE_URL:-https://cloud.debian.org/images/cloud}"
MACVS_LAUNCHD_PREFIX="${MACVS_LAUNCHD_PREFIX:-com.carteratl.macvs}"
MACVS_STOP_TIMEOUT="${MACVS_STOP_TIMEOUT:-90}"                  # seconds to wait for ACPI shutdown
MACVS_RELAY_BASE="${MACVS_RELAY_BASE:-40000}"                   # privileged port P is bound as RELAY_BASE+P and relayed
MACVS_SSH_TIMEOUT="${MACVS_SSH_TIMEOUT:-300}"                   # seconds to wait for first SSH

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_BOLD=""; C_RST=""
fi

info() { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
ok()   { printf '%s ok %s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1${2:+ ($2)}"
}

# Resolve symlinks to an absolute path (no readlink -f dependency).
resolve_path() {
  local src="$1" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  printf '%s/%s\n' "$(cd -P "$(dirname "$src")" && pwd)" "$(basename "$src")"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Quote a value for a shell-sourced key=value file.
shell_quote() {
  local s="$1"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  printf '%s' "$s"
}

confirm() {
  local answer
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1" >&2
  read -r answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

host_timezone() {
  local tz
  tz="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
  printf '%s\n' "${tz:-UTC}"
}

find_default_pubkey() {
  local k
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [ -f "$k" ]; then printf '%s\n' "$k"; return 0; fi
  done
  return 1
}

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ---------------------------------------------------------------------------
# VM naming, paths, and per-VM configuration
# ---------------------------------------------------------------------------
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'

validate_name() {
  [[ "$1" =~ $NAME_RE ]] || die "invalid VM name '$1' (letters, digits, dot, dash, underscore; max 40 chars)"
}

vm_dir()    { printf '%s/vms/%s\n' "$MACVS_HOME" "$1"; }
vm_exists() { [ -f "$(vm_dir "$1")/vm.conf" ]; }

require_vm() {
  validate_name "$1"
  vm_exists "$1" || die "no such VM '$1' (see: macvs list)"
}

# Load vm.conf into VM_* variables and derive well-known paths.
load_vm() {
  require_vm "$1"
  VM_DIR="$(vm_dir "$1")"
  # shellcheck disable=SC1090
  . "$VM_DIR/vm.conf"
  : "${VM_NAME:=$1}" "${VM_FORWARDS:=}" "${VM_EXTRA_ARGS:=}" "${VM_MACHINE:=virt}"
  : "${VM_DISK_CACHE:=$MACVS_DEFAULT_DISK_CACHE}" "${VM_BIND:=$MACVS_DEFAULT_BIND}"
  : "${VM_SSH_IDENTITY:=}" "${VM_TIMEZONE:=}" "${VM_PASSWORD_HASH:=}" "${VM_SSH_PUBKEY:=}"
  : "${VM_PROVISION:=cloud-init}" "${VM_BALLOON:=on}" "${VM_AUTOSTART:=on}" "${VM_ORIGIN:=}" "${VM_PROFILES:=}" "${VM_SITES:=}"

  VM_DISK_PATH="$VM_DIR/disk.qcow2"
  VM_NVRAM_PATH="$VM_DIR/nvram.fd"
  VM_SEED_PATH="$VM_DIR/seed.iso"
  VM_RUN_DIR="$VM_DIR/run"
  VM_LOG_DIR="$VM_DIR/logs"
  VM_PIDFILE="$VM_RUN_DIR/qemu.pid"
  VM_QMP_SOCK="$VM_RUN_DIR/qmp.sock"
  VM_CONSOLE_SOCK="$VM_RUN_DIR/console.sock"
  VM_CONSOLE_LOG="$VM_LOG_DIR/console.log"
  VM_QEMU_LOG="$VM_LOG_DIR/qemu.log"
  VM_LAUNCHD_LOG="$VM_LOG_DIR/launchd.log"
  VM_KNOWN_HOSTS="$VM_DIR/ssh/known_hosts"

  case "$VM_BIND" in 0.0.0.0|'') VM_SSH_HOST=127.0.0.1 ;; *) VM_SSH_HOST="$VM_BIND" ;; esac
  VM_SSH_DEST="$VM_USER@$VM_SSH_HOST"

  SSH_OPTS=(-p "$VM_SSH_PORT"
            -o "UserKnownHostsFile=$VM_KNOWN_HOSTS"
            -o StrictHostKeyChecking=accept-new
            -o LogLevel=ERROR)
  if [ -n "$VM_SSH_IDENTITY" ] && [ -f "$VM_SSH_IDENTITY" ]; then
    SSH_OPTS+=(-i "$VM_SSH_IDENTITY" -o IdentitiesOnly=yes)
  fi
}

# Write vm.conf from the current VM_* variables.
save_vm_conf() {
  local f="$VM_DIR/vm.conf" tmp
  tmp="$f.tmp"
  {
    echo "# macvs VM configuration - edit while the VM is stopped; sourced as shell."
    printf 'VM_NAME=%s\n'          "$(shell_quote "$VM_NAME")"
    printf 'VM_CREATED=%s\n'       "$(shell_quote "$VM_CREATED")"
    printf 'VM_RELEASE=%s\n'       "$(shell_quote "$VM_RELEASE")"
    printf 'VM_VARIANT=%s\n'       "$(shell_quote "$VM_VARIANT")"
    printf 'VM_IMAGE=%s\n'         "$(shell_quote "$VM_IMAGE")"
    printf 'VM_IMAGE_SHA512=%s\n'  "$(shell_quote "$VM_IMAGE_SHA512")"
    printf 'VM_CPUS=%s\n'          "$(shell_quote "$VM_CPUS")"
    printf 'VM_MEMORY=%s\n'        "$(shell_quote "$VM_MEMORY")"
    printf 'VM_DISK=%s\n'          "$(shell_quote "$VM_DISK")"
    printf 'VM_DISK_CACHE=%s\n'    "$(shell_quote "$VM_DISK_CACHE")"
    printf 'VM_MACHINE=%s\n'       "$(shell_quote "$VM_MACHINE")"
    printf 'VM_BIND=%s\n'          "$(shell_quote "$VM_BIND")"
    printf 'VM_SSH_PORT=%s\n'      "$(shell_quote "$VM_SSH_PORT")"
    printf 'VM_FORWARDS=%s\n'      "$(shell_quote "$VM_FORWARDS")"
    printf 'VM_USER=%s\n'          "$(shell_quote "$VM_USER")"
    printf 'VM_SSH_PUBKEY=%s\n'    "$(shell_quote "$VM_SSH_PUBKEY")"
    printf 'VM_SSH_IDENTITY=%s\n'  "$(shell_quote "$VM_SSH_IDENTITY")"
    printf 'VM_TIMEZONE=%s\n'      "$(shell_quote "$VM_TIMEZONE")"
    printf 'VM_PASSWORD_HASH=%s\n' "$(shell_quote "$VM_PASSWORD_HASH")"
    printf 'VM_EXTRA_ARGS=%s\n'    "$(shell_quote "$VM_EXTRA_ARGS")"
    printf 'VM_PROVISION=%s\n'     "$(shell_quote "$VM_PROVISION")"
    printf 'VM_BALLOON=%s\n'       "$(shell_quote "$VM_BALLOON")"
    printf 'VM_AUTOSTART=%s\n'     "$(shell_quote "$VM_AUTOSTART")"
    printf 'VM_ORIGIN=%s\n'        "$(shell_quote "$VM_ORIGIN")"
    printf 'VM_PROFILES=%s\n'      "$(shell_quote "$VM_PROFILES")"
    printf 'VM_SITES=%s\n'         "$(shell_quote "$VM_SITES")"
  } > "$tmp"
  mv -f "$tmp" "$f"
}

# ---------------------------------------------------------------------------
# Port helpers
# ---------------------------------------------------------------------------
port_listening() { nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1; }

# Print the name of the VM whose SSH port or forwards use host port $1.
port_used_by_vm() {
  local p="$1" d
  for d in "$MACVS_HOME"/vms/*/; do
    [ -f "$d/vm.conf" ] || continue
    if ( . "$d/vm.conf"
         b="${VM_BIND:-$MACVS_DEFAULT_BIND}"
         for h in "${VM_SSH_PORT:-0}" $(for f in ${VM_FORWARDS:-}; do printf '%s\n' "${f%%:*}"; done); do
           [ "$h" = "$p" ] && exit 0
           forward_needs_relay "$h" "$b" && [ "$(relay_port "$h")" = "$p" ] && exit 0
         done
         exit 1 ); then
      basename "$d"
      return 0
    fi
  done
  return 1
}

# macOS lets non-root processes bind ports below 1024 only on the wildcard address.
# On a specific address (the default 127.0.0.1) QEMU gets EACCES, so such forwards
# are bound on MACVS_RELAY_BASE+port and launchd (which may bind anything) relays
# the real port to it.
forward_needs_relay() { # hostport bind
  [ "$1" -lt 1024 ] && [ "$2" != 0.0.0.0 ]
}
relay_port() { printf '%s\n' $((MACVS_RELAY_BASE + $1)); }

pick_free_port() {
  local p="$1"
  while port_used_by_vm "$p" >/dev/null || port_listening "$p"; do p=$((p + 1)); done
  printf '%s\n' "$p"
}

# Validate a host:guest forward spec and check the host port is free.
# $2 is an optional hint appended to the error message.
check_forward() {
  local spec="$1" hint="${2:-}" h g owner
  h="${spec%%:*}"; g="${spec##*:}"
  [ "$h" != "$spec" ] && is_int "$h" && is_int "$g" || die "bad forward '$spec' (expected HOSTPORT:GUESTPORT)"
  if owner="$(port_used_by_vm "$h")"; then die "host port $h is already assigned to VM '$owner'${hint:+; $hint}"; fi
  port_listening "$h" && die "host port $h is already in use on this Mac${hint:+; $hint}"
  return 0
}

# Merge user forwards with the default web forwards (user entries win per host port).
merge_web_forwards() { # user-forwards-string
  local out="$1" w u dup
  for w in $MACVS_DEFAULT_WEB_FORWARDS; do
    dup=""
    for u in $1; do [ "${u%%:*}" = "${w%%:*}" ] && dup=1; done
    [ -n "$dup" ] || out="$out $w"
  done
  printf '%s\n' "$out"
}

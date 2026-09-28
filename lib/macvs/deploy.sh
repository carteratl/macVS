# shellcheck shell=bash
# deploy.sh - provisioning profiles applied to a running VM over SSH.
#
# A profile is a bash script under share/macvs/deploy/<profile>.sh that runs as
# root inside the guest. macvs sends it over the VM's SSH connection, runs it with
# its parameters in the environment, mirrors the output into the VM's logs
# directory, and records the profile in vm.conf (VM_PROFILES) once it succeeds.
# Profiles are idempotent: running one again reconverges the same state.

MACVS_WEBROOT_PHP="${MACVS_WEBROOT_PHP:-8.5}"            # PHP series from packages.sury.org
MACVS_WEBROOT_SWAP="${MACVS_WEBROOT_SWAP:-2G}"           # guest swapfile, or none
MACVS_WEBROOT_FIREWALL="${MACVS_WEBROOT_FIREWALL:-none}" # none | ufw

deploy_dir()    { printf '%s/share/macvs/deploy\n' "$MACVS_ROOT"; }
deploy_script() { printf '%s/%s.sh\n' "$(deploy_dir)" "$1"; }

usage_deploy() {
  cat <<EOT
Usage: macvs deploy <profile> <name> [options]
       macvs deploy list

Applies a provisioning profile to a running VM over SSH (the guest needs
passwordless sudo, which created VMs have). Profiles converge: run them again
after changing options or to repair the guest.

Profiles:
$(deploy_list | tail -n +2 | sed 's/^/  /')

Try: macvs deploy webroot --help
EOT
}

usage_deploy_webroot() {
  cat <<EOT
Usage: macvs deploy webroot <name> [options]

Turns a running macvs VM into a web server: base tools, security-only unattended
upgrades, swap, Apache 2.4 (event MPM, hardened, compression and caching policy,
default-deny vhost on 80 and 443), PHP-FPM from packages.sury.org, MariaDB on
127.0.0.1, and certbot with an Apache reload hook. It follows the io-server web
stack and leaves the guest ready for a site vhost plus a webroot; it creates no
site, database, or certificate. Safe to re-run.

  --php VERSION        PHP series from packages.sury.org    (default $MACVS_WEBROOT_PHP)
  --swap SIZE|none     Swapfile inside the guest, e.g. 2G   (default $MACVS_WEBROOT_SWAP)
  --firewall ufw|none  Guest firewall                        (default $MACVS_WEBROOT_FIREWALL; see README)
  --no-certbot         Do not install certbot
  --dns-plugin NAME    Also install python3-certbot-dns-NAME (e.g. cloudflare) for DNS-01 challenges
  --timezone TZ        Guest timezone                        (default: the VM's, else this Mac's)
  --print              Show the guest script and its parameters instead of running them
  --example [FQDN]     Print an example site vhost for such a server (no VM needed)
EOT
}

deploy_list() {
  local f n d
  printf '%-10s %s\n' PROFILE DESCRIPTION
  for f in "$(deploy_dir)"/*.sh; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .sh)"
    d="$(sed -n 's/^# macvs-profile: [^ ]* - //p' "$f" | head -n 1)"
    printf '%-10s %s\n' "$n" "$d"
  done
}

# ---------------------------------------------------------------------------
# Shared machinery
# ---------------------------------------------------------------------------
# The guest must be running, reachable, a Debian, and able to sudo without a
# password. Sets GUEST_ID, GUEST_VERSION, GUEST_CODENAME, GUEST_ARCH.
deploy_preflight() {
  local facts
  require_cmd ssh
  vm_is_running || die "$VM_NAME is not running (start it with: macvs start $VM_NAME)"
  if ! vm_ssh true 2>/dev/null; then vm_wait_ssh; fi
  [ "$VM_PROVISION" = cloud-init ] && vm_wait_cloudinit
  # shellcheck disable=SC2016  # the quoted command expands on the guest
  facts="$(vm_ssh '. /etc/os-release 2>/dev/null; printf "%s %s %s %s " "${ID:-?}" "${VERSION_ID:-?}" "${VERSION_CODENAME:-?}" "$(uname -m)"; if sudo -n true 2>/dev/null; then echo sudo-ok; else echo sudo-missing; fi' 2>/dev/null)" \
    || die "cannot run commands in $VM_NAME over SSH as $VM_USER (try: macvs ssh $VM_NAME)"
  # shellcheck disable=SC2086
  set -- $facts
  GUEST_ID="${1:-?}"; GUEST_VERSION="${2:-?}"; GUEST_CODENAME="${3:-?}"; GUEST_ARCH="${4:-?}"
  [ "${5:-}" = sudo-ok ] || die "$VM_USER cannot sudo without a password inside $VM_NAME; profiles need passwordless sudo"
  [ "$GUEST_ID" = debian ] || die "profiles support Debian guests only; $VM_NAME reports '$GUEST_ID'"
  ok "guest: Debian $GUEST_VERSION ($GUEST_CODENAME) $GUEST_ARCH, passwordless sudo for $VM_USER"
}

# Send share/macvs/deploy/<profile>.sh to the guest and run it as root with the
# given KEY=VALUE parameters in its environment. The script arrives on stdin and
# is written to a temp file first, so nothing it runs can swallow its own text.
deploy_run() { # profile [KEY=VALUE...]
  local profile="$1" script log remote envs="" kv rc=0
  shift
  script="$(deploy_script "$profile")"
  [ -f "$script" ] || die "no such profile '$profile' (see: macvs deploy list)"
  for kv in "$@"; do envs="$envs $(shell_quote "$kv")"; done
  mkdir -p "$VM_LOG_DIR"
  log="$VM_LOG_DIR/deploy-$profile.log"
  remote="f=\$(mktemp /tmp/macvs-$profile.XXXXXX) && cat > \"\$f\" && sudo -n env$envs bash \"\$f\"; rc=\$?; rm -f \"\$f\"; exit \$rc"
  printf '%s ===== macvs %s deploy %s: %s =====\n' "$(now_iso)" "$MACVS_VERSION" "$profile" "$*" >> "$log"
  info "running profile '$profile' inside $VM_NAME as root (output also in $log)"
  echo >&2
  # Output is mirrored with tee (no process substitution: bash 3.2 would wait on it).
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 \
      "$VM_SSH_DEST" "$remote" < "$script" 2>&1 | tee -a "$log" || rc=$?
  return "$rc"
}

deploy_record_profile() { # profile
  case " $VM_PROFILES " in
    *" $1 "*) ;;
    *) VM_PROFILES="${VM_PROFILES:+$VM_PROFILES }$1"; save_vm_conf ;;
  esac
}

# ---------------------------------------------------------------------------
# webroot
# ---------------------------------------------------------------------------
deploy_webroot_example() { # fqdn php
  sed -e "s/SITE_FQDN/$1/g" -e "s/PHP_VERSION/$2/g" "$(deploy_dir)/webroot-example-vhost.conf"
}

deploy_webroot() {
  local name="" php="$MACVS_WEBROOT_PHP" swap="$MACVS_WEBROOT_SWAP" firewall="$MACVS_WEBROOT_FIREWALL"
  local certbot=yes dns_plugin="" tz="" print="" example="" f g ports="22" p script
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)     usage_deploy_webroot; return 0 ;;
      --php)         php="$2"; shift 2 ;;
      --swap)        swap="$2"; shift 2 ;;
      --firewall)    firewall="$2"; shift 2 ;;
      --no-certbot)  certbot=no; shift ;;
      --dns-plugin)  dns_plugin="$2"; shift 2 ;;
      --timezone)    tz="$2"; shift 2 ;;
      --print)       print=1; shift ;;
      --example)     example=1; shift ;;
      -*) die "unknown option for deploy webroot: $1 (try: macvs deploy webroot --help)" ;;
      *)  [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [[ "$php" =~ ^[0-9]+\.[0-9]+$ ]] || die "--php must look like 8.5"
  [[ "$swap" =~ ^([0-9]+[GgMm]|none)$ ]] || die "--swap must look like 2G, or be none"
  [[ "$firewall" =~ ^(none|ufw)$ ]] || die "--firewall must be ufw or none"
  [ -z "$dns_plugin" ] || [[ "$dns_plugin" =~ ^[a-z0-9-]+$ ]] || die "--dns-plugin must be a certbot DNS plugin name such as cloudflare"

  if [ -n "$example" ]; then
    deploy_webroot_example "${name:-site.example}" "$php"
    return 0
  fi
  [ -n "$name" ] || { usage_deploy_webroot; die "a VM name is required"; }
  load_vm "$name"
  [ -n "$tz" ] || tz="${VM_TIMEZONE:-$(host_timezone)}"

  # A guest firewall may only admit the guest ports macvs forwards (plus SSH).
  for f in $VM_FORWARDS; do
    g="${f##*:}"
    case " $ports " in *" $g "*) ;; *) ports="$ports $g" ;; esac
  done
  # shellcheck disable=SC2086
  ports="$(printf '%s\n' $ports | sort -n | uniq | tr '\n' ' ' | sed 's/ *$//')"

  set -- "MACVS_WEBROOT_PHP=$php" "MACVS_WEBROOT_SWAP=$swap" "MACVS_WEBROOT_FIREWALL=$firewall" \
         "MACVS_WEBROOT_UFW_PORTS=$ports" "MACVS_WEBROOT_CERTBOT=$certbot" "MACVS_WEBROOT_DNS_PLUGIN=$dns_plugin" \
         "MACVS_WEBROOT_TIMEZONE=$tz" "MACVS_WEBROOT_VERSION=$MACVS_VERSION"

  if [ -n "$print" ]; then
    script="$(deploy_script webroot)"
    printf '# would run inside %s as root, with:\n' "$VM_NAME"
    for p in "$@"; do printf '#   %s\n' "$p"; done
    printf '# --- %s ---\n' "$script"
    cat "$script"
    return 0
  fi

  deploy_preflight
  if [ "$firewall" = ufw ]; then
    info "guest firewall: ufw will allow tcp ${ports// /, } (SSH plus this VM's forwarded guest ports)"
  fi
  if ! deploy_run webroot "$@"; then
    echo >&2
    die "the webroot profile failed in $VM_NAME; see the output above and $VM_LOG_DIR/deploy-webroot.log"
  fi
  deploy_record_profile webroot

  echo >&2
  ok "$VM_NAME is a web server (profiles: $VM_PROFILES)"
  cat >&2 <<EOT

Next steps
  Add a site:    macvs deploy webroot --example your.site.tld > site.conf   (an Apache vhost to copy in)
                 webroot goes in /var/www/<site>/htdocs; vhosts in /etc/apache2/sites-available
  Certificate:   inside the guest: certbot certonly --dns-<provider> -d your.site.tld  (DNS-01, no inbound needed)
  Database:      macvs ssh $VM_NAME sudo mariadb    (127.0.0.1:3306 and the unix socket only)
  Reach it:      $(for f in $VM_FORWARDS; do printf 'http%s://%s:%s ' "$([ "${f##*:}" = 443 ] && echo s)" "$VM_SSH_HOST" "${f%%:*}"; done)(default vhost answers 403 until a site claims its name)
  Re-run:        macvs deploy webroot $VM_NAME    (converges; add --firewall ufw, --php, --swap to change settings)
EOT
}

# ---------------------------------------------------------------------------
cmd_deploy() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    webroot)        deploy_webroot "$@" ;;
    list|ls)        deploy_list ;;
    ""|-h|--help)   usage_deploy ;;
    *)              die "unknown profile '$sub' (see: macvs deploy list)" ;;
  esac
}

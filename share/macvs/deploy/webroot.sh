#!/bin/bash
# macvs-profile: webroot - Apache 2.4 (event MPM), PHP-FPM from packages.sury.org, and MariaDB, ready for a vhost and a webroot
#
# This script runs INSIDE the guest as root; `macvs deploy webroot <vm>` sends it
# over SSH. It ports the base-OS and web-stack layers of the io-server project
# (playbooks 10-base-os and 30-web-stack) to a single idempotent bash run:
# re-running it converges the same state and restarts a service only when its
# managed configuration actually changed.
#
# What it leaves behind: Debian sources plus the Sury PHP repository (signing key
# fingerprint verified), the base tool set, security-only unattended upgrades, a
# swapfile, locale and timezone, Apache with a reviewed module set, hardening and
# compression/caching policy and a default-deny vhost on 80 and 443, PHP-FPM with
# the io resource settings and the packaged `www` pool on the standard socket,
# MariaDB bound to 127.0.0.1, certbot with an Apache reload hook, and a record of
# it all in /etc/macvs/webroot.env. No site, database, or certificate is created.
#
# Parameters arrive as environment variables (defaults shown):
#   MACVS_WEBROOT_PHP=8.5             PHP series to install from packages.sury.org
#   MACVS_WEBROOT_SWAP=2G             swapfile size (e.g. 1G, 2048M) or "none"
#   MACVS_WEBROOT_FIREWALL=none       "ufw" installs UFW allowing only MACVS_WEBROOT_UFW_PORTS
#   MACVS_WEBROOT_UFW_PORTS="22 80 443"
#   MACVS_WEBROOT_CERTBOT=yes         "no" skips certbot
#   MACVS_WEBROOT_DNS_PLUGIN=         e.g. cloudflare -> also installs python3-certbot-dns-cloudflare
#   MACVS_WEBROOT_TIMEZONE=           set the guest timezone (empty = leave it alone)
#   MACVS_WEBROOT_LOCALE=en_US.UTF-8
#   MACVS_WEBROOT_VERSION=            macvs version, recorded in /etc/macvs/webroot.env
set -euo pipefail

PHP="${MACVS_WEBROOT_PHP:-8.5}"
SWAP="${MACVS_WEBROOT_SWAP:-2G}"
FIREWALL="${MACVS_WEBROOT_FIREWALL:-none}"
UFW_PORTS="${MACVS_WEBROOT_UFW_PORTS:-22 80 443}"
CERTBOT="${MACVS_WEBROOT_CERTBOT:-yes}"
DNS_PLUGIN="${MACVS_WEBROOT_DNS_PLUGIN:-}"
TIMEZONE="${MACVS_WEBROOT_TIMEZONE:-}"
LOCALE="${MACVS_WEBROOT_LOCALE:-en_US.UTF-8}"
MACVS_VERSION="${MACVS_WEBROOT_VERSION:-unknown}"

SURY_REPO="https://packages.sury.org/php/"
SURY_KEYRING_URL="https://packages.sury.org/debsuryorg-archive-keyring.deb"
SURY_FINGERPRINT="15058500A0235D97F5D10063B188E2B695BD4743"
DEBIAN_MIRROR="https://deb.debian.org/debian"
DEBIAN_SECURITY_MIRROR="https://security.debian.org/debian-security"

LOG=/var/log/macvs-webroot.log
STATE_DIR=/etc/macvs
CACHE_DIR=/var/cache/macvs
GUARD=/usr/sbin/policy-rc.d

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a LC_ALL=C.UTF-8
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o Dpkg::Progress-Fancy=0 --no-install-recommends)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
say()  { printf '==> %s\n' "$*"; }
ok()   { printf ' ok  %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Run a noisy command, keeping its output in $LOG; show the tail if it fails.
run() {
  printf '%s $ %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"
  if ! "$@" >> "$LOG" 2>&1; then
    printf 'error: command failed: %s\n--- last lines of %s ---\n' "$*" "$LOG" >&2
    tail -n 40 "$LOG" >&2
    exit 1
  fi
}

apt_install() { run apt-get install "${APT_OPTS[@]}" "$@"; }
apt_update()  { run apt-get update -q; }
pkg_installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ]; }

# write_file DEST MODE  (content on stdin). Returns 0 if the file changed, 1 if it
# was already identical. Callers must use it in an `if`, never as `write_file && x=1`.
write_file() {
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
  mkdir -p "$(dirname "$dest")"
  install -o root -g root -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  return 0
}

# set_kv FILE KEY VALUE [SEP]: replace an existing (possibly commented) `KEY = VALUE`
# line, or append one. Returns 0 if the file changed.
set_kv() {
  local file="$1" key="$2" value="$3" sep="${4:- = }" before after esc
  esc="$(printf '%s' "$key" | sed 's/[.[\*^$]/\\&/g')"
  before="$(md5sum < "$file")"
  if grep -qE "^[[:space:];#]*${esc}[[:space:]]*=" "$file"; then
    sed -i -E "0,/^[[:space:];#]*${esc}[[:space:]]*=.*/s//${key}${sep}${value}/" "$file"
  else
    printf '%s%s%s\n' "$key" "$sep" "$value" >> "$file"
  fi
  after="$(md5sum < "$file")"
  [ "$before" != "$after" ]
}

# Package-install guard: nothing a package postinst starts may run before its
# managed configuration exists (Debian's invoke-rc.d honours policy-rc.d).
guard_on()  { printf '#!/bin/sh\n# macvs deploy webroot: temporary package service-start guard\nexit 101\n' > "$GUARD"; chmod 755 "$GUARD"; }
guard_off() { rm -f "$GUARD"; }

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || fail "must run as root"
[ -r /etc/os-release ] || fail "/etc/os-release missing"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = debian ] || fail "this profile supports Debian only (found ${PRETTY_NAME:-unknown})"
case "${VERSION_CODENAME:-}" in
  trixie) ;;
  bookworm) note "Debian 12 detected; this profile is tested on Debian 13 (trixie)" ;;
  *) fail "unsupported Debian release '${VERSION_CODENAME:-?}' (need trixie or bookworm)" ;;
esac
CODENAME="$VERSION_CODENAME"
[[ "$PHP" =~ ^[0-9]+\.[0-9]+$ ]] || fail "MACVS_WEBROOT_PHP must look like 8.5"
[[ "$SWAP" =~ ^([0-9]+[GgMm]|none)$ ]] || fail "MACVS_WEBROOT_SWAP must look like 2G or be 'none'"
[[ "$FIREWALL" =~ ^(none|ufw)$ ]] || fail "MACVS_WEBROOT_FIREWALL must be none or ufw"
[[ "$CERTBOT" =~ ^(yes|no)$ ]] || fail "MACVS_WEBROOT_CERTBOT must be yes or no"
[ -z "$DNS_PLUGIN" ] || [[ "$DNS_PLUGIN" =~ ^[a-z0-9-]+$ ]] || fail "MACVS_WEBROOT_DNS_PLUGIN must be a plugin name such as cloudflare"

if [ -e "$GUARD" ] && ! grep -q 'macvs deploy webroot' "$GUARD" 2>/dev/null; then
  fail "$GUARD already exists and is not ours; review it before installing packages"
fi
trap 'guard_off' EXIT
trap 'printf "error: unexpected failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

mkdir -p "$STATE_DIR" "$CACHE_DIR" "$(dirname "$LOG")"
touch "$LOG"; chmod 600 "$LOG"
printf '%s ===== macvs deploy webroot (macvs %s) on %s =====\n' "$(date -u +%FT%TZ)" "$MACVS_VERSION" "$(hostname -f 2>/dev/null || hostname)" >> "$LOG"

# Size the stack from guest memory, following io-server's role policy
# (io = 4 GB host, studio = 1 GB host). Anything at or above 3.5 GB gets the
# larger column; the default 2 GiB macvs VM gets the smaller one.
MEM_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
if [ "$MEM_MB" -ge 3500 ]; then
  SIZE=large; DB_BUFFER_POOL=512M; DB_MAX_CONN=40; FPM_PROCESS_MAX=12; OPCACHE_MEM=256; FPM_MAX_CHILDREN=6
else
  SIZE=small; DB_BUFFER_POOL=256M; DB_MAX_CONN=30; FPM_PROCESS_MAX=6;  OPCACHE_MEM=128; FPM_MAX_CHILDREN=4
fi

say "webroot profile on $PRETTY_NAME ($(uname -m), ${MEM_MB} MB RAM -> '$SIZE' sizing), PHP $PHP, swap $SWAP, firewall $FIREWALL, certbot $CERTBOT"
note "full command output is kept in $LOG"

# ---------------------------------------------------------------------------
# 1. APT sources: Debian (deb822) and Sury PHP with a verified signing key
# ---------------------------------------------------------------------------
say "apt sources"
apt_update
apt_install ca-certificates curl debian-archive-keyring gnupg lsb-release wget

if write_file /etc/apt/sources.list.d/debian.sources 0644 <<EOT
# Managed by macvs deploy webroot (ported from io-server roles/apt_sources)
Types: deb
URIs: $DEBIAN_MIRROR
Suites: $CODENAME $CODENAME-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $DEBIAN_SECURITY_MIRROR
Suites: $CODENAME-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT
then ok "wrote /etc/apt/sources.list.d/debian.sources"; fi

# Neutralise a legacy one-line sources.list so nothing competes with the deb822 file.
if [ -f /etc/apt/sources.list ] && grep -qE '^[[:space:]]*deb' /etc/apt/sources.list; then
  cp -a /etc/apt/sources.list "/etc/apt/sources.list.macvs-$(date -u +%Y%m%dT%H%M%SZ)"
  note "kept a copy of the previous /etc/apt/sources.list"
fi
write_file /etc/apt/sources.list 0644 <<'EOT' || true
# Managed by macvs deploy webroot. Active repositories live in /etc/apt/sources.list.d/.
EOT

keyring=/usr/share/keyrings/debsuryorg-archive-keyring.gpg
if ! pkg_installed debsuryorg-archive-keyring; then
  run curl -fsSL --retry 3 -o "$CACHE_DIR/debsuryorg-archive-keyring.deb" "$SURY_KEYRING_URL"
  run dpkg -i "$CACHE_DIR/debsuryorg-archive-keyring.deb"
fi
[ -f "$keyring" ] || fail "Sury keyring not found at $keyring after installing its package"
if ! gpg --batch --no-options --homedir "$(mktemp -d)" --show-keys --with-colons "$keyring" 2>/dev/null \
     | grep -E "^fpr:+${SURY_FINGERPRINT}:" >/dev/null; then
  fail "the installed Sury keyring does not carry the expected signing key $SURY_FINGERPRINT"
fi
ok "Sury signing key verified ($SURY_FINGERPRINT)"

sury_changed=""
if write_file /etc/apt/sources.list.d/php-sury.sources 0644 <<EOT
# Managed by macvs deploy webroot
Types: deb
URIs: $SURY_REPO
Suites: $CODENAME
Components: main
Signed-By: $keyring
EOT
then sury_changed=1; fi
if write_file /etc/apt/preferences.d/php-sury 0644 <<EOT
# Managed by macvs deploy webroot: PHP $PHP comes from packages.sury.org, everything else from Debian.
Package: php${PHP}*
Pin: origin packages.sury.org
Pin-Priority: 700
EOT
then sury_changed=1; fi
[ -z "$sury_changed" ] || apt_update
if ! apt-cache policy "php${PHP}-fpm" | grep packages.sury.org >/dev/null; then
  fail "php${PHP}-fpm is not offered by packages.sury.org for $CODENAME on $(uname -m)"
fi
if apt-cache policy apache2 mariadb-server | grep packages.sury.org >/dev/null; then
  fail "apache2 or mariadb-server would come from packages.sury.org; refusing (only PHP should)"
fi
ok "php${PHP} candidates come from packages.sury.org; Apache and MariaDB from Debian"

# ---------------------------------------------------------------------------
# 2. Base operating system
# ---------------------------------------------------------------------------
say "base packages, updates policy, locale, timezone"
apt_install acl bind9-dnsutils ca-certificates cron curl debian-archive-keyring file gawk git \
  gnupg htop jq less locales logrotate lsb-release lsof nano needrestart openssh-server psmisc \
  rsync ssl-cert sudo tzdata unattended-upgrades unzip wget xz-utils zip zstd
ok "base packages present"

# needrestart: restart services automatically during unattended package runs.
write_file /etc/needrestart/conf.d/50-macvs.conf 0644 <<'EOT' || true
# Managed by macvs deploy webroot: never prompt, restart services as needed.
$nrconf{restart} = 'a';
EOT

if write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOT'
// Managed by macvs deploy webroot (ported from io-server roles/base_os)
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOT
then ok "apt periodic schedule"; fi
if write_file /etc/apt/apt.conf.d/52macvs-unattended-upgrades 0644 <<EOT
// Managed by macvs deploy webroot (ported from io-server roles/base_os)
// Only Debian security updates are applied unattended; Sury and ordinary
// Debian updates wait for you. No automatic reboot.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${CODENAME}-security,label=Debian-Security";
};

Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
EOT
then ok "security-only unattended upgrades"; fi
run systemctl enable --now apt-daily.timer apt-daily-upgrade.timer cron.service

if ! locale -a 2>/dev/null | grep -qi "^$(printf '%s' "$LOCALE" | sed 's/UTF-8/utf8/')$"; then
  sed -i -E "s/^#?[[:space:]]*(${LOCALE}[[:space:]]+UTF-8)[[:space:]]*$/\1/" /etc/locale.gen
  grep -qE "^${LOCALE}[[:space:]]+UTF-8" /etc/locale.gen || printf '%s UTF-8\n' "$LOCALE" >> /etc/locale.gen
  run locale-gen
  ok "generated locale $LOCALE"
fi
if set_kv /etc/default/locale LANG "$LOCALE" "="; then ok "LANG=$LOCALE"; fi
if [ -n "$TIMEZONE" ]; then
  current_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
  if [ "$current_tz" != "$TIMEZONE" ]; then run timedatectl set-timezone "$TIMEZONE"; ok "timezone $TIMEZONE"; fi
fi

# ---------------------------------------------------------------------------
# 3. Swap (ported from io-server roles/swap; size is a parameter here)
# ---------------------------------------------------------------------------
if [ "$SWAP" != none ]; then
  say "swapfile $SWAP, swappiness 10"
  case "$SWAP" in
    *[Gg]) swap_bytes=$(( ${SWAP%[Gg]} * 1073741824 )) ;;
    *[Mm]) swap_bytes=$(( ${SWAP%[Mm]} * 1048576 )) ;;
  esac
  if [ -e /swapfile ]; then
    [ -f /swapfile ] || fail "/swapfile exists but is not a regular file"
    have=$(stat -c %s /swapfile)
    if [ "$have" != "$swap_bytes" ]; then
      note "/swapfile is $have bytes, want $swap_bytes; recreating it"
      swapoff /swapfile 2>/dev/null || true
      rm -f /swapfile
    fi
  fi
  if [ ! -f /swapfile ]; then
    run fallocate --length "$swap_bytes" /swapfile
    chmod 600 /swapfile
    run mkswap /swapfile
  fi
  chown root:root /swapfile; chmod 600 /swapfile
  [ "$(blkid -p -s TYPE -o value /swapfile 2>/dev/null)" = swap ] || run mkswap /swapfile
  grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  swapon --show=NAME --noheadings | grep -qx /swapfile || run swapon /swapfile
  write_file /etc/sysctl.d/99-macvs-swap.conf 0644 <<'EOT' || true
# Managed by macvs deploy webroot (ported from io-server roles/swap)
vm.swappiness = 10
EOT
  [ "$(sysctl -n vm.swappiness)" = 10 ] || run sysctl -w vm.swappiness=10
  ok "swap active: $(swapon --show=NAME,SIZE --noheadings | grep /swapfile | tr -s ' ')"
else
  say "swap: none requested"
fi

# ---------------------------------------------------------------------------
# 4. Apache 2.4, event MPM (ported from io-server roles/apache)
# ---------------------------------------------------------------------------
say "Apache 2.4 (mpm_event)"
apache_changed=""
guard_on
apt_install apache2
guard_off

# The reviewed io module set plus authz_host (so a vhost may use `Require ip`)
# and reqtimeout (slow-request protection). Everything else Debian enables by
# default is switched off.
APACHE_MODULES="alias authz_core authz_host brotli deflate dir env expires filter headers http2 mime mpm_event proxy proxy_fcgi reqtimeout rewrite setenvif socache_shmcb ssl"
for link in /etc/apache2/mods-enabled/*.load; do
  [ -e "$link" ] || continue
  m="$(basename "$link" .load)"
  case " $APACHE_MODULES " in *" $m "*) ;; *) run a2dismod -q -f "$m"; apache_changed=1; note "disabled module $m" ;; esac
done
for m in $APACHE_MODULES; do
  if [ ! -e "/etc/apache2/mods-enabled/$m.load" ]; then run a2enmod -q "$m"; apache_changed=1; note "enabled module $m"; fi
done

for link in /etc/apache2/conf-enabled/*.conf; do
  [ -e "$link" ] || continue
  c="$(basename "$link" .conf)"
  case "$c" in macvs-security|macvs-wordpress-optimization) ;; *) run a2disconf -q "$c"; apache_changed=1; note "disabled conf $c" ;; esac
done
for link in /etc/apache2/sites-enabled/*.conf; do
  [ -e "$link" ] || continue
  s="$(basename "$link" .conf)"
  case "$s" in 000-default|default-ssl) run a2dissite -q "$s"; apache_changed=1; note "disabled site $s" ;; esac
done

if write_file /etc/apache2/ports.conf 0644 <<'EOT'
# Managed by macvs deploy webroot.
# 443 is served by the default-deny vhost (self-signed) until a site vhost with a
# real certificate claims its name; both are in sites-available.
Listen 80
Listen 443
EOT
then apache_changed=1; fi

if write_file /etc/apache2/conf-available/macvs-security.conf 0644 <<'EOT'
# Managed by macvs deploy webroot (ported from io-server roles/apache io-security.conf)

# A global name so apache2ctl stops warning about the FQDN; vhosts set their own.
ServerName localhost
ServerTokens Prod
ServerSignature Off
TraceEnable Off

Header always set X-Robots-Tag "noindex, nofollow, noarchive"
Header always set X-Content-Type-Options "nosniff"
Header always unset X-Powered-By

<IfModule mod_ssl.c>
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLHonorCipherOrder off
</IfModule>

# Never route or serve Git metadata, including nested wp-content.
<LocationMatch "(?i)(^|/)\.git(?:/|$)">
    Require all denied
</LocationMatch>

<DirectoryMatch "(?i)(^|/)\.git(?:/|$)">
    Require all denied
</DirectoryMatch>

# Debian's apache2.conf gives /var/www/ Options Indexes FollowSymLinks. Sites live
# in /var/www/<name>/htdocs owned by their own user; a link is followed only to a
# target its owner also owns, and no directory is listed. Set AllowOverride in a
# site's own <Directory> block if it needs .htaccess.
<Directory /var/www/>
    Options SymLinksIfOwnerMatch
    AllowOverride None
</Directory>
EOT
then apache_changed=1; fi

# Compression (Brotli preferred, gzip fallback) and static caching policy.
# Regex alternation of the compressible MIME types ('+' escaped; '#' delimits the match below).
compress_types='application/atom\+xml|application/javascript|application/json|application/ld\+json|application/manifest\+json|application/rss\+xml|application/xml|font/otf|font/ttf|image/svg\+xml|text/calendar|text/css|text/csv|text/html|text/javascript|text/plain|text/vcard|text/xml'
if write_file /etc/apache2/conf-available/macvs-wordpress-optimization.conf 0644 <<EOT
# Managed by macvs deploy webroot (ported from io-server roles/apache io-wordpress-optimization.conf)

# mod_filter evaluates providers in declaration order. Brotli is selected when
# the client accepts it; gzip is eligible only when acceptable Brotli is absent.
FilterDeclare MACVS_COMPRESS CONTENT_SET
FilterProvider MACVS_COMPRESS BROTLI_COMPRESS "%{CONTENT_TYPE} =~ m#^(?:${compress_types})(?:[[:space:]]*;|\$)#i && %{req:Accept-Encoding} =~ m#(?:^|,)[[:space:]]*br(?:[[:space:]]*;[[:space:]]*q=(?:1(?:\\.0+)?|0?\\.[0-9]*[1-9][0-9]*))?[[:space:]]*(?:,|\$)#i"
FilterProvider MACVS_COMPRESS DEFLATE "%{CONTENT_TYPE} =~ m#^(?:${compress_types})(?:[[:space:]]*;|\$)#i && %{req:Accept-Encoding} !~ m#(?:^|,)[[:space:]]*br(?:[[:space:]]*;[[:space:]]*q=(?:1(?:\\.0+)?|0?\\.[0-9]*[1-9][0-9]*))?[[:space:]]*(?:,|\$)#i && %{req:Accept-Encoding} =~ m#(?:^|,)[[:space:]]*gzip(?:[[:space:]]*;[[:space:]]*q=(?:1(?:\\.0+)?|0?\\.[0-9]*[1-9][0-9]*))?[[:space:]]*(?:,|\$)#i"
FilterChain MACVS_COMPRESS

ExpiresActive Off

# styles-and-scripts
<FilesMatch "(?i)\\.(?:css|js|mjs|map)\$">
    ExpiresActive On
    ExpiresDefault "access plus 7 days"
    Header always set Cache-Control "public, max-age=604800"
</FilesMatch>

# fonts
<FilesMatch "(?i)\\.(?:eot|otf|ttf|woff|woff2)\$">
    ExpiresActive On
    ExpiresDefault "access plus 30 days"
    Header always set Cache-Control "public, max-age=2592000"
</FilesMatch>

# images-and-media
<FilesMatch "(?i)\\.(?:avif|gif|ico|jpe?g|png|svg|webp)\$">
    ExpiresActive On
    ExpiresDefault "access plus 30 days"
    Header always set Cache-Control "public, max-age=2592000"
</FilesMatch>

# fingerprinted-static-assets
<FilesMatch "(?i)\\.[0-9a-f]{8,}\\.(?:avif|css|gif|ico|jpe?g|js|mjs|otf|png|svg|ttf|webp|woff2?)\$">
    ExpiresActive On
    ExpiresDefault "access plus 1 year"
    Header always set Cache-Control "public, max-age=31536000, immutable"
</FilesMatch>

# Dynamic PHP responses are never assigned shared static-cache semantics.
<FilesMatch "(?i)\\.(?:php|phtml|phar)\$">
    ExpiresActive Off
    Header unset Expires
    Header always unset Expires
    Header unset Cache-Control
    Header always set Cache-Control "private, no-store"
</FilesMatch>

# WordPress administration, authentication, API, XML-RPC, and feed paths are
# explicitly non-cacheable even when a path ends in a normally static suffix.
<LocationMatch "(?i)^/(?:wp-admin(?:/|\$)|wp-login\\.php(?:/|\$)|wp-signup\\.php(?:/|\$)|wp-register\\.php(?:/|\$)|xmlrpc\\.php(?:/|\$)|wp-json(?:/|\$)|index\\.php/wp-json(?:/|\$)|feed(?:/|\$)|comments/feed(?:/|\$)|.*/feed(?:/|\$))">
    ExpiresActive Off
    Header unset Expires
    Header always unset Expires
    Header unset Cache-Control
    Header always set Cache-Control "private, no-store"
</LocationMatch>
EOT
then apache_changed=1; fi

[ -f /etc/ssl/certs/ssl-cert-snakeoil.pem ] || run make-ssl-cert generate-default-snakeoil
if write_file /etc/apache2/sites-available/000-macvs-default-deny.conf 0644 <<'EOT'
# Managed by macvs deploy webroot (ported from io-server roles/apache 000-io-default-deny.conf)
# The catch-all for any name no site vhost claims: no document root, always 403.
# Sorting first makes it Apache's default vhost on both ports.

<VirtualHost *:80>
    ServerName default.invalid

    Header always set X-Robots-Tag "noindex, nofollow, noarchive"
    Header always set Cache-Control "private, no-store"

    <Location "/">
        Require all denied
    </Location>

    ErrorLog ${APACHE_LOG_DIR}/macvs-default-deny_error.log
    CustomLog ${APACHE_LOG_DIR}/macvs-default-deny_access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName default.invalid
    Protocols h2 http/1.1

    # Self-signed placeholder so unknown names get a clean TLS 403 instead of a
    # handshake against some site's certificate. Site vhosts bring their own.
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/ssl-cert-snakeoil.pem
    SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key

    Header always set X-Robots-Tag "noindex, nofollow, noarchive"
    Header always set Cache-Control "private, no-store"

    <Location "/">
        Require all denied
    </Location>

    ErrorLog ${APACHE_LOG_DIR}/macvs-default-deny-tls_error.log
    CustomLog ${APACHE_LOG_DIR}/macvs-default-deny-tls_access.log combined
</VirtualHost>
EOT
then apache_changed=1; fi

for c in macvs-security macvs-wordpress-optimization; do
  if [ ! -e "/etc/apache2/conf-enabled/$c.conf" ]; then run a2enconf -q "$c"; apache_changed=1; fi
done
if [ ! -e /etc/apache2/sites-enabled/000-macvs-default-deny.conf ]; then run a2ensite -q 000-macvs-default-deny; apache_changed=1; fi
mkdir -p /var/www; chmod 755 /var/www

run apache2ctl -t
if [ -n "$apache_changed" ] || ! systemctl is-active -q apache2; then
  run systemctl enable apache2
  run systemctl restart apache2
  ok "Apache restarted with the managed configuration"
else
  ok "Apache configuration unchanged"
fi

# ---------------------------------------------------------------------------
# 5. PHP-FPM from Sury (ported from io-server roles/php_fpm)
# ---------------------------------------------------------------------------
say "PHP $PHP FPM"
php_changed=""
guard_on
apt_install "php${PHP}" "php${PHP}-cli" "php${PHP}-common" "php${PHP}-fpm" "php${PHP}-mysql" "php${PHP}-xml" \
  "php${PHP}-gd" "php${PHP}-curl" "php${PHP}-mbstring" "php${PHP}-zip" "php${PHP}-intl"
guard_off
for p in "libapache2-mod-php${PHP}" libapache2-mod-fcgid; do
  if pkg_installed "$p"; then run apt-get purge "${APT_OPTS[@]}" "$p"; note "removed $p (PHP runs through FPM only)"; fi
done

fpm_dir="/etc/php/${PHP}/fpm"
[ -d "$fpm_dir" ] || fail "$fpm_dir not found after installing php${PHP}-fpm"
if set_kv "$fpm_dir/php-fpm.conf" process.max "$FPM_PROCESS_MAX"; then php_changed=1; fi
if write_file "$fpm_dir/conf.d/99-macvs-wordpress.ini" 0644 <<'EOT'
; Managed by macvs deploy webroot (ported from io-server roles/php_fpm 99-io-wordpress.ini)

upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
expose_php = Off
EOT
then php_changed=1; fi
if write_file "$fpm_dir/conf.d/99-macvs-opcache.ini" 0644 <<EOT
; Managed by macvs deploy webroot (ported from io-server roles/php_fpm 99-io-opcache.ini)

opcache.enable = 1
opcache.memory_consumption = $OPCACHE_MEM
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 0
opcache.jit = "off"
EOT
then php_changed=1; fi

# io-server removes the packaged pool and creates one pool per site user. This
# profile stops one step earlier: the www pool stays, tuned with io's pool
# policy, on the standard socket, so a dropped-in vhost works right away.
if write_file "$fpm_dir/pool.d/www.conf" 0644 <<EOT
; Managed by macvs deploy webroot (pool tuning ported from io-server roles/php_fpm site-pool.conf).
; Add a pool per site under pool.d/ (own user, own socket) when a site needs isolation.

[www]
user = www-data
group = www-data
listen = /run/php/php${PHP}-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = $FPM_MAX_CHILDREN
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 2
pm.max_requests = 500

clear_env = yes
catch_workers_output = yes
decorate_workers_output = no
security.limit_extensions = .php
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
EOT
then php_changed=1; fi

run "php-fpm${PHP}" -t
if [ -n "$php_changed" ] || ! systemctl is-active -q "php${PHP}-fpm"; then
  run systemctl enable "php${PHP}-fpm"
  run systemctl restart "php${PHP}-fpm"
  ok "php${PHP}-fpm restarted"
else
  ok "php${PHP}-fpm configuration unchanged"
fi

# ---------------------------------------------------------------------------
# 6. MariaDB, loopback only (ported from io-server roles/mariadb)
# ---------------------------------------------------------------------------
say "MariaDB"
db_changed=""
guard_on
apt_install mariadb-server mariadb-client
guard_off
if write_file /etc/mysql/mariadb.conf.d/60-macvs.cnf 0644 <<EOT
# Managed by macvs deploy webroot (ported from io-server roles/mariadb 60-io-server.cnf, '$SIZE' sizing)

[mariadbd]
bind-address = 127.0.0.1
innodb_buffer_pool_size = $DB_BUFFER_POOL
max_connections = $DB_MAX_CONN
tmp_table_size = 32M
max_heap_table_size = 32M
innodb_log_file_size = 64M
slow_query_log = 0
EOT
then db_changed=1; fi
run mariadbd --defaults-file=/etc/mysql/my.cnf --verbose --help
if [ -n "$db_changed" ] || ! systemctl is-active -q mariadb; then
  run systemctl enable mariadb
  run systemctl restart mariadb
  ok "MariaDB restarted"
else
  ok "MariaDB configuration unchanged"
fi
run mariadb-admin --protocol=socket ping

# ---------------------------------------------------------------------------
# 7. certbot (ported from io-server roles/certbot); certificates are yours to issue
# ---------------------------------------------------------------------------
if [ "$CERTBOT" = yes ]; then
  say "certbot${DNS_PLUGIN:+ with the $DNS_PLUGIN DNS plugin}"
  apt_install certbot python3-certbot-apache ${DNS_PLUGIN:+"python3-certbot-dns-${DNS_PLUGIN}"}
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  write_file /etc/letsencrypt/renewal-hooks/deploy/macvs-apache-reload 0755 <<'EOT' || true
#!/bin/sh
# Managed by macvs deploy webroot: reload Apache after a renewed certificate is deployed.
set -eu
/usr/sbin/apache2ctl -t >/dev/null
/usr/bin/systemctl reload apache2.service
EOT
  run systemctl enable --now certbot.timer
  ok "certbot installed; renewal timer active"
fi

# ---------------------------------------------------------------------------
# 8. Firewall
# ---------------------------------------------------------------------------
# Under QEMU user-mode networking the guest only ever receives traffic on the
# ports the Mac forwards, and every client appears as 10.0.2.2. A guest firewall
# therefore cannot tell clients apart, and fail2ban would ban the Mac itself,
# which is every client at once. The default is no guest firewall: the forward
# list on the Mac is the firewall. "ufw" limits the guest to the forwarded ports.
if [ "$FIREWALL" = ufw ]; then
  say "ufw: allow tcp ${UFW_PORTS// /, }; deny everything else inbound"
  apt_install ufw
  set_kv /etc/default/ufw IPV6 yes "=" || true
  run ufw --force reset
  run ufw default deny incoming
  run ufw default allow outgoing
  for p in $UFW_PORTS; do run ufw allow "$p/tcp"; done
  run ufw --force enable
  run systemctl enable ufw
  ok "ufw active"
elif pkg_installed ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
  say "firewall: leaving the existing active ufw alone (pass --firewall ufw to manage it)"
else
  say "firewall: none in the guest (the Mac's port forwards are the firewall)"
fi
if pkg_installed fail2ban; then
  note "fail2ban is installed; with every client seen as 10.0.2.2 a ban locks out everyone. Consider: apt-get purge fail2ban"
fi

# ---------------------------------------------------------------------------
# 9. Validation
# ---------------------------------------------------------------------------
say "validation"
fails=0
check() { # label ok?(0/1) detail
  if [ "$2" = 0 ]; then printf '  ok   %-34s %s\n' "$1" "$3"; else printf '  FAIL %-34s %s\n' "$1" "$3"; fails=$((fails + 1)); fi
}
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || echo 000; }

r=0; apache2ctl -t >/dev/null 2>&1 || r=1; check "apache2ctl -t" "$r" "syntax OK"
r=0; systemctl is-active -q apache2 || r=1; check "apache2.service" "$r" "$(systemctl is-active apache2)"
mods="$(apache2ctl -M 2>/dev/null)"
r=0; printf '%s' "$mods" | grep -q mpm_event_module || r=1; check "event MPM" "$r" "$(printf '%s' "$mods" | grep -c '_module' | tr -d ' ') modules loaded"
r=0; printf '%s' "$mods" | grep -qE 'php[0-9._]*module|fcgid_module|mpm_prefork' && r=1; check "no mod_php / prefork" "$r" "PHP via proxy_fcgi only"
c="$(http_code -H 'Host: unknown.invalid' http://127.0.0.1/)"; r=0; [ "$c" = 403 ] || r=1; check "HTTP unknown host -> 403" "$r" "got $c"
c="$(http_code http://127.0.0.1/)"; r=0; [ "$c" = 403 ] || r=1; check "HTTP bare IP -> 403" "$r" "got $c"
c="$(http_code -k https://127.0.0.1/)"; r=0; [ "$c" = 403 ] || r=1; check "HTTPS default-deny -> 403" "$r" "got $c"
r=0; systemctl is-active -q "php${PHP}-fpm" || r=1; check "php${PHP}-fpm.service" "$r" "$(systemctl is-active "php${PHP}-fpm")"
r=0; [ -S "/run/php/php${PHP}-fpm.sock" ] || r=1; check "FPM socket" "$r" "/run/php/php${PHP}-fpm.sock"
v="$("php${PHP}" -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;' 2>/dev/null || true)"; r=0; [ "$v" = "$PHP" ] || r=1; check "php version" "$r" "${v:-?} ($("php${PHP}" -m 2>/dev/null | grep -ci 'opcache\|mysqli\|gd\|intl\|mbstring\|curl\|zip\|dom' | tr -d ' ') key extensions)"
mem="$(PHP_INI_SCAN_DIR="$fpm_dir/conf.d" "php-fpm${PHP}" -i 2>/dev/null | awk -F' => ' '$1=="memory_limit"{v=$2} END{print v}' || true)"; r=0; [ "$mem" = 256M ] || r=1; check "FPM memory_limit" "$r" "${mem:-?}"
r=0; systemctl is-active -q mariadb || r=1; check "mariadb.service" "$r" "$(systemctl is-active mariadb)"
r=0; mariadb-admin --protocol=socket ping >/dev/null 2>&1 || r=1; check "mariadb socket ping" "$r" "alive"
lst="$(ss -H -lnt 2>/dev/null)"
r=0; printf '%s' "$lst" | grep -qE '127\.0\.0\.1:3306[[:space:]]' || r=1
r2=0; printf '%s' "$lst" | grep -qE '(0\.0\.0\.0|\[::\]):3306[[:space:]]' && r2=1
check "mariadb loopback only" "$((r + r2 > 0 ? 1 : 0))" "$(printf '%s' "$lst" | awk '$4 ~ /:3306$/ {print $4}' | tr '\n' ' ')"
vals="$(mariadb --batch --skip-column-names --protocol=socket -e 'SELECT @@bind_address, @@innodb_buffer_pool_size/1048576, @@max_connections' 2>/dev/null | tr '\t' ' ' || true)"
r=0; [ "$vals" = "127.0.0.1 ${DB_BUFFER_POOL%M}.0000 $DB_MAX_CONN" ] || [ "$vals" = "127.0.0.1 ${DB_BUFFER_POOL%M} $DB_MAX_CONN" ] || r=1; check "mariadb tuning" "$r" "${vals:-?}"
r=0; printf '%s' "$lst" | grep -qE ':80[[:space:]]' && printf '%s' "$lst" | grep -qE ':443[[:space:]]' || r=1; check "listening 80 and 443" "$r" "$(printf '%s' "$lst" | awk '{print $4}' | sort -u | tr '\n' ' ')"
if [ "$CERTBOT" = yes ]; then r=0; systemctl is-active -q certbot.timer || r=1; check "certbot.timer" "$r" "$(systemctl is-active certbot.timer)"; fi
if [ "$SWAP" != none ]; then r=0; swapon --show=NAME --noheadings | grep -qx /swapfile || r=1; check "swap" "$r" "/swapfile $(swapon --show=SIZE --noheadings --bytes 2>/dev/null | head -n 1) bytes"; fi
r=0; [ -z "$(systemctl --failed --no-legend --plain 2>/dev/null)" ] || r=1; check "no failed systemd units" "$r" "$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 10. Record
# ---------------------------------------------------------------------------
if ! pkg_installed ufw; then ufw_state=absent
elif ufw status 2>/dev/null | grep -q '^Status: active'; then ufw_state=active
else ufw_state=inactive; fi
write_file "$STATE_DIR/webroot.env" 0644 <<EOT || true
# Written by macvs deploy webroot. Non-secret record of what was applied; re-run the deploy to reconverge.
MACVS_WEBROOT_MACVS_VERSION='$MACVS_VERSION'
MACVS_WEBROOT_DEBIAN='$CODENAME'
MACVS_WEBROOT_PHP='$PHP'
MACVS_WEBROOT_SIZE='$SIZE'
MACVS_WEBROOT_SWAP='$SWAP'
MACVS_WEBROOT_FIREWALL='$FIREWALL'
MACVS_WEBROOT_UFW_PORTS='$UFW_PORTS'
MACVS_WEBROOT_UFW_STATE='$ufw_state'
MACVS_WEBROOT_CERTBOT='$CERTBOT'
MACVS_WEBROOT_DNS_PLUGIN='$DNS_PLUGIN'
MACVS_WEBROOT_FPM_SOCKET='/run/php/php${PHP}-fpm.sock'
MACVS_WEBROOT_SITES_ROOT='/var/www'
EOT
printf 'MACVS_WEBROOT_LAST_RUN=%s\n' "$(date -u +%FT%TZ)" > "$STATE_DIR/webroot.last-run"

write_file /etc/motd 0644 <<EOT || true

  $(hostname) - web server provisioned by macvs deploy webroot
  Apache 2.4 (mpm_event) + PHP ${PHP}-FPM + MariaDB, PHP from packages.sury.org

  vhosts      /etc/apache2/sites-available   (a2ensite NAME; apache2ctl -t; systemctl reload apache2)
  webroots    /var/www/<site>/htdocs
  PHP-FPM     /run/php/php${PHP}-fpm.sock    (pool: /etc/php/${PHP}/fpm/pool.d/www.conf)
  MariaDB     sudo mariadb                  (127.0.0.1:3306 and the unix socket only)
  record      /etc/macvs/webroot.env

EOT

echo
if [ "$fails" = 0 ]; then
  ok "webroot profile applied; every check passed"
else
  printf 'error: %s validation check(s) failed (details above; log: %s)\n' "$fails" "$LOG" >&2
  exit 1
fi

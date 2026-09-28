#!/bin/bash
# macvs-profile: website - a site on a webroot server: locked user, PHP-FPM pool, Apache vhost (domain or subdomain), Hello World webroot, MariaDB database
#
# This script runs INSIDE the guest as root; `macvs deploy website <fqdn> <vm>`
# sends it over SSH. It needs a guest provisioned by the webroot profile and
# follows the io-server site model (roles wordpress_site, php_fpm/site,
# apache/site, mariadb/site): one locked Linux user per site, the site's files
# under /var/www/<fqdn>/htdocs, a dedicated PHP-FPM pool on its own socket, one
# Apache vhost file, a MariaDB database and localhost-only user, log rotation.
# Idempotent: re-running converges and reloads only what changed. It never
# touches anything outside the guest.
#
# Parameters (environment):
#   MACVS_SITE_FQDN=site.example      the name to serve (a domain or a subdomain)
#   MACVS_SITE_ALIASES=               extra names, space separated (ServerAlias)
#   MACVS_SITE_TLS=auto               auto: HTTPS when /etc/letsencrypt/live/<fqdn> exists, else HTTP only
#                                     self-signed: generate and serve a self-signed certificate
#                                     custom: use MACVS_SITE_CERT and MACVS_SITE_KEY (guest paths)
#                                     none: HTTP only
#   MACVS_SITE_CERT= MACVS_SITE_KEY=  for custom
#   MACVS_SITE_DATABASE=yes           create a MariaDB database and user for the site
#   MACVS_SITE_ACTION=apply           apply | remove (vhost and pool go, files stay) | purge (everything goes)
#   MACVS_SITE_VERSION=               macvs version, recorded
set -euo pipefail

FQDN="${MACVS_SITE_FQDN:-}"
ALIASES="${MACVS_SITE_ALIASES:-}"
TLS="${MACVS_SITE_TLS:-auto}"
CERT="${MACVS_SITE_CERT:-}"
KEY="${MACVS_SITE_KEY:-}"
DATABASE="${MACVS_SITE_DATABASE:-yes}"
ACTION="${MACVS_SITE_ACTION:-apply}"
MACVS_VERSION="${MACVS_SITE_VERSION:-unknown}"

LOG=/var/log/macvs-website.log
WEBROOT_ENV=/etc/macvs/webroot.env
SITES_STATE_ROOT=/etc/macvs/sites
SITES_LOG_ROOT=/var/log/macvs-sites

# ---------------------------------------------------------------------------
# helpers (same conventions as webroot.sh)
# ---------------------------------------------------------------------------
say()  { printf '==> %s\n' "$*"; }
ok()   { printf ' ok  %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

run() {
  printf '%s $ %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"
  if ! "$@" >> "$LOG" 2>&1; then
    printf 'error: command failed: %s\n--- last lines of %s ---\n' "$*" "$LOG" >&2
    tail -n 40 "$LOG" >&2
    exit 1
  fi
}

# write_file DEST MODE [OWNER:GROUP] (content on stdin). Returns 0 if changed, 1 if identical.
write_file() {
  local dest="$1" mode="$2" owner="${3:-root:root}" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest" \
     && [ "$(stat -c '%U:%G %a' "$dest")" = "$owner $(printf '%o' "$((8#$mode))")" ]; then
    rm -f "$tmp"; return 1
  fi
  mkdir -p "$(dirname "$dest")"
  install -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  return 0
}

ensure_dir() { # path mode owner:group  -> returns 0 if it changed anything
  local path="$1" mode="$2" owner="$3" changed=1
  if [ -L "$path" ]; then fail "$path is a symbolic link; refusing to use a planted link"; fi
  if [ ! -d "$path" ]; then mkdir -p "$path"; changed=0; fi
  if [ "$(stat -c '%U:%G' "$path")" != "$owner" ]; then chown "$owner" "$path"; changed=0; fi
  if [ "$(stat -c '%a' "$path")" != "$mode" ]; then chmod "$mode" "$path"; changed=0; fi
  return "$changed"
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null || echo 000; }

# ---------------------------------------------------------------------------
# preflight and derived names
# ---------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || fail "must run as root"
[ -f "$WEBROOT_ENV" ] || fail "this guest has not been provisioned by 'macvs deploy webroot' ($WEBROOT_ENV is missing)"
# shellcheck disable=SC1090
. "$WEBROOT_ENV"
PHP="${MACVS_WEBROOT_PHP:-}"
SIZE="${MACVS_WEBROOT_SIZE:-small}"
[ -n "$PHP" ] && [ -d "/etc/php/$PHP/fpm" ] || fail "PHP-FPM $PHP from the webroot profile is not installed"
command -v apache2ctl >/dev/null || fail "apache2 is not installed; run 'macvs deploy webroot' first"

FQDN="$(printf '%s' "$FQDN" | tr '[:upper:]' '[:lower:]')"
name_re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}$'
[[ "$FQDN" =~ $name_re ]] && [ "${#FQDN}" -le 253 ] || fail "MACVS_SITE_FQDN must be a host name such as site.example or sub.site.example (got '$FQDN')"
for a in $ALIASES; do
  [[ "$a" =~ $name_re ]] || fail "alias '$a' is not a valid host name"
done
[[ "$TLS" =~ ^(auto|self-signed|custom|none)$ ]] || fail "MACVS_SITE_TLS must be auto, self-signed, custom, or none"
[[ "$DATABASE" =~ ^(yes|no)$ ]] || fail "MACVS_SITE_DATABASE must be yes or no"
[[ "$ACTION" =~ ^(apply|remove|purge)$ ]] || fail "MACVS_SITE_ACTION must be apply, remove, or purge"
if [ "$TLS" = custom ]; then
  [ -f "$CERT" ] || fail "certificate not found in the guest: $CERT"
  [ -f "$KEY" ]  || fail "key not found in the guest: $KEY"
fi

# Identifiers derived from the name: the site id (Linux user, pool, socket) and
# the database id. Long names are shortened with a hash so they stay unique.
SITE_ID="${FQDN//./-}"
if [ "${#SITE_ID}" -gt 32 ]; then SITE_ID="${SITE_ID:0:24}-$(printf '%s' "$FQDN" | sha256sum | cut -c1-7)"; fi
DB_ID="$(printf '%s' "$FQDN" | tr '.-' '__')"
if [ "${#DB_ID}" -gt 64 ]; then DB_ID="${DB_ID:0:56}_$(printf '%s' "$FQDN" | sha256sum | cut -c1-7)"; fi
SITE_USER="$SITE_ID"
SITE_HOME="/home/$SITE_USER"
SITE_ROOT="/var/www/$FQDN"
DOCROOT="$SITE_ROOT/htdocs"
LOG_DIR="$SITES_LOG_ROOT/$FQDN"
STATE_DIR="$SITES_STATE_ROOT/$FQDN"
SECRETS="$STATE_DIR/secrets.env"
TLS_DIR="$STATE_DIR/tls"
POOL="$SITE_ID"
SOCKET="/run/php/fpm-$SITE_ID.sock"
POOL_FILE="/etc/php/$PHP/fpm/pool.d/macvs-$SITE_ID.conf"
VHOST="/etc/apache2/sites-available/$FQDN.conf"
VHOST_LINK="/etc/apache2/sites-enabled/$FQDN.conf"
LOGROTATE="/etc/logrotate.d/macvs-site-$SITE_ID"
DB_NAME="$DB_ID"; DB_USER="$DB_ID"

mkdir -p "$(dirname "$LOG")"; touch "$LOG"; chmod 600 "$LOG"
printf '%s ===== macvs deploy website %s (%s, macvs %s) =====\n' "$(date -u +%FT%TZ)" "$FQDN" "$ACTION" "$MACVS_VERSION" >> "$LOG"
trap 'printf "error: unexpected failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

apache_changed=""; fpm_changed=""

# ---------------------------------------------------------------------------
# remove / purge
# ---------------------------------------------------------------------------
if [ "$ACTION" != apply ]; then
  say "$ACTION site $FQDN (user $SITE_USER, pool $POOL)"
  if [ -e "$VHOST_LINK" ]; then run a2dissite -q "$FQDN"; apache_changed=1; fi
  if [ -f "$VHOST" ]; then rm -f "$VHOST"; apache_changed=1; fi
  if [ -n "$apache_changed" ]; then run apache2ctl -t; run systemctl reload apache2; ok "vhost removed; Apache reloaded"; fi
  if [ -f "$POOL_FILE" ]; then rm -f "$POOL_FILE"; fpm_changed=1; fi
  if [ -n "$fpm_changed" ]; then
    # Restart, not reload: a USR2 reload does not reliably drop and re-add pools
    # (io-server restarts FPM over the surviving pools for the same reason).
    if [ "$(find "/etc/php/$PHP/fpm/pool.d" -name '*.conf' | wc -l)" -gt 0 ]; then
      run "php-fpm$PHP" -t; run systemctl restart "php$PHP-fpm"
    else
      run systemctl stop "php$PHP-fpm"; note "no pools left; php$PHP-fpm stopped"
    fi
    rm -f "$SOCKET"
    ok "PHP-FPM pool removed"
  fi
  rm -f "$LOGROTATE"
  if [ "$ACTION" = purge ]; then
    if [ -f "$SECRETS" ] || mariadb --batch --skip-column-names --protocol=socket -e "SHOW DATABASES LIKE '$DB_NAME'" 2>/dev/null | grep -qx "$DB_NAME"; then
      mariadb --batch --protocol=socket <<SQL
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_USER'@'localhost';
SQL
      ok "database $DB_NAME and user $DB_USER dropped"
    fi
    rm -rf "$SITE_ROOT" "$LOG_DIR" "$STATE_DIR"
    if id -u "$SITE_USER" >/dev/null 2>&1; then
      if ! userdel -r "$SITE_USER" >> "$LOG" 2>&1; then userdel "$SITE_USER" >> "$LOG" 2>&1 || fail "could not delete user $SITE_USER (see $LOG)"; fi
    fi
    ok "purged $SITE_ROOT, logs, secrets, and user $SITE_USER"
  else
    if [ -f "$STATE_DIR/site.env" ]; then
      sed -i 's/^SITE_ENABLED=.*/SITE_ENABLED=no/' "$STATE_DIR/site.env"
    fi
    note "kept $SITE_ROOT, the database, secrets, and user $SITE_USER (use purge to delete them)"
  fi
  c="$(http_code -H "Host: $FQDN" http://127.0.0.1/)"
  [ "$c" = 403 ] || fail "$FQDN still answers $c on the default listener after removal"
  ok "$FQDN now falls through to the default-deny vhost (403)"
  exit 0
fi

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------
say "site $FQDN${ALIASES:+ (aliases: $ALIASES)} on PHP $PHP: user $SITE_USER, pool $POOL, '$SIZE' sizing, tls $TLS, database $DATABASE"
note "full command output is kept in $LOG"

# 1. Locked Linux user (io-server: a regular account with a locked password).
if ! id -u "$SITE_USER" >/dev/null 2>&1; then
  run useradd --create-home --home-dir "$SITE_HOME" --shell /bin/bash --comment "macvs site $FQDN" "$SITE_USER"
  run passwd -l "$SITE_USER"
  ok "created user $SITE_USER"
fi
ensure_dir "$SITE_HOME" 750 "$SITE_USER:$SITE_USER" || true

# 2. Directories: the site's tree is the site user's, readable by www-data.
ensure_dir "$SITE_ROOT" 750 "$SITE_USER:www-data" || true
ensure_dir "$DOCROOT"   750 "$SITE_USER:www-data" || true
ensure_dir "$SITES_LOG_ROOT" 755 root:root || true
ensure_dir "$LOG_DIR"   750 "$SITE_USER:$SITE_USER" || true
ensure_dir "$SITES_STATE_ROOT" 700 root:root || true
ensure_dir "$STATE_DIR" 700 root:root || true

# 3. Hello World, only while the webroot holds no index of its own.
if ! ls "$DOCROOT"/index.* >/dev/null 2>&1; then
  write_file "$DOCROOT/index.php" 0640 "$SITE_USER:www-data" <<EOT || true
<?php
// Placeholder written by macvs deploy website for $FQDN. Replace it with your site.
header('Content-Type: text/html; charset=utf-8');
\$host = htmlspecialchars(\$_SERVER['HTTP_HOST'] ?? '$FQDN', ENT_QUOTES);
?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Hello World - $FQDN</title>
<style>body{font:16px/1.5 system-ui,sans-serif;margin:3rem auto;max-width:40rem;padding:0 1rem;color:#222}code{background:#f2f2f2;padding:.1em .3em}</style>
</head>
<body>
<h1>Hello World</h1>
<p>This is <strong><?= \$host ?></strong>, served by Apache and PHP <?= PHP_VERSION ?> (<?= PHP_SAPI ?>) on <?= htmlspecialchars(gethostname()) ?>.</p>
<p>The webroot is <code>$DOCROOT</code>; replace this <code>index.php</code> with your site.</p>
</body>
</html>
EOT
  ok "wrote the Hello World page to $DOCROOT/index.php"
fi

# 4. Dedicated PHP-FPM pool (io-server's per-role pool policy: ondemand on the
#    small sizing so idle sites hold no workers, dynamic on the large one).
if [ "$SIZE" = large ]; then
  pm_block=$'pm = dynamic\npm.max_children = 4\npm.start_servers = 1\npm.min_spare_servers = 1\npm.max_spare_servers = 2'
else
  pm_block=$'pm = ondemand\npm.max_children = 3\npm.process_idle_timeout = 10s'
fi
if write_file "$POOL_FILE" 0644 <<EOT
; Managed by macvs deploy website for $FQDN (ported from io-server roles/php_fpm site-pool.conf).
; Re-run 'macvs deploy website $FQDN <vm>' to regenerate.

[$POOL]
user = $SITE_USER
group = $SITE_USER
listen = $SOCKET
listen.owner = $SITE_USER
listen.group = www-data
listen.mode = 0660

$pm_block
pm.max_requests = 500

clear_env = yes
catch_workers_output = yes
decorate_workers_output = no
security.limit_extensions = .php
php_admin_value[error_log] = $LOG_DIR/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
EOT
then fpm_changed=1; fi
run "php-fpm$PHP" -t
if [ -n "$fpm_changed" ] || [ ! -S "$SOCKET" ]; then
  # Restart rather than reload: a USR2 reload does not reliably create the socket
  # of a pool that was added (or removed and re-added); io-server restarts FPM on
  # pool changes too. Other sites' workers are replaced within a second.
  run systemctl enable "php$PHP-fpm"
  run systemctl restart "php$PHP-fpm"
  t=0; until [ -S "$SOCKET" ] || [ "$t" -ge 10 ]; do sleep 1; t=$((t + 1)); done
  [ -S "$SOCKET" ] || fail "PHP-FPM did not create $SOCKET (journalctl -u php$PHP-fpm)"
  ok "PHP-FPM pool $POOL listening on $SOCKET (php$PHP-fpm restarted)"
else
  ok "PHP-FPM pool unchanged"
fi

# 5. Certificate.
tls_on=""; tls_source="none"
case "$TLS" in
  custom)
    tls_on=1; tls_source="custom ($CERT)" ;;
  self-signed)
    ensure_dir "$TLS_DIR" 700 root:root || true
    CERT="$TLS_DIR/cert.pem"; KEY="$TLS_DIR/key.pem"
    if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
      san="DNS:$FQDN"; for a in $ALIASES; do san="$san,DNS:$a"; done
      run openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj "/CN=$FQDN" -addext "subjectAltName=$san" -keyout "$KEY" -out "$CERT"
      chmod 600 "$KEY"; chmod 644 "$CERT"
      ok "generated a self-signed certificate for $FQDN${ALIASES:+ and its aliases}"
    fi
    tls_on=1; tls_source="self-signed ($CERT)" ;;
  auto)
    if [ -f "/etc/letsencrypt/live/$FQDN/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$FQDN/privkey.pem" ]; then
      CERT="/etc/letsencrypt/live/$FQDN/fullchain.pem"; KEY="/etc/letsencrypt/live/$FQDN/privkey.pem"
      tls_on=1; tls_source="letsencrypt ($CERT)"
    fi ;;
  none) ;;
esac
if [ -n "$tls_on" ]; then
  openssl x509 -in "$CERT" -noout >/dev/null 2>&1 || fail "$CERT is not a readable X.509 certificate"
  ok "HTTPS on: $tls_source"
else
  note "HTTPS off: no certificate for $FQDN yet (serving plain HTTP; re-run after certbot, or use self-signed)"
fi

# 6. Apache vhost: one file per site, port 80 plus 443 when a certificate exists.
alias_line=""
[ -z "$ALIASES" ] || alias_line="    ServerAlias $ALIASES"$'\n'
site_body="    DocumentRoot $DOCROOT
    DirectoryIndex index.php index.html

    # Links are followed only to targets the site user owns; .htaccess stays off.
    <Directory \"$DOCROOT\">
        Options SymLinksIfOwnerMatch
        AllowOverride None
        Require all granted
        FallbackResource /index.php
    </Directory>

    <FilesMatch \"\\.php\$\">
        SetHandler \"proxy:unix:$SOCKET|fcgi://localhost/\"
    </FilesMatch>
"
vtmp="$(mktemp)"
{
  printf '# Managed by macvs deploy website for %s (macvs %s). Re-run the deploy to regenerate;\n' "$FQDN" "$MACVS_VERSION"
  printf '# edits here are overwritten. Webroot: %s  PHP-FPM socket: %s\n\n' "$DOCROOT" "$SOCKET"
  if [ -n "$tls_on" ]; then
    cat <<EOT
<VirtualHost *:80>
    ServerName $FQDN
${alias_line}    DocumentRoot $DOCROOT

    # Plain HTTP only redirects, except ACME HTTP-01 challenges from the webroot.
    <Directory "$DOCROOT/.well-known/acme-challenge">
        Options None
        AllowOverride None
        Require all granted
    </Directory>
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/
    RewriteRule ^ https://$FQDN%{REQUEST_URI} [R=301,L,NE]

    ErrorLog \${APACHE_LOG_DIR}/${FQDN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${FQDN}_access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName $FQDN
${alias_line}    Protocols h2 http/1.1

    SSLEngine on
    SSLCertificateFile $CERT
    SSLCertificateKeyFile $KEY

$site_body
    ErrorLog \${APACHE_LOG_DIR}/${FQDN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${FQDN}_access.log combined
</VirtualHost>
EOT
  else
    cat <<EOT
<VirtualHost *:80>
    ServerName $FQDN
${alias_line}
$site_body
    ErrorLog \${APACHE_LOG_DIR}/${FQDN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${FQDN}_access.log combined
</VirtualHost>
EOT
  fi
} > "$vtmp"
if write_file "$VHOST" 0644 < "$vtmp"; then apache_changed=1; fi
rm -f "$vtmp"
if [ ! -e "$VHOST_LINK" ]; then run a2ensite -q "$FQDN"; apache_changed=1; fi
run apache2ctl -t
if [ -n "$apache_changed" ]; then run systemctl reload apache2; ok "vhost $VHOST enabled; Apache reloaded"; else ok "vhost unchanged"; fi

# 7. Database and localhost-only user; the password lives only in a root-only file.
db_state="none"
if [ "$DATABASE" = yes ]; then
  if [ -f "$SECRETS" ]; then
    db_password="$(sed -n 's/^DB_PASSWORD=//p' "$SECRETS" | head -n 1)"
  else
    db_password=""
  fi
  if [ -z "$db_password" ]; then
    db_password="$(openssl rand -hex 32)"
    write_file "$SECRETS" 0600 <<EOT || true
# Written by macvs deploy website for $FQDN. Root only; do not commit anywhere.
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$db_password
DB_HOST=localhost
EOT
    ok "generated database credentials in $SECRETS"
  fi
  mariadb --batch --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$db_password';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$db_password';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$DB_USER'@'localhost';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
  probe="$(mktemp)"; chmod 600 "$probe"
  printf '[client]\nuser=%s\npassword=%s\nprotocol=socket\n' "$DB_USER" "$db_password" > "$probe"
  if mariadb --defaults-extra-file="$probe" --batch --skip-column-names -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME'" 2>/dev/null | grep -qx 1; then
    db_state="ok"
  else
    db_state="FAILED"
  fi
  rm -f "$probe"; unset db_password
  [ "$db_state" = ok ] || fail "the site's database user cannot reach $DB_NAME"
  ok "database $DB_NAME, user $DB_USER@localhost"
fi

# 8. Rotate the pool's PHP error log as the site user (io-server wordpress-logrotate).
write_file "$LOGROTATE" 0644 <<EOT || true
# Managed by macvs deploy website for $FQDN.
$LOG_DIR/php-error.log {
    su $SITE_USER $SITE_USER
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 $SITE_USER $SITE_USER
}
EOT

# 9. Record (non-secret).
write_file "$STATE_DIR/site.env" 0644 <<EOT || true
# Written by macvs deploy website. Non-secret record; credentials are in secrets.env (root only).
SITE_FQDN='$FQDN'
SITE_ALIASES='$ALIASES'
SITE_ID='$SITE_ID'
SITE_USER='$SITE_USER'
SITE_ROOT='$SITE_ROOT'
SITE_DOCROOT='$DOCROOT'
SITE_POOL='$POOL'
SITE_SOCKET='$SOCKET'
SITE_VHOST='$VHOST'
SITE_TLS='$TLS'
SITE_TLS_SOURCE='$tls_source'
SITE_TLS_CERT='${tls_on:+$CERT}'
SITE_DATABASE='$([ "$DATABASE" = yes ] && echo "$DB_NAME" || echo none)'
SITE_DB_USER='$([ "$DATABASE" = yes ] && echo "$DB_USER" || echo none)'
SITE_LOG_DIR='$LOG_DIR'
SITE_ENABLED=yes
SITE_MACVS_VERSION='$MACVS_VERSION'
EOT
printf 'SITE_LAST_RUN=%s\n' "$(date -u +%FT%TZ)" > "$STATE_DIR/site.last-run"

# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------
say "validation"
fails=0
check() { if [ "$2" = 0 ]; then printf '  ok   %-34s %s\n' "$1" "$3"; else printf '  FAIL %-34s %s\n' "$1" "$3"; fails=$((fails + 1)); fi; }

r=0; apache2ctl -t >/dev/null 2>&1 || r=1; check "apache2ctl -t" "$r" "syntax OK"
r=0; apache2ctl -S 2>/dev/null | grep -q "namevhost $FQDN " || r=1; check "vhost in the map" "$r" "$(apache2ctl -S 2>/dev/null | grep -c "namevhost $FQDN " | tr -d ' ') listener(s)"
r=0; [ -S "$SOCKET" ] && [ "$(stat -c %U "$SOCKET")" = "$SITE_USER" ] || r=1; check "FPM socket owned by site user" "$r" "$SOCKET ($(stat -c '%U:%G %a' "$SOCKET" 2>/dev/null || echo missing))"
body="$(curl -s --max-time 8 -H "Host: $FQDN" http://127.0.0.1/ 2>/dev/null || true)"
c="$(http_code -H "Host: $FQDN" http://127.0.0.1/)"
if [ -n "$tls_on" ]; then
  loc="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 8 -H "Host: $FQDN" http://127.0.0.1/ 2>/dev/null || true)"
  r=0; [ "$c" = 301 ] && [ "$loc" = "https://$FQDN/" ] || r=1; check "HTTP -> HTTPS redirect" "$r" "$c -> ${loc:-?}"
  body="$(curl -sk --max-time 8 --resolve "$FQDN:443:127.0.0.1" "https://$FQDN/" 2>/dev/null || true)"
  c="$(http_code -k --resolve "$FQDN:443:127.0.0.1" "https://$FQDN/")"
  r=0; [ "$c" = 200 ] || [ "$c" = 301 ] || [ "$c" = 302 ] || r=1; check "HTTPS answers" "$r" "$c"
  subj="$(openssl s_client -connect 127.0.0.1:443 -servername "$FQDN" </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//' || true)"
  r=0; printf '%s' "$subj" | grep -q "$FQDN" || r=1; check "certificate presented for the name" "$r" "${subj:-none}"
else
  r=0; [ "$c" = 200 ] || [ "$c" = 301 ] || [ "$c" = 302 ] || r=1; check "HTTP answers" "$r" "$c"
fi
if [ -f "$DOCROOT/index.php" ] && grep -q 'macvs deploy website' "$DOCROOT/index.php" 2>/dev/null; then
  r=0; printf '%s' "$body" | grep -q 'Hello World' && printf '%s' "$body" | grep -q 'fpm-fcgi' || r=1
  check "Hello World through PHP-FPM" "$r" "$(printf '%s' "$body" | grep -o 'PHP [0-9.]* (fpm-fcgi)' | head -n 1)"
fi
for a in $ALIASES; do
  c="$(http_code -H "Host: $a" http://127.0.0.1/)"; r=0; [ "$c" != 403 ] && [ "$c" != 000 ] || r=1; check "alias $a" "$r" "$c"
done
c="$(http_code -H 'Host: unknown.invalid' http://127.0.0.1/)"; r=0; [ "$c" = 403 ] || r=1; check "other names still denied" "$r" "$c"
if [ "$DATABASE" = yes ]; then r=0; [ "$db_state" = ok ] || r=1; check "database reachable as site user" "$r" "$DB_NAME"; fi
r=0; logrotate -d "$LOGROTATE" >/dev/null 2>&1 || r=1; check "logrotate config" "$r" "$LOGROTATE"

echo
if [ "$fails" = 0 ]; then
  ok "site $FQDN is live on this server"
else
  printf 'error: %s check(s) failed for %s (log: %s)\n' "$fails" "$FQDN" "$LOG" >&2
  exit 1
fi

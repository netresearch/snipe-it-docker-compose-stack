#!/bin/sh
# entrypoint.sh — runs as root before php-fpm takes over.
#
# Responsibilities:
#   - Read Docker secrets via *_FILE env vars and export the value
#   - Verify required env vars are set
#   - Ensure storage / cache directories are writable (volumes may have new uids)
#   - Wait for the DB to be reachable
#   - Apply migrations (opt-out via SKIP_MIGRATIONS=true)
#   - Cache Laravel config + routes
#   - exec CMD (php-fpm)
#
# Hard-fail loudly if any precondition is missing — silent half-starts are
# worse than crash loops.

set -eu

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------
# 1. Docker-secrets shim — *_FILE env vars take precedence over plain ones
# ---------------------------------------------------------------------
load_secret_file() {
  var="$1"
  file_var="${var}_FILE"
  eval file_path="\${$file_var:-}"
  eval current_value="\${$var:-}"
  if [ -n "$file_path" ] && [ -f "$file_path" ]; then
    if [ -n "$current_value" ]; then
      log "WARNING: both $var and $file_var set — using $file_var"
    fi
    secret_value=$(cat "$file_path")
    export "$var"="$secret_value"
    unset "$file_var"
  fi
}

for v in APP_KEY DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD \
         REDIS_HOST REDIS_PASSWORD REDIS_PORT \
         MAIL_HOST MAIL_PORT MAIL_USERNAME MAIL_PASSWORD; do
  load_secret_file "$v"
done

# ---------------------------------------------------------------------
# 2. Required env vars (artisan-friendly diagnostics)
# ---------------------------------------------------------------------
: "${APP_KEY:?APP_KEY is required — generate with: php artisan key:generate --show}"
: "${APP_URL:?APP_URL is required (e.g. https://snipeit.example.com — no trailing slash)}"
: "${DB_HOST:?DB_HOST is required}"
: "${DB_DATABASE:?DB_DATABASE is required}"
: "${DB_USERNAME:?DB_USERNAME is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"

export APP_ENV="${APP_ENV:-production}"
export APP_DEBUG="${APP_DEBUG:-false}"
export DB_CONNECTION="${DB_CONNECTION:-mysql}"
export DB_PORT="${DB_PORT:-3306}"
export TZ="${TZ:-UTC}"
export SKIP_MIGRATIONS="${SKIP_MIGRATIONS:-false}"

# ---------------------------------------------------------------------
# 3. Volume bind-mount permission repair
# ---------------------------------------------------------------------
log "ensuring storage/cache directories are writable by www-data"
mkdir -p \
  /var/www/html/storage/framework/cache/data \
  /var/www/html/storage/framework/sessions \
  /var/www/html/storage/framework/views \
  /var/www/html/storage/logs \
  /var/www/html/bootstrap/cache \
  /var/lib/snipeit

chown -R www-data:www-data \
  /var/www/html/storage \
  /var/www/html/bootstrap/cache \
  /var/lib/snipeit 2>/dev/null || true
chmod -R u+rwX,g+rwX,o+rX /var/www/html/storage /var/www/html/bootstrap/cache

# ---------------------------------------------------------------------
# 4. Wait for DB (skip if SKIP_DB_WAIT=true)
# ---------------------------------------------------------------------
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-60}"
if [ "${SKIP_DB_WAIT:-false}" != "true" ]; then
  log "waiting up to ${DB_WAIT_TIMEOUT}s for ${DB_HOST}:${DB_PORT}"
  i=0
  while [ "$i" -lt "$DB_WAIT_TIMEOUT" ]; do
    if php -r "
      try {
        new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_DATABASE}',
                '${DB_USERNAME}', '${DB_PASSWORD}',
                [PDO::ATTR_TIMEOUT => 3]);
        exit(0);
      } catch (Exception \$e) { exit(1); }
    " 2>/dev/null; then
      log "DB reachable"
      break
    fi
    i=$((i + 2))
    sleep 2
  done
  if [ "$i" -ge "$DB_WAIT_TIMEOUT" ]; then
    log "ERROR: DB not reachable after ${DB_WAIT_TIMEOUT}s — aborting"
    exit 1
  fi
fi

# ---------------------------------------------------------------------
# 5. Migrations
# ---------------------------------------------------------------------
cd /var/www/html
if [ "$SKIP_MIGRATIONS" = "true" ]; then
  log "SKIP_MIGRATIONS=true — skipping artisan migrate"
else
  log "running php artisan migrate --force"
  su-exec www-data php artisan migrate --force --no-interaction
fi

# ---------------------------------------------------------------------
# 6. Cache config + routes (production optimisation)
# ---------------------------------------------------------------------
log "caching config, routes, events"
su-exec www-data php artisan config:cache
su-exec www-data php artisan route:cache 2>/dev/null || true
su-exec www-data php artisan event:cache 2>/dev/null || true
su-exec www-data php artisan view:clear

log "ready — exec into CMD: $*"
exec "$@"

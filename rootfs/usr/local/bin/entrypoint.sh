#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# entrypoint.sh — runs as root before php-fpm takes over.
#
# Responsibilities:
#   - Read Docker secrets via *_FILE env vars and export the value
#   - Verify required env vars are set
#   - Ensure storage / cache directories are writable (volumes may have new uids)
#   - Bootstrap Passport OAuth keys if missing (first-boot / nuked volume)
#   - Wait for the DB to be reachable
#   - Apply migrations under maintenance mode (opt-out via SKIP_MIGRATIONS=true)
#   - Clear stale Laravel cache, then re-cache config + routes
#   - exec CMD (php-fpm)
#
# Mirrors the artisan call sequence from upstream's upgrade.php
# (https://github.com/grokability/snipe-it/blob/master/upgrade.php) so that
# entrypoint-driven schema upgrades behave like the documented upstream
# upgrade flow.
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
  /var/lib/snipeit \
  /run/php-fpm

# /run/php-fpm is also chown'd in case compose mounts a tmpfs here:
# tmpfs masks the image-bake chown, so php-fpm (UID www-data) can't
# create its socket without this. Standalone `docker run` of the image
# falls back to the image-layer chown set in the Dockerfile.
chown -R www-data:www-data \
  /var/www/html/storage \
  /var/www/html/bootstrap/cache \
  /var/lib/snipeit \
  /run/php-fpm 2>/dev/null || true
# Only chmod the directories we just (potentially) created via mkdir -p above —
# a recursive chmod across the whole storage tree pegs CPU for seconds on large
# instances on every container start. Pre-existing files keep their modes.
chmod 0775 \
  /var/www/html/storage \
  /var/www/html/storage/framework \
  /var/www/html/storage/framework/cache \
  /var/www/html/storage/framework/cache/data \
  /var/www/html/storage/framework/sessions \
  /var/www/html/storage/framework/views \
  /var/www/html/storage/logs \
  /var/www/html/bootstrap/cache \
  /var/lib/snipeit 2>/dev/null || true

# ---------------------------------------------------------------------
# 3b. Passport / OAuth key bootstrap
# ---------------------------------------------------------------------
# Snipe-IT uses Laravel Passport for OAuth. The asymmetric keypair lives at
# storage/oauth-{private,public}.key. If either is missing — fresh install,
# or storage volume was nuked — the UI works but every /oauth/* request 500s
# silently (catastrophic for API consumers). Generate the pair before
# php-fpm starts so OAuth is functional from the very first request.
#
# `passport:keys --force` is a file-only operation (no DB), so we run it
# here, before the DB wait. The `[ ! -f X ] || [ ! -f Y ]` guard is
# load-bearing: --force would overwrite an existing keypair and revoke all
# outstanding access tokens.
if [ ! -f /var/www/html/storage/oauth-private.key ] || \
   [ ! -f /var/www/html/storage/oauth-public.key ]; then
  log "OAuth/Passport keys missing — generating via artisan passport:keys"
  su-exec www-data php artisan passport:keys --force --no-interaction
else
  log "OAuth/Passport keys present"
fi

# ---------------------------------------------------------------------
# 4. Wait for DB (skip if SKIP_DB_WAIT=true)
# ---------------------------------------------------------------------
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-60}"
if [ "${SKIP_DB_WAIT:-false}" != "true" ]; then
  log "waiting up to ${DB_WAIT_TIMEOUT}s for ${DB_HOST}:${DB_PORT}"
  i=0
  while [ "$i" -lt "$DB_WAIT_TIMEOUT" ]; do
    # Read credentials via getenv() inside PHP — never interpolate $DB_PASSWORD
    # into the shell command, since a single quote or shell metacharacter in
    # the password would either break the PDO call or be a shell-injection
    # vector if .env is ever attacker-controlled.
    # shellcheck disable=SC2016 # intentional: PHP reads env vars itself
    if php -r '
      try {
        new PDO(
          "mysql:host=" . getenv("DB_HOST")
            . ";port=" . getenv("DB_PORT")
            . ";dbname=" . getenv("DB_DATABASE"),
          getenv("DB_USERNAME"),
          getenv("DB_PASSWORD"),
          [PDO::ATTR_TIMEOUT => 3]
        );
        exit(0);
      } catch (Exception $e) { exit(1); }
    ' 2>/dev/null; then
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
# 5. Migrations — wrapped in maintenance mode (mirrors upstream upgrade.php)
# ---------------------------------------------------------------------
# Upstream runs `php artisan down` before migrate and `php artisan up` after,
# so users hitting the app mid-migration see Laravel's maintenance page
# instead of partial-state 500s. We do the same.
#
# `down` and `up` are made resilient: failures are logged but never abort
# the entrypoint, so a stale "down" file from a previous crash doesn't
# wedge the container in maintenance mode forever. The MIGRATE result is
# captured separately and re-raised AFTER `up` runs — that's the load-
# bearing invariant. We never want to leave the app in maintenance mode
# just because migrations failed.
cd /var/www/html
if [ "$SKIP_MIGRATIONS" = "true" ]; then
  log "SKIP_MIGRATIONS=true — skipping artisan down/migrate/up"
else
  log "entering maintenance mode (php artisan down)"
  su-exec www-data php artisan down --no-interaction \
    || log "WARNING: artisan down failed — continuing with migrate"

  migrate_rc=0
  log "running php artisan migrate --force"
  su-exec www-data php artisan migrate --force --no-interaction || migrate_rc=$?

  log "leaving maintenance mode (php artisan up)"
  su-exec www-data php artisan up --no-interaction \
    || log "WARNING: artisan up failed — container may still be in maintenance mode"

  if [ "$migrate_rc" -ne 0 ]; then
    log "ERROR: artisan migrate failed with exit $migrate_rc — aborting"
    exit "$migrate_rc"
  fi
fi

# ---------------------------------------------------------------------
# 6. Clear stale caches, then re-cache config + routes
# ---------------------------------------------------------------------
# Upstream's post-upgrade sequence clears config / cache / route / view
# before re-caching. config:cache implicitly clears the cached config
# (it overwrites bootstrap/cache/config.php), but it does NOT clear
# Laravel's general application cache — that's what `cache:clear` does.
# Stale cached settings rows can survive image-version bumps without it.
log "clearing stale application cache"
su-exec www-data php artisan cache:clear 2>/dev/null || true

log "caching config, routes, events"
su-exec www-data php artisan config:cache
su-exec www-data php artisan route:cache 2>/dev/null || true
su-exec www-data php artisan event:cache 2>/dev/null || true
su-exec www-data php artisan view:clear

log "ready — exec into CMD: $*"
exec "$@"

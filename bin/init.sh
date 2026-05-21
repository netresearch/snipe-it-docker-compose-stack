#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# init.sh — generate APP_KEY + random DB passwords, write to .env.
#
# Idempotent: existing non-empty values are preserved; only empty/missing
# variables are populated. APP_KEY is NEVER overwritten — re-generating it
# would invalidate every encrypted column and signed session in the DB.

set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env"
ENV_EXAMPLE=".env.example"
IMAGE_FOR_KEYGEN="ghcr.io/netresearch/snipe-it-php-fpm:latest"

log() { printf '\033[1;34m[init]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[init]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[init]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
# 1. Bootstrap .env from .env.example if missing
# ---------------------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  [ -f "$ENV_EXAMPLE" ] || fail "$ENV_EXAMPLE not found — run from repo root"
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  log "created $ENV_FILE from $ENV_EXAMPLE"
fi

# ---------------------------------------------------------------------
# 2. Helpers — read + write .env keys in place
# ---------------------------------------------------------------------
read_env() {
  # Return the value of KEY from $ENV_FILE, or empty if unset/blank.
  local key="$1"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print }' "$ENV_FILE" \
    | head -1
}

write_env() {
  # Set KEY=VALUE in .env (line is created if missing).
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # Escape | (used as sed delimiter) in the value
    local escaped="${value//|/\\|}"
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

random_pw() {
  # 32 chars URL-safe base64; no '/', '+', '=' to avoid env-quoting surprises
  openssl rand -base64 32 | tr -d '/+=\n' | head -c 32
}

# ---------------------------------------------------------------------
# 3. APP_KEY — generate via Laravel artisan if empty
# ---------------------------------------------------------------------
APP_KEY_CURRENT=$(read_env APP_KEY)
if [ -z "$APP_KEY_CURRENT" ]; then
  log "APP_KEY empty — generating via artisan key:generate"
  if ! command -v docker >/dev/null 2>&1; then
    fail "docker not found — install docker first"
  fi
  # `key:generate --show` prints the key to stdout
  KEY=$(docker run --rm "$IMAGE_FOR_KEYGEN" \
    php /var/www/html/artisan key:generate --show 2>&1 \
    | tail -1 \
    | tr -d '\r')
  if [[ "$KEY" != base64:* ]]; then
    fail "artisan output didn't look like a key (got: $KEY)"
  fi
  write_env APP_KEY "$KEY"
  log "wrote APP_KEY=base64:<32 bytes>"
else
  log "APP_KEY already set — keeping (re-generating would invalidate sessions/encrypted data)"
fi

# ---------------------------------------------------------------------
# 4. DB passwords — generate random if empty
# ---------------------------------------------------------------------
for var in DB_PASSWORD DB_ROOT_PASSWORD; do
  CUR=$(read_env "$var")
  if [ -z "$CUR" ]; then
    NEW=$(random_pw)
    write_env "$var" "$NEW"
    log "wrote $var=<32 random chars>"
  else
    log "$var already set — keeping"
  fi
done

# ---------------------------------------------------------------------
# 5. Sanity: APP_URL present (default from .env.example is http://localhost:8000)
# ---------------------------------------------------------------------
APP_URL_CURRENT=$(read_env APP_URL)
if [ -z "$APP_URL_CURRENT" ]; then
  write_env APP_URL "http://localhost:8000"
  log "wrote APP_URL=http://localhost:8000 (override for public deployment)"
fi

# ---------------------------------------------------------------------
# 6. .env permissions — passwords inside, not world-readable
# ---------------------------------------------------------------------
chmod 0600 "$ENV_FILE"

cat <<'EOF'

╔═══════════════════════════════════════════════════════════════════╗
║  ✓ init complete — .env ready                                     ║
║                                                                   ║
║  Next:                                                            ║
║    make up            # bring stack up (db, valkey, app, web,    ║
║                       #   scheduler, backup)                      ║
║    make logs          # follow app logs                           ║
║                                                                   ║
║  Override APP_URL in .env when deploying behind a reverse proxy.  ║
╚═══════════════════════════════════════════════════════════════════╝

EOF

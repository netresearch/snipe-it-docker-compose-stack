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

# Restrict file creation mode for the rest of the script — passwords land in
# .env BEFORE the explicit chmod below, so umask is the only thing preventing
# a 0644 readable window.
umask 077

cd "$(cd "$(dirname "$0")/.." && pwd)" || { echo "init: cannot cd repo root" >&2; exit 1; }
[ -f compose.yml ] || { echo "init: compose.yml not found at repo root" >&2; exit 1; }

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
  # awk-based replacement — sidesteps sed-escaping pitfalls (&, \, etc.)
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    BEGIN { done=0 }
    $0 ~ "^"k"=" { print k"="v; done=1; next }
    { print }
    END { if (!done) print k"="v }
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
}

# NOTE: output is NOT valid base64 — padding (`=`) and URL-unsafe chars (`/`, `+`)
# are stripped. It's a 32-char URL-safe random string used as a DB password,
# chosen to avoid env-quoting / shell-escaping surprises in .env / docker-compose.
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
  command -v docker >/dev/null 2>&1 \
    || fail "docker not found — install docker first"
  docker info >/dev/null 2>&1 \
    || fail "Docker daemon not reachable — start Docker Desktop / dockerd first"

  # Capture stdout (the key) and stderr separately so failures surface verbatim
  # instead of being mangled into the parse error.
  # `--entrypoint php` bypasses the image's runtime entrypoint, which would
  # otherwise hard-fail on missing APP_KEY (chicken-and-egg — we're trying
  # to GENERATE the APP_KEY).
  TMP_OUT=$(mktemp); TMP_ERR=$(mktemp)
  if ! docker run --rm --pull=missing --entrypoint php "$IMAGE_FOR_KEYGEN" \
        /var/www/html/artisan key:generate --show --no-ansi \
        >"$TMP_OUT" 2>"$TMP_ERR"; then
    cat "$TMP_ERR" >&2
    rm -f "$TMP_OUT" "$TMP_ERR"
    fail "artisan key:generate failed (see stderr above)"
  fi
  KEY=$(grep -oE '^base64:[A-Za-z0-9+/=]+' "$TMP_OUT" | tail -1)
  rm -f "$TMP_OUT" "$TMP_ERR"
  [ -n "$KEY" ] || fail "could not extract APP_KEY from artisan output"
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

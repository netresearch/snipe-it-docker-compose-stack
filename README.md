# Snipe-IT Docker Compose Stack

[![Build Status](https://github.com/netresearch/snipe-it-docker-compose-stack/actions/workflows/build.yml/badge.svg)](https://github.com/netresearch/snipe-it-docker-compose-stack/actions/workflows/build.yml)
[![Lint](https://github.com/netresearch/snipe-it-docker-compose-stack/actions/workflows/lint.yml/badge.svg)](https://github.com/netresearch/snipe-it-docker-compose-stack/actions/workflows/lint.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)

Opinionated, hardened, **daily-built** [Snipe-IT](https://snipeitapp.com/) deployment — a 6-service docker-compose stack with our own slim **PHP 8.5 / Alpine** php-fpm image, plus dev overrides with mailpit and adminer for friction-free local development.

Made by [Netresearch DTT GmbH](https://www.netresearch.de/) on the back of a real Snipe-IT inventory evaluation. Battle-scarred defaults, not a barebones starter.

## What's in the stack

```
        ┌─── web ─────── nginx:alpine
        │
   client ──► db ──── mariadb:11 (binlog enabled)
        │
        ├─── valkey ─── valkey/valkey:9-alpine
        │
        └─── app ───── ghcr.io/netresearch/snipe-it-php-fpm  ◄── built daily
                       │
                       └─◄ scheduler ── ghcr.io/netresearch/ofelia
                              (runs `php artisan schedule:run` per minute
                               via docker exec, label-driven)

   one-shot init: `app-assets` populates a shared volume with Snipe-IT's
   public/ files so nginx can serve them statically.
```

| Service | Image | Purpose |
|---|---|---|
| **db** | `mariadb:11` | Primary store, binlog enabled for PITR |
| **valkey** | `valkey/valkey:9-alpine` | Cache + sessions + queue backend (Redis-compatible) |
| **app** | `ghcr.io/netresearch/snipe-it-php-fpm` | **Our** php-fpm image, Snipe-IT app code |
| **web** | `nginx:alpine` | Static asset serving + fastcgi → `app:9000` |
| **scheduler** | `ghcr.io/netresearch/ofelia` | `php artisan schedule:run` per minute via docker labels |
| **app-assets** | (same as `app`) | One-shot init: syncs `public/` into the shared volume |

## What's in our image

The php-fpm image (`ghcr.io/netresearch/snipe-it-php-fpm`) is intentionally narrow — just PHP + Snipe-IT app code:

| | |
|---|---|
| **Base** | `php:8.5-fpm-alpine` |
| **PHP extensions** | bcmath, gd, intl, ldap, mbstring, opcache, pdo_mysql, redis, xml, zip |
| **Runtime user** | `www-data` (non-root) |
| **Init** | `tini` as PID 1 → entrypoint → php-fpm |
| **Healthcheck** | `cgi-fcgi` ping on 127.0.0.1:9000 |
| **Multi-arch** | linux/amd64, linux/arm64 |
| **License** | AGPL-3.0-or-later (matched Snipe-IT upstream) |

## Why does this exist?

The official `snipe/snipe-it` image is fine but conservative:
- ships PHP 8.3 (Ubuntu) or 8.4 (Alpine) — not the upstream-recommended 8.5
- the Alpine variant has [no built-in scheduler](https://github.com/grokability/snipe-it/issues), so Laravel's scheduled tasks (audit reminders, expected-checkin alerts, license expiry warnings) silently don't run
- new versions ship every 3-6 months — base-OS CVEs accrue between releases

This stack fixes all three:
1. **PHP 8.5** (upstream-supported via `composer.json` `^8.2`)
2. **Scheduler runs by default** via [ofelia](https://github.com/netresearch/ofelia) (Netresearch's fork), label-driven, no in-container cron
3. **Daily rebuild** picks up Alpine + PHP + Composer-dep patches without waiting for an upstream Snipe-IT release

## Quick start

```bash
git clone https://github.com/netresearch/snipe-it-docker-compose-stack.git
cd snipe-it-docker-compose-stack
cp .env.example .env

# Generate an APP_KEY (one-shot)
docker run --rm ghcr.io/netresearch/snipe-it-php-fpm:latest \
  php /var/www/html/artisan key:generate --show
# Paste the output into .env as APP_KEY=base64:...

# Set DB_PASSWORD, DB_ROOT_PASSWORD, APP_URL in .env, then:
docker compose up -d
docker compose logs -f app
```

Open `http://localhost:8000` and complete the setup wizard.

## Dev mode

```bash
cp compose.override.yml.example compose.override.yml
docker compose up -d
```

Brings up the same stack plus:
- **mailpit** at `http://localhost:8025` — SMTP sink + web UI to catch outgoing notifications
- **adminer** at `http://localhost:8081` — DB browser
- Exposed db (3306) + valkey (6379) host ports for external clients
- `APP_DEBUG=true`, `APP_ENV=local`

## TLS / reverse proxy

The default `web` service binds plain HTTP on `${SNIPEIT_HTTP_PORT:-8000}`. Front it with your TLS terminator of choice. We ship one example:

```bash
# Traefik (requires an existing traefik network)
docker compose -f compose.yml -f examples/compose.traefik.yml up -d
```

See [`examples/`](examples/) for the complete Traefik recipe; alternatives (Caddy, host-side nginx) follow the same overlay pattern.

## Image tags

| Tag | Description |
|---|---|
| `latest` | Latest stable Snipe-IT release, freshly built |
| `vX.Y.Z` | Pinned Snipe-IT release (e.g. `v8.5.0`) |
| `vX.Y.Z-YYYYMMDD` | Reproducible date-stamped variant for audit trails |
| `vX.Y` | Latest patch of a minor (e.g. `v8.5`) |
| `vX` | Latest minor of a major (e.g. `v8`) |
| `sha-<commit>` | Per-commit build of this repo |

Both `linux/amd64` and `linux/arm64`.

## Configuration

Required env vars (see [`.env.example`](.env.example) for the complete reference):

| Variable | Description |
|---|---|
| `APP_KEY` | Laravel application key — generate once, never rotate |
| `APP_URL` | Public URL, no trailing slash |
| `DB_PASSWORD` | Application DB user password |
| `DB_ROOT_PASSWORD` | MariaDB root (only used at init) |

Operational toggles:

| Variable | Default | Description |
|---|---|---|
| `SNIPE_IT_IMAGE_TAG` | `latest` | Pin to a specific image build |
| `CACHE_DRIVER` / `SESSION_DRIVER` / `QUEUE_DRIVER` | `redis` | Laravel driver name (RESP protocol). Flip to `file`/`file`/`sync` if you remove the valkey service |
| `SKIP_MIGRATIONS` | `false` | Skip `php artisan migrate --force` at container start |
| `TZ` | `UTC` | IANA timezone |

Docker secrets supported via `*_FILE` env vars (e.g. `DB_PASSWORD_FILE=/run/secrets/db_password`).

## Security posture

- **Non-root execution** — `www-data` runs php-fpm; entrypoint drops privileges with `su-exec` after volume permission repair
- **No new privileges** — `security_opt: no-new-privileges:true` on every service
- **Capability drop** — `cap_drop: ALL` on `web` with minimal re-adds
- **Read-only mounts** — nginx reads `app-public` and `app-storage` read-only
- **tmpfs** — `/tmp`, `/var/cache/nginx`, `/var/run` are tmpfs on `web`
- **Pinned upstream** — Snipe-IT git-tag-pinned via `.snipe-it-version`, image SHAs pinned in Dockerfile
- **Daily rebuild** — picks up base-image CVEs without waiting for upstream
- **Supply chain** — SLSA build provenance + SBOM (cosign signing post-MVP)

## Upgrading

```bash
# 1. Backup (the binlog enables PITR but a logical dump is the operational baseline)
docker compose exec db sh -c \
  'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction --routines --triggers snipeit' \
  | gzip > "backup-$(date +%Y%m%d-%H%M%S).sql.gz"

# 2. Pull + restart
docker compose pull
docker compose up -d
docker compose logs -f app
```

The `app` entrypoint runs `php artisan migrate --force` on every start. No DDL grant dance required — this stack's DB user is the app's own MariaDB account with full schema rights inside its database.

## Related projects

- [grokability/snipe-it](https://github.com/grokability/snipe-it) — upstream Snipe-IT itself
- [snipe/snipe-it](https://hub.docker.com/r/snipe/snipe-it) — official Docker image
- [netresearch/ofelia](https://github.com/netresearch/ofelia) — the scheduler this stack uses
- [netresearch/phpbu-docker](https://github.com/netresearch/phpbu-docker) — Netresearch's hardened phpbu image (sibling project)

## Contributing

PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md). Security issues: see [`SECURITY.md`](SECURITY.md).

## License

[AGPL-3.0-or-later](LICENSE) — matched to Snipe-IT upstream.

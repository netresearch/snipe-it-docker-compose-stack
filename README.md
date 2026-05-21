<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Snipe-IT Docker Compose Stack

[![Build Status](https://github.com/netresearch/snipe-it-docker-compose-stack/actions/workflows/build.yml/badge.svg)](https://github.com/netresearch/snipe-it-docker-compose-stack/actions/workflows/build.yml)
[![Lint](https://github.com/netresearch/snipe-it-docker-compose-stack/actions/workflows/lint.yml/badge.svg)](https://github.com/netresearch/snipe-it-docker-compose-stack/actions/workflows/lint.yml)
[![License: MIT (code)](https://img.shields.io/badge/code-MIT-blue.svg)](LICENSE-MIT)
[![License: CC-BY-SA-4.0 (content)](https://img.shields.io/badge/content-CC--BY--SA--4.0-green.svg)](LICENSE-CC-BY-SA-4.0)

Opinionated, hardened, **daily-built** [Snipe-IT](https://snipeitapp.com/) deployment — a 7-service docker-compose stack with our own slim **PHP 8.5 / Alpine** php-fpm image, scheduled `phpbu` backups out of the box, plus dev overrides with mailpit and adminer for friction-free local development.

Made by [Netresearch DTT GmbH](https://www.netresearch.de/) on the back of a real Snipe-IT inventory evaluation. Battle-scarred defaults, not a barebones starter.

## What's in the stack

```
        ┌─── web ─────── nginx:alpine
        │
   client ──► db ──── mariadb:11 (binlog enabled)
        │
        ├─── valkey ─── valkey/valkey:9-alpine
        │
        ├─── app ───── ghcr.io/netresearch/snipe-it-php-fpm   ◄── built daily
        │              │
        │              ├─◄ scheduler ── ghcr.io/netresearch/ofelia
        │              │      (runs `php artisan schedule:run` per minute)
        │              │
        └─── backup ── ghcr.io/netresearch/phpbu-docker
                       └─◄ (same ofelia drives nightly `phpbu` runs)

   one-shot init: `app-assets` populates a shared volume with Snipe-IT's
   public/ files so nginx can serve them statically.
```

| Service | Image | Purpose |
|---|---|---|
| **db** | `mariadb:11` | Primary store, binlog enabled for PITR |
| **valkey** | `valkey/valkey:9-alpine` | Cache + sessions + queue backend (Redis-compatible) |
| **app** | `ghcr.io/netresearch/snipe-it-php-fpm` | **Our** php-fpm image, Snipe-IT app code |
| **web** | `nginx:alpine` | Static asset serving + fastcgi → `app:9000` |
| **scheduler** | `ghcr.io/netresearch/ofelia` | Label-driven cron for `artisan schedule:run` (per minute) **and** the nightly `phpbu` backup |
| **backup** | `ghcr.io/netresearch/phpbu-docker` | Nightly DB dump + uploads/storage tarball with retention policy |
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
make init        # bootstraps .env: APP_KEY + random DB passwords (idempotent)
make up          # docker compose up -d
make logs-app    # follow app logs while it boots
```

Open `http://localhost:8000` and complete the setup wizard. `make help` lists every other target (`backup`, `upgrade`, `clean`, `artisan CMD="..."`, …).

For public deployments, edit `APP_URL` in `.env` after `make init` and re-run `make up`.

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

Built daily, multi-arch (`linux/amd64` + `linux/arm64`), two dependency
variants. Pick a variant by tag suffix:

| Pinned (default) | Rolling (suffix `-rolling`) | Source ref | What it gives you |
|---|---|---|---|
| `latest` | `rolling` | latest stable release | Default; tracks `.snipe-it-version` |
| `8.5.0` | `8.5.0-rolling` | `refs/tags/v8.5.0` | Pin a specific Snipe-IT release |
| `8.5.0-YYYYMMDD` | `8.5.0-rolling-YYYYMMDD` | same | Reproducible dated build (audit-friendly) |
| `8.5` | `8.5-rolling` | latest patch of 8.5.x | Auto-rolls on `.x` bump |
| `8` | `8-rolling` | latest minor of 8.x | Auto-rolls on minor bump |
| `master` | `master-rolling` | `refs/heads/master` | Upstream stable branch HEAD |
| `develop` / `nightly` | `develop-rolling` / `nightly-rolling` | `refs/heads/develop` | Pre-release / bleeding edge |
| `sha-pinned-<sha>` | `sha-rolling-<sha>` | this repo's commit | Per-stack-commit build |

### Pinned vs Rolling — which should you use?

- **`pinned` (default)** — honours Snipe-IT's shipped `composer.lock`. Reproducible: rebuilding `8.5.0` at any date produces a manifest-equivalent image (modulo Alpine + PHP base-image patches). Recommended for production.
- **`-rolling`** — `composer.lock` is deleted before `composer install`, so Composer resolves fresh against `composer.json` ranges. Daily rebuild picks up transitive Composer-package CVE fixes without waiting for upstream Snipe-IT to cut a patch release. Use if you'd rather catch CVEs early than match upstream's tested dependency graph.

Each image (both variants) ships a manifest at `/var/lib/snipeit/deps.txt` —
`docker exec <container> cat /var/lib/snipeit/deps.txt` to see exactly which
versions are installed.

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

## Backups

`phpbu` runs nightly at **03:00** (ofelia-driven) and produces three artefact families in the `backups` volume:

| Path | Contents | Retention |
|---|---|---|
| `db/snipeit-db-*.sql.gz` | mariadb-dump (single-transaction, with routines) | rolling capacity (~5 GB) |
| `uploads/snipeit-uploads-*.tar.gz` | Snipe-IT uploads (`app-data` volume) | 30 days |
| `storage/snipeit-storage-*.tar.gz` | Laravel storage (`app-storage` volume) | 30 days |

On-demand backup: `make backup`. Off-host shipping: bind-mount the `backups` volume into a destination synced by your existing tool (restic, rclone, NAS-attached cron).

## Upgrading

```bash
make upgrade           # pulls latest images, recreates containers, follows logs
```

The `app` entrypoint runs `php artisan migrate --force` on every start. No DDL grant dance required — this stack's DB user is the app's own MariaDB account with full schema rights inside its database.

## Related projects

- [grokability/snipe-it](https://github.com/grokability/snipe-it) — upstream Snipe-IT itself
- [snipe/snipe-it](https://hub.docker.com/r/snipe/snipe-it) — official Docker image
- [netresearch/ofelia](https://github.com/netresearch/ofelia) — the scheduler this stack uses
- [netresearch/phpbu-docker](https://github.com/netresearch/phpbu-docker) — the backup engine this stack uses

## Contributing

PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md). Security issues: see [`SECURITY.md`](SECURITY.md).

## License

This repository uses split licensing — the right tool for each part:

| Path | License | Rationale |
|---|---|---|
| `Dockerfile`, `rootfs/`, `config/`, `compose*.yml`, `examples/`, `.github/`, `.snipe-it-version` | [MIT](LICENSE-MIT) | Code and code-shaped configuration |
| `README.md`, `CHANGELOG.md`, `docs/**` (when added), `CONTRIBUTING.md`, `SECURITY.md` (when added) | [CC-BY-SA-4.0](LICENSE-CC-BY-SA-4.0) | Prose and documentation — share-alike keeps forks open |

**The built image** (`ghcr.io/netresearch/snipe-it-php-fpm:*`) bundles AGPL-3.0 Snipe-IT application code from [grokability/snipe-it](https://github.com/grokability/snipe-it). Redistribution of the image is bound by the upstream AGPL-3.0 terms in addition to MIT for our build glue.

This split follows the [Netresearch skill-repo licensing pattern](https://github.com/netresearch?q=skill).

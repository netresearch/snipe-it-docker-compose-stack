<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Changelog

All notable changes to this image are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the image
version tracks the upstream Snipe-IT release plus a date stamp.

## [Unreleased]

### Security
- **Dropped the `SESSION_SECURE_COOKIE` → `SECURE_COOKIES`
  backward-compatibility fallback in `compose.yml`** (issue #28). The chained
  default `${SECURE_COOKIES:-${SESSION_SECURE_COOKIE:-true}}` introduced
  in PR #22 could silently disable secure cookies for any operator who
  had `SESSION_SECURE_COOKIE=false` in `.env` carried over from earlier
  docs (it was a no-op then because Snipe-IT never read that variable).
  After this change, the default is back to plain `${SECURE_COOKIES:-true}`
  — operators who ever set `SESSION_SECURE_COOKIE` in `.env` must rename
  it to `SECURE_COOKIES` explicitly. Flagged by independent security
  audit during PR #27 review.

### Changed
- License: split AGPL-3.0 (initial) → MIT for code/configs + CC-BY-SA-4.0 for
  prose. AGPL was wrong here — this repo is a deployment template, not a
  derivative of Snipe-IT. The built image still bundles AGPL Snipe-IT and
  redistributors are bound by those upstream terms.

### Added
- `make init` bootstrap: generates `APP_KEY` and random DB passwords into
  `.env`; idempotent re-runs preserve existing values
- `Makefile` with the common lifecycle targets (init/up/down/logs/backup/
  upgrade/artisan/clean)
- `backup` service using `ghcr.io/netresearch/phpbu-docker` — nightly at
  03:00 (ofelia label), DB dump + uploads + storage with 30-day / 5-GB
  retention
- Initial release: 7-service docker-compose stack with our own slim php-fpm image
  - **db** — mariadb:11 with binlog enabled
  - **valkey** — valkey/valkey:9-alpine for cache/sessions/queues (RESP-compatible Redis fork)
  - **app** — our PHP 8.5 / Alpine php-fpm image with Snipe-IT app code
  - **web** — nginx:alpine, fastcgi → app:9000, mounts our nginx config
  - **scheduler** — Netresearch's ofelia fork, label-driven cron for both `artisan schedule:run` and `phpbu`
  - **backup** — phpbu-docker; nightly archives
  - **app-assets** — one-shot init to share Snipe-IT's `public/` with nginx
- Dev override (mailpit + adminer + exposed db/redis ports + APP_DEBUG=true)
- Traefik example overlay
- Daily image rebuild via GitHub Actions cron (04:00 UTC)
- Multi-arch builds (linux/amd64, linux/arm64)
- Docker-secrets shim via `*_FILE` env vars in entrypoint
- Snipe-IT version pinned via `.snipe-it-version` (Renovate-managed)
- SLSA build provenance attestation + SBOM
- hadolint + shellcheck + yamllint + compose-validate CI

### Configuration
- Tracks Snipe-IT [v8.5.0](https://github.com/grokability/snipe-it/releases/tag/v8.5.0)

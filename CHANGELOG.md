# Changelog

All notable changes to this image are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the image
version tracks the upstream Snipe-IT release plus a date stamp.

## [Unreleased]

### Added
- Initial release: 6-service docker-compose stack with our own slim php-fpm image
  - **db** — mariadb:11 with binlog enabled
  - **redis** — redis:7-alpine for cache/sessions/queues
  - **app** — our PHP 8.5 / Alpine php-fpm image with Snipe-IT app code
  - **web** — nginx:alpine, fastcgi → app:9000, mounts our nginx config
  - **scheduler** — Netresearch's ofelia fork, label-driven `artisan schedule:run`
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

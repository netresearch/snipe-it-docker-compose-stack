<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Migration: from `snipe/snipe-it` single-container to this stack

If you currently run Snipe-IT via the upstream single-container image
(`snipe/snipe-it:vX.Y.Z-alpine`, which bundles Apache + PHP-FPM + cron in
one image) and want to switch to this opinionated multi-container stack,
this guide walks you through a downtime-bounded cutover with a rollback
path.

## What changes architecturally

| Concern | Upstream single-container | This stack |
|---------|---------------------------|------------|
| Web server | Apache (in-container) | nginx (`web` service) |
| PHP runtime | mod_php / fpm (in-container) | dedicated `app` service (`ghcr.io/netresearch/snipe-it-php-fpm`) |
| Scheduler / cron | system cron in-container | `scheduler` service (ofelia, Docker-native) |
| Cache / sessions | filesystem default | `cache` service (Valkey) |
| Database | external (you provide) | `db` service (MariaDB 11) — bring-your-own DB also supported |
| Backups | external (you provide) | optional `backup` service (phpbu-docker) |
| Image scope | everything | each container does one thing |

The PHP-FPM image is multi-arch (linux/amd64 + linux/arm64), SLSA-attested,
cosign-signed, rebuilt nightly against upstream Snipe-IT releases. The
rest of the stack uses upstream-published images for the satellite
services.

## Pre-flight

1. **Verify your current state**:
   ```bash
   docker compose -p <current-project-name> config | grep image:
   docker volume ls
   ```
   Note the volume names that hold uploads + Laravel storage. Upstream's
   image typically mounts them at `/var/lib/snipeit` and
   `/var/www/html/storage`.

2. **Confirm your `.env` has** at minimum:
   - `APP_KEY` (the base64-encoded key — this MUST survive the migration
     or all encrypted-at-rest data is unreadable)
   - `DB_PASSWORD` / `DB_HOST` / `DB_DATABASE`
   - `MAIL_*` if email is configured
   - any LDAP / SAML / SSO secrets

3. **Pick a deployment directory** for the new stack. Convention varies
   by organisation; common choices include `/srv/www/<service>`,
   `/opt/<service>`, `/home/<deploy-user>/<service>`. Throughout this
   guide we refer to the deploy directory as `$DEPLOY_DIR` — set it
   once:
   ```bash
   export DEPLOY_DIR=/srv/www/snipeit-new      # adjust to taste
   export BACKUP_DIR=/srv/backup/snipeit-migration
   export LEGACY_DIR=/srv/www/snipeit           # where your current stack lives
   mkdir -p "$BACKUP_DIR"
   ```

## Phase 1 — snapshot the current deployment

```bash
cd "$LEGACY_DIR"

# Database dump (adjust service name + credentials to match your old stack)
docker compose exec db \
  mysqldump --single-transaction -u root -p"$DB_ROOT_PASSWORD" snipeit \
  > "$BACKUP_DIR/snipeit-pre-migration.sql"

# Uploads + storage tarball.
# Replace <UPLOADS_VOLUME> + <STORAGE_VOLUME> with the actual volume
# names from `docker volume ls` — typical upstream pattern is one
# `snipeit_data` or similar single volume.
docker run --rm \
  -v <UPLOADS_VOLUME>:/uploads \
  -v "$BACKUP_DIR":/backup \
  alpine tar czf /backup/uploads.tar.gz -C /uploads .

docker run --rm \
  -v <STORAGE_VOLUME>:/storage \
  -v "$BACKUP_DIR":/backup \
  alpine tar czf /backup/storage.tar.gz -C /storage .

# .env snapshot — keep the APP_KEY and everything else
cp .env "$BACKUP_DIR/.env.pre-migration"

# Sanity-check the snapshots
ls -lah "$BACKUP_DIR"/
```

The DB dump and tarballs should be non-empty. The `.env` snapshot is
your reference for the next phase.

## Phase 2 — prepare the new stack

```bash
git clone https://github.com/netresearch/snipe-it-docker-compose-stack.git "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

cp .env.example .env
```

Edit `.env` so the critical fields match what the snapshot recorded:

- `APP_KEY` — **must be the exact same value** as before, otherwise
  encrypted columns (asset checkouts, LDAP passwords stored in DB) become
  unreadable. Copy from `$BACKUP_DIR/.env.pre-migration`.
- `DB_PASSWORD` and `DB_ROOT_PASSWORD` — pick fresh values here; the DB
  service is new and gets initialised below. Don't reuse old passwords
  unless you intentionally want them.
- `MAIL_*`, LDAP, SAML, OIDC, SSO — copy verbatim from the snapshot.

If you maintain operator-specific overrides (reverse-proxy labels,
custom volume paths, extra services), put them in `compose.override.yml`
(gitignored by default) so they survive `git pull` updates of the stack:

```yaml
# compose.override.yml — local-only overrides
services:
  web:
    labels:
      # Paste your existing reverse-proxy labels here. They applied to
      # the upstream apache service; now they apply to the nginx
      # `web` service which terminates HTTP for the stack.
      # Example for Traefik:
      # - "traefik.enable=true"
      # - "traefik.http.routers.snipeit.rule=Host(`assets.example.org`)"
```

## Phase 3 — cutover

Downtime begins. Allow ~5–10 minutes for the DB restore plus first-boot
migrations.

```bash
# 1. Stop the old stack
cd "$LEGACY_DIR"
docker compose down

# 2. Bring up DB + cache first so the restore has somewhere to land
cd "$DEPLOY_DIR"
docker compose up -d db cache
docker compose exec db sh -c 'until mysqladmin ping -u root -p"$DB_ROOT_PASSWORD" --silent; do sleep 1; done'

# 3. Restore the database
docker compose exec -T db \
  mysql -u root -p"$DB_ROOT_PASSWORD" snipeit \
  < "$BACKUP_DIR/snipeit-pre-migration.sql"

# 4. Restore uploads + storage into the new volumes
# Volume names follow Docker Compose convention: <project>_<volume>
PROJECT="$(basename "$DEPLOY_DIR")"

docker run --rm \
  -v "${PROJECT}_app-data:/data" \
  -v "$BACKUP_DIR":/backup \
  alpine tar xzf /backup/uploads.tar.gz -C /data

docker run --rm \
  -v "${PROJECT}_app-storage:/storage" \
  -v "$BACKUP_DIR":/backup \
  alpine tar xzf /backup/storage.tar.gz -C /storage

# 5. Bring up the rest
docker compose up -d --wait
```

## Phase 4 — validate

```bash
# All services healthy
docker compose ps

# HTTP reachable (adjust host/port for your reverse-proxy or direct port mapping)
curl -fsS -I http://localhost:8000/ | head -5

# Database connectivity from the app container
docker compose exec app php artisan tinker --execute='echo "Users: " . \App\Models\User::count() . PHP_EOL;'
docker compose exec app php artisan tinker --execute='echo "Assets: " . \App\Models\Asset::count() . PHP_EOL;'

# Scheduler is running (ofelia replaces cron)
docker compose logs scheduler --tail=20

# At least one full request flowed through the stack: log in via the UI,
# load a few asset detail pages, run one report. Encrypted columns
# (asset checkout history, LDAP-bound passwords) should be readable —
# if they aren't, the APP_KEY did not transfer correctly. See Rollback.
```

## Rollback

The new stack hasn't written outside its own volumes during the cutover.
If validation fails, the old stack can come back up immediately:

```bash
cd "$DEPLOY_DIR" && docker compose down
cd "$LEGACY_DIR" && docker compose up -d
```

The DB snapshot in `$BACKUP_DIR/snipeit-pre-migration.sql` is your
worst-case restore point against the legacy DB if something has been
written to it in error.

## Post-validation cleanup

After 1–2 days of stable operation:

```bash
# Archive the legacy stack directory (don't delete yet — keep for one
# more week as a belt-and-suspenders rollback)
mv "$LEGACY_DIR" "${LEGACY_DIR}.archive-$(date +%Y%m%d)"

# Rename the new deployment to the canonical name if you used a -new suffix
# (skip if your DEPLOY_DIR already has the final name)
# mv "$DEPLOY_DIR" "$LEGACY_DIR"
```

The legacy upstream image can be removed from your local Docker store:

```bash
docker image rm snipe/snipe-it:vX.Y.Z-alpine
```

The `$BACKUP_DIR` snapshots are worth keeping for ~30 days, then
prune.

## Common pitfalls

- **APP_KEY mismatch** — symptoms are silent: the UI loads, but
  asset-checkout history columns show as `���` or "decryption failed"
  warnings in `storage/logs/laravel.log`. Stop, restore APP_KEY from the
  snapshot, restart the `app` container.
- **Wrong volume name in step 4** — Compose prepends the project name
  (the directory basename by default). If you used `-p some-project` in
  the compose call, that's the prefix. `docker volume ls` after step 2
  reveals the actual names.
- **Reverse-proxy 502s after cutover** — verify the `web` service is in
  the same Docker network the proxy expects. Upstream's image listened
  on port 80 directly; this stack's `web` (nginx) does the same, but if
  your proxy was previously targeting an `app:80` container, update the
  target to `web:80`.
- **Scheduler doesn't run** — ofelia reads labels from the `app`
  service. `docker compose logs scheduler` should show
  `successfully connected to docker socket`. If it says permission
  denied, the host's `/var/run/docker.sock` isn't being passed through —
  check `compose.yml`'s `scheduler` service volume mount.

## When to revisit this guide

- Snipe-IT releases that bump `composer.json` constraints past
  currently CVE-blocked transitive deps may let you remove
  `matrix.exclude` from `.github/workflows/build.yml` (the `tag/rolling`
  cell). Currently excluded because `symfony/dom-crawler ^4.4`'s entire
  range carries advisory PKSA-5r1g-c7b7-y1zg.
- If/when the netresearch/.github reusable workflows adopt versioned
  refs (`@v1` instead of `@main`), this stack's caller workflows will
  switch — that's a stack-side change, not a migration concern, but
  watch the changelog.

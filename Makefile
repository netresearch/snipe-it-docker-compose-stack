# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ────────────────────────────────────────────────────────────────────
# Lifecycle
# ────────────────────────────────────────────────────────────────────

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

init: ## Bootstrap .env (APP_KEY + random DB passwords, idempotent)
	@./bin/init.sh

up: .env ## Start the stack (detached)
	docker compose up -d

# Guard: bringing the stack up without a populated .env poisons the db-data
# volume with an empty MARIADB_ROOT_PASSWORD that survives `make clean`.
# This rule fails before docker compose sees the empty env vars.
.env:
	@printf '\033[1;31m[make]\033[0m No .env found — run `make init` first.\n' >&2
	@exit 1

down: ## Stop the stack (preserves volumes)
	docker compose down

restart: ## Restart app + web only
	docker compose restart app web

logs: ## Tail logs (all services)
	docker compose logs -f --tail=100

logs-app: ## Tail logs (app service)
	docker compose logs -f --tail=100 app

ps: ## Show container status
	docker compose ps

# ────────────────────────────────────────────────────────────────────
# Backup / restore
# ────────────────────────────────────────────────────────────────────

backup: ## Run a backup now (normally scheduled by ofelia at 03:00)
	docker compose exec -T backup phpbu --configuration=/config/backup.json

backup-list: ## List backup archives
	docker compose exec -T backup ls -lh /backups

# ────────────────────────────────────────────────────────────────────
# Testing (local)
# ────────────────────────────────────────────────────────────────────

test-image: ## Build runtime image + run container-structure-test (image-surface check)
	docker buildx build --target runtime --platform linux/amd64 --load -t snipe-it-php-fpm:test .
	@command -v container-structure-test >/dev/null 2>&1 \
	  || { echo "Install: https://github.com/GoogleContainerTools/container-structure-test/releases"; exit 1; }
	container-structure-test test --image snipe-it-php-fpm:test --config tests/container-structure-test.yaml

test-snipeit: ## Build tester stage — runs Snipe-IT's own phpunit suite, fails the build on any failure
	docker buildx build --target tester --platform linux/amd64 .

# ────────────────────────────────────────────────────────────────────
# Upgrade
# ────────────────────────────────────────────────────────────────────

pull: ## Pull latest images
	docker compose pull

upgrade: pull up logs-app ## Pull + recreate + follow logs

# ────────────────────────────────────────────────────────────────────
# Maintenance
# ────────────────────────────────────────────────────────────────────

shell: ## Shell into the app container
	docker compose exec app sh

artisan: ## Run an artisan command (use: make artisan CMD="route:list")
	docker compose exec app php /var/www/html/artisan $(CMD)

clean: ## DESTRUCTIVE: down + delete ALL volumes (db + uploads + backups)
	@read -r -p "This deletes ALL data including the database. Type 'yes' to proceed: " ans; \
	  [ "$$ans" = "yes" ] || { echo "aborted"; exit 1; }
	docker compose down -v

.PHONY: help init up down restart logs logs-app ps backup backup-list test-image test-snipeit pull upgrade shell artisan clean

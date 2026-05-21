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

up: ## Start the stack (detached)
	docker compose up -d

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

.PHONY: help init up down restart logs logs-app ps backup backup-list pull upgrade shell artisan clean

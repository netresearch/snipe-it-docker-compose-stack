# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH

# Snipe-IT php-fpm image — only PHP + the Snipe-IT app code.
# Web serving (nginx), scheduling (ofelia), and DB (mariadb) live in
# separate containers in compose.yml. This image is single-purpose.
#
# Two stages:
#   1. builder — pulls Snipe-IT source, runs `composer install --no-dev`
#   2. runtime — minimal php-fpm with the app code, runs as www-data
#
# Build args:
#   PHP_VERSION       — base PHP version (default 8.5)
#   ALPINE_VERSION    — Alpine tag for php images (default 3.22)
#   SNIPE_IT_VERSION  — Snipe-IT git tag (default v8.5.0 — keep in sync with .snipe-it-version)

ARG PHP_VERSION=8.5
ARG ALPINE_VERSION=3.22

# =====================================================================
# Stage 1: builder
# =====================================================================
FROM php:${PHP_VERSION}-cli-alpine${ALPINE_VERSION} AS builder

# pipefail — surface errors in piped curl downloads (hadolint DL4006)
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG SNIPE_IT_VERSION=v8.5.0
# ROLLING_DEPS=true deletes Snipe-IT's composer.lock before `composer install`,
# letting Composer resolve fresh against the `^` ranges in composer.json. Used
# by the `-rolling` image variants so daily rebuilds pick up transitive CVE
# fixes without waiting for upstream to cut a release.
# Default: false — produces deterministic, audit-friendly pinned images.
ARG ROLLING_DEPS=false

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1 \
    COMPOSER_NO_AUDIT=1 \
    COMPOSER_MEMORY_LIMIT=-1

RUN set -eux; \
    apk add --no-cache \
        bash curl git unzip ca-certificates \
        autoconf gcc g++ make pkgconf \
        icu-dev libpng-dev libjpeg-turbo-dev freetype-dev \
        libxml2-dev libzip-dev oniguruma-dev openldap-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath gd intl ldap mbstring pdo_mysql xml zip \
    && curl -sS https://getcomposer.org/installer \
        | php -- --quiet --install-dir=/usr/local/bin --filename=composer \
    && composer --version

WORKDIR /build

RUN set -eux; \
    curl -fsSL "https://codeload.github.com/grokability/snipe-it/tar.gz/${SNIPE_IT_VERSION}" \
        | tar xz --strip-components=1 \
    && test -f composer.json -a -f artisan

RUN --mount=type=cache,target=/root/.composer/cache \
    set -eux; \
    if [ "${ROLLING_DEPS}" = "true" ]; then \
        echo "[rolling-variant] deleting composer.lock to resolve fresh deps"; \
        rm -f composer.lock; \
    fi; \
    composer install \
        --no-dev \
        --no-progress \
        --no-scripts \
        --prefer-dist \
        --optimize-autoloader \
    && composer dump-autoload --optimize --no-dev \
    && composer show --format=text > /build/deps-manifest.txt

RUN set -eux; \
    mkdir -p \
        storage/framework/cache/data \
        storage/framework/sessions \
        storage/framework/views \
        storage/logs \
        bootstrap/cache \
    && chmod -R 0775 storage bootstrap/cache

# =====================================================================
# Stage 2: tester — installs dev deps + runs Snipe-IT's own test suite
#
# This stage is NOT in the production image. It's built on demand for CI
# (or via `make test-image`) to catch regressions in rolling builds OR
# base-image-bump-induced PHP-extension fallout that pinned builds would
# otherwise ship silently.
# =====================================================================
FROM builder AS tester

ARG SKIP_TESTS=false

# Install dev deps now (builder did --no-dev). Failure means the dev
# composer constraints don't resolve against PHP 8.5 — surface loudly.
RUN --mount=type=cache,target=/root/.composer/cache \
    set -eux; \
    composer install --no-progress --no-scripts --prefer-dist

# Minimal test env — sqlite in-memory DB, dummy APP_KEY, no external deps
RUN set -eux; \
    cp -f .env.example .env 2>/dev/null || true; \
    echo "APP_KEY=base64:Q0lfUExBQ0VIT0xERVJfS0VZX0ZPUl9DSV9PTkxZX1VTRQ==" >> .env; \
    echo "APP_ENV=testing"   >> .env; \
    echo "DB_CONNECTION=sqlite" >> .env; \
    echo "DB_DATABASE=:memory:" >> .env; \
    echo "CACHE_DRIVER=array" >> .env; \
    echo "SESSION_DRIVER=array" >> .env; \
    echo "QUEUE_DRIVER=sync" >> .env; \
    echo "MAIL_MAILER=log" >> .env

# Run upstream tests. Snipe-IT uses phpunit + the `php artisan test`
# wrapper. Failure exits the build — perfect gate for CI.
RUN set -eux; \
    if [ "${SKIP_TESTS}" = "true" ]; then \
        echo "[tester] SKIP_TESTS=true — skipping suite"; \
        exit 0; \
    fi; \
    php artisan key:generate --force >/dev/null 2>&1 || true; \
    php artisan test --without-tty --stop-on-failure || { \
        echo "[tester] upstream test suite failed — see output above"; \
        exit 1; \
    }

# =====================================================================
# Stage 3: runtime — php-fpm only
# =====================================================================
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS runtime

# pipefail — surface errors in piped curl downloads (hadolint DL4006)
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG SNIPE_IT_VERSION=v8.5.0
ARG PHP_VERSION=8.5
ARG BUILD_DATE
ARG VCS_REF
ARG ROLLING_DEPS=false

LABEL org.opencontainers.image.title="snipe-it-php-fpm" \
      org.opencontainers.image.description="Snipe-IT ${SNIPE_IT_VERSION} on PHP ${PHP_VERSION} / Alpine — php-fpm only (use with snipe-it-docker-compose-stack)" \
      org.opencontainers.image.url="https://github.com/netresearch/snipe-it-docker-compose-stack" \
      org.opencontainers.image.source="https://github.com/netresearch/snipe-it-docker-compose-stack" \
      org.opencontainers.image.documentation="https://github.com/netresearch/snipe-it-docker-compose-stack#readme" \
      org.opencontainers.image.vendor="Netresearch DTT GmbH" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.version="${SNIPE_IT_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

RUN set -eux; \
    apk add --no-cache \
        bash ca-certificates curl tini tzdata su-exec fcgi \
        icu-libs libpng libjpeg-turbo freetype \
        libxml2 libzip oniguruma openldap \
    && apk add --no-cache --virtual .ext-build-deps \
        autoconf gcc g++ make pkgconf \
        icu-dev libpng-dev libjpeg-turbo-dev freetype-dev \
        libxml2-dev libzip-dev oniguruma-dev openldap-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    # NOTE: opcache is NOT in this list. PHP 8.5 statically builds opcache into
    # the binary (the configure command lacks --with-opcache as a build option;
    # opcache appears as a Zend Module in `php -m` out of the box). Running
    # `docker-php-ext-install opcache` against PHP 8.5 fails with
    # `cp: can't stat 'modules/*'` because there's no shared module to install.
    # Our snipe-it.ini's opcache.* settings still apply unchanged.
    && docker-php-ext-install -j"$(nproc)" \
        bcmath gd intl ldap mbstring pdo_mysql xml zip \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .ext-build-deps \
    && rm -rf /tmp/* /var/cache/apk/* /usr/src/php* /usr/local/lib/php/test \
        /usr/local/lib/php/doc

WORKDIR /var/www/html
COPY --from=builder --chown=www-data:www-data /build /var/www/html
COPY rootfs/ /

# Surface the dependency manifest for ops debugging:
#   docker exec snipe-it cat /var/lib/snipeit/deps.txt
RUN mkdir -p /var/lib/snipeit \
    && cp /var/www/html/deps-manifest.txt /var/lib/snipeit/deps.txt \
    && chmod 0644 /var/lib/snipeit/deps.txt \
    && rm -f /var/www/html/deps-manifest.txt

RUN set -eux; \
    mkdir -p /var/lib/snipeit \
    && chown -R www-data:www-data \
        /var/www/html/storage \
        /var/www/html/bootstrap/cache \
        /var/lib/snipeit \
    && chmod 0755 /usr/local/bin/entrypoint.sh

# php-fpm listens on a unix socket at /run/php-fpm/snipeit.sock (shared
# tmpfs volume between `app` and `web` in compose). NO TCP port exposed.
# Rationale: closes a FastCGI bypass — with TCP on 0.0.0.0:9000, any
# sibling container on the snipeit network could speak FastCGI directly,
# trivially bypassing nginx access control.

# /run/php-fpm must exist for php-fpm to bind the socket — compose mounts
# a tmpfs here; this RUN is the fallback if the image is run standalone.
RUN mkdir -p /run/php-fpm && chown www-data:www-data /run/php-fpm

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET \
        cgi-fcgi -bind -connect /run/php-fpm/snipeit.sock 2>/dev/null \
        | grep -q "pong" || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["php-fpm", "--nodaemonize"]

FROM php:8.4.20-cli-alpine3.22 AS php-base

RUN apk upgrade --no-cache

FROM composer/composer:2-bin AS composer-bin

FROM php:8.4.20-cli-alpine3.22 AS build

WORKDIR /app

COPY --from=composer-bin /composer /usr/local/bin/composer

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_HOME=/tmp/composer \
    COMPOSER_CACHE_DIR=/tmp/composer/cache \
    COMPOSER_MAX_PARALLEL_HTTP=4 \
    COMPOSER_PROCESS_TIMEOUT=900 \
    APP_ENV=dev

RUN apk add --no-cache git unzip

COPY composer.json composer.lock symfony.lock ./
RUN set -eux; \
    attempt=1; \
    until composer install --no-interaction --prefer-dist --no-progress --no-scripts; do \
        if [ "$attempt" -ge 3 ]; then \
            exit 1; \
        fi; \
        sleep $((attempt * 10)); \
        attempt=$((attempt + 1)); \
    done

COPY . .
RUN composer dump-autoload --optimize \
    && APP_SECRET="$(cat /proc/sys/kernel/random/uuid)" composer run-script --no-interaction post-install-cmd

FROM php-base AS runtime

WORKDIR /app

ENV APP_ENV=dev

RUN addgroup -S app && adduser -S -G app -h /app app

COPY --from=build --chown=app:app /app /app

USER app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD ["php", "-r", "exit(@file_get_contents('http://127.0.0.1:8080/api/doc.json') === false ? 1 : 0);"]

CMD ["php", "-S", "0.0.0.0:8080", "-t", "public"]

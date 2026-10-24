# syntax=docker/dockerfile:1
# Образ optomstroy/backup (16 §4.1, §4.4, §8): Alpine + postgresql17-client (pg_dump 17) + rclone + age. Расписание — BACKUP_SCHEDULE
# (cron, 5 полей) внутри контейнера, без crond и без root: цикл раз в минуту сверяет текущее время с выражением.
# Контекст сборки — каталог infra/docker/backup:
#   docker build -t optomstroy/backup:<версия> infra/docker/backup
# Секреты — только файлы /run/secrets/* (PGPASSWORD_FILE, RCLONE_CONFIG, HEALTHCHECKS_PING_URL_FILE).
# Приватный ключ age (BACKUP_AGE_IDENTITY_FILE) в образ и на сервер не попадает (OPS-004).
# Сборка локально НЕ проверялась (нет Docker) — проверяется job `test-contour` CI.

ARG BASE_IMAGE=alpine:3.23
FROM ${BASE_IMAGE}
ARG APP_UID=10002
ARG APP_GID=10002
RUN apk add --no-cache postgresql17-client rclone age tini tzdata \
 && addgroup -S -g "${APP_GID}" backup \
 && adduser -S -D -H -u "${APP_UID}" -G backup -s /sbin/nologin backup \
 && mkdir -p /backups \
 && chown "${APP_UID}:${APP_GID}" /backups
COPY --chmod=0755 backup.sh /usr/local/bin/backup.sh
USER ${APP_UID}:${APP_GID}
VOLUME ["/backups"]
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/backup.sh"]
# daemon — по расписанию BACKUP_SCHEDULE; once — один прогон (проверка в CI: `docker compose run --rm backup once`).
CMD ["daemon"]

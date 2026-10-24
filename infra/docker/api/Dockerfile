# syntax=docker/dockerfile:1
# Образ optomstroy/api — ОДИН для api, worker и migrate (D-45; 06 §7.3; 16 §4.1, §4.4). Роль задаёт команда:
#   api     — node dist/main.js     (WORKERS_ENABLED=false)
#   worker  — node dist/worker.js   (WORKERS_ENABLED=true; RM-C-007)
#   migrate — node dist/migrate.js  (одноразовый; RM-C-006; `--seed` — значения по умолчанию)
# Контекст сборки — КОРЕНЬ репозитория (нужны pos-api/ и только он); состав контекста ограничивает
# infra/docker/api/Dockerfile.dockerignore (BuildKit читает <Dockerfile>.dockerignore рядом с Dockerfile).
#   docker build -f infra/docker/api/Dockerfile -t optomstroy/api:<версия> .            # прод (стадия release)
#   docker build -f infra/docker/api/Dockerfile --target test-fixtures -t optomstroy/api:test .  # тестовый контур
# Секреты в образ не попадают: только Compose secrets (*_FILE → /run/secrets/*), infra/env/README.md §2.
# Базовый образ закреплён тегом точной версии; digest фиксируется при выпуске (RM-H). Сборка этим файлом
# локально НЕ проверялась (на машине разработки нет Docker) — проверяется job `test-contour` CI (docs/ci.md).

ARG NODE_IMAGE=node:24.18.1-alpine3.23

# ---------- 1. Зависимости (все, включая dev — нужны для tsc) ----------
FROM ${NODE_IMAGE} AS deps
WORKDIR /build
COPY pos-api/package.json pos-api/package-lock.json ./
# --ignore-scripts: install-скрипты зависимостей не исполняются (цепочка поставок, T-SEC-054).
# Нативный @node-rs/argon2 ставится готовым бинарником из optional-пакета под linux-x64-musl (без скриптов).
RUN npm ci --ignore-scripts --no-audit --no-fund

# ---------- 2. Сборка TypeScript и отбор production-зависимостей ----------
FROM deps AS build
COPY pos-api/tsconfig.json pos-api/tsconfig.build.json ./
COPY pos-api/scripts ./scripts
COPY pos-api/src ./src
RUN npm run build \
 && npm prune --omit=dev --ignore-scripts --no-audit --no-fund

# ---------- 3. Runtime: только dist, prod-зависимости, SQL миграций и seed ----------
FROM ${NODE_IMAGE} AS runtime
ARG APP_UID=10001
ARG APP_GID=10001
ENV NODE_ENV=production
# tini — корректная доставка SIGTERM и сбор зомби (graceful shutdown api/worker).
RUN apk add --no-cache tini \
 && addgroup -S -g "${APP_GID}" app \
 && adduser -S -D -H -u "${APP_UID}" -G app -s /sbin/nologin app \
 && mkdir -p /app /data/media \
 && chown "${APP_UID}:${APP_GID}" /data/media
WORKDIR /app
COPY --from=build --chown=root:root /build/node_modules ./node_modules
COPY --from=build --chown=root:root /build/dist ./dist
COPY --chown=root:root pos-api/package.json ./package.json
COPY --chown=root:root pos-api/migrations ./migrations
COPY --chown=root:root pos-api/seeds ./seeds
# Печатные формы этапа F (RM-F-004; FQ-BASE-08, FQ-DOC-07): шрифт Inter с кириллицей и шаблоны PDF — путь
# вычисляется от dist/ (../assets), без каталога GET /orders/{id}/documents/*.pdf в контейнере не работает.
COPY --chown=root:root pos-api/assets ./assets
# Код и зависимости принадлежат root и доступны процессу только на чтение; писать можно лишь в /data/media
# (том media) и /tmp (tmpfs в compose при read_only: true).
USER ${APP_UID}:${APP_GID}
EXPOSE 3000
# HEALTHCHECK в образе не задаётся: один образ работает в трёх ролях, а /health есть только у api.
# Проверка api — в compose (`wget -qO- http://127.0.0.1:3000/health`, 16 §4.4).
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/main.js"]

# ---------- 4. Тестовый контур: runtime + фикстуры 1С (FQ-INT-08; 16 §4.4 прим. (2); ADR-098) ----------
# Только для `ONEC_MODE=fixtures` (infra/compose.test.yml, `build.target: test-fixtures`): FakeOnecGateway читает
# `<корень>/contracts/onec/fixtures` относительно dist/ → в образе /contracts/onec/fixtures (только чтение, root).
# Тестовые данные в прод-образ не входят: стадия по умолчанию — `release` (ниже), она фикстур не содержит;
# prod отказывает в старте при ONEC_MODE=fixtures (16 OPS-027, env.schema.ts).
FROM runtime AS test-fixtures
# COPY выполняется от root независимо от USER; пользователь процесса (10001) наследуется от runtime.
COPY --chown=root:root contracts/onec/fixtures /contracts/onec/fixtures

# ---------- 5. Прод-образ (стадия по умолчанию: `docker build` без --target) = runtime без фикстур ----------
FROM runtime AS release

# syntax=docker/dockerfile:1
# pos-api / pos-worker / migrate — один образ (D-45; 06 §7.3; 16 §4.4). Контекст сборки — каталог pos-api/.
# Основной файл образа — infra/docker/api/Dockerfile (compose, CI, install.sh); этот — локальная сборка (CI-KI-06).
#   docker build -t optomstroy/api:local pos-api                         # стадия по умолчанию release, без фикстур 1С
#   docker build --build-context contracts=contracts --target test-fixtures -t optomstroy/api:local-fixtures pos-api
#                                                                          # ONEC_MODE=fixtures (только вне prod)
# Node 24 LTS на Alpine, multi-stage, процесс от непривилегированного пользователя `node` (uid 1000).
# Секреты в образ не попадают: только через Compose secrets (*_FILE → /run/secrets/*), см. infra/env/README.md.
# Тег базового образа фиксируется digest'ом при выпуске (RM-H); сборка этапа C не проверена — на машине нет Docker.

FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json ./
COPY scripts ./scripts
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:24-alpine AS runtime
WORKDIR /app
RUN apk add --no-cache tini
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./
COPY --chown=node:node migrations ./migrations
# seed (`node dist/migrate.js --seed`, RM-C-006): без каталога seeds/ — ENOENT.
COPY --chown=node:node seeds ./seeds
# Печатные формы этапа F (RM-F-004): шрифт Inter с кириллицей (OFL) и шаблоны PDF — путь вычисляется от dist/
# (FQ-BASE-08, FQ-DOC-07); без каталога PDF-документы в контейнере не формируются.
COPY --chown=node:node assets ./assets
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/health >/dev/null || exit 1
ENTRYPOINT ["/sbin/tini", "--"]
# api: node dist/main.js; worker: node dist/worker.js (RM-C-007); migrate: node dist/migrate.js (RM-C-006)
CMD ["node", "dist/main.js"]

# ---------- Тестовый образ: runtime + фикстуры 1С (P4-KI-09, 2026-11-24; FQ-INT-08; ADR-098) ----------
# FakeOnecGateway (ONEC_MODE=fixtures) читает каталог при старте: путь по умолчанию — `<корень>/contracts/onec/fixtures`
# относительно dist/integrations/onec/ (../../../../), т. е. при WORKDIR /app — /contracts/onec/fixtures. Без каталога
# api и worker с ONEC_MODE=fixtures не стартуют. Каталог contracts/ лежит вне контекста pos-api/, поэтому он передаётся
# именованным контекстом BuildKit (`--build-context contracts=contracts`), и из него копируются ТОЛЬКО onec/fixtures.
# Стадия собирается только по `--target test-fixtures`; стадия по умолчанию (release, ниже) фикстур не содержит,
# prod с ONEC_MODE=fixtures отказывает в старте (OPS-027). Сборка не проверена — на машине разработки нет Docker.
FROM runtime AS test-fixtures
COPY --from=contracts --chown=root:root onec/fixtures /contracts/onec/fixtures
LABEL org.optomstroy.onec-fixtures="true"

# ---------- Образ по умолчанию (`docker build` без --target) = runtime без фикстур ----------
FROM runtime AS release

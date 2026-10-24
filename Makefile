# «Оптомстрой POS» — команды тестового контура и контрактов (RM-C-011, RM-C-012). Описание — docs/ci.md.
# Требуется GNU make и POSIX-shell: Linux/macOS, CI-раннер ubuntu-latest; на Windows — Git Bash/WSL с make
# (на машине разработки make и Docker нет — цели test-* выполняются в CI, job `test-contour`).
#
#   make test-up          секреты → сборка образов → migrate (--seed) → up -d → ожидание healthy
#   make test-smoke       smoke e2e через pos-proxy (Caddy) — pos-api/test/e2e/smoke.e2e-spec.ts
#   make test-check       проверки контура: ports только у caddy, internal-сеть, состав таблиц, повтор migrate, backup
#   make test-down        остановить контур и удалить его контейнеры, сети и тома
#   make gen              перегенерировать производные файлы из contracts/ (результат коммитится)
#   make check-contracts  проверки контрактов без Docker (те же команды, что job contracts-lint, кроме psql/генератора клиента)

SHELL := /bin/sh
.DEFAULT_GOAL := help

PYTHON          ?= python3
PY              := $(PYTHON) -I -X utf8
NPX             ?= npx
REDOCLY_VERSION ?= 2.59.0
COMPOSE         := docker compose -f infra/compose.test.yml
CRED_DIR        := infra/secrets
CADDY_ROOT_CA   := $(CRED_DIR)/caddy-root.crt
AGE_KEY         := $(CRED_DIR)/backup_age.key
SMOKE_BASE_URL  ?= https://localhost
TMP             ?= /tmp/optomstroy-make

.PHONY: help test-secrets test-build test-up test-wait test-smoke test-check test-logs test-down gen check-contracts

help:
	@sed -n 's/^#   make /make /p' Makefile

# ---------------------------------------------------------------------------------------------------------------
# Тестовый контур (RM-C-012)
# ---------------------------------------------------------------------------------------------------------------

test-secrets:
	@sh infra/docker/scripts/gen-test-secrets.sh $(CRED_DIR)

test-build: test-secrets
	$(COMPOSE) build api backup

# Тестовая пара ключей age для backup (публичная часть → BACKUP_AGE_RECIPIENT). Только для тестового контура:
# на сервере приватный ключ age не хранится (16 §4.3, OPS-004).
$(AGE_KEY):
	@umask 077; docker run --rm --entrypoint age-keygen optomstroy/backup:$${BACKUP_TAG:-test} > $(AGE_KEY) 2>/dev/null
	@chmod 644 $(AGE_KEY)
	@echo "создан: $(AGE_KEY) (тестовая пара age)"

# Команды печатаются (без @): журнал CI должен показывать `docker version` и `docker compose … up -d` (RM-C-011 п. 4).
test-up: test-build $(AGE_KEY)
	docker version
	export BACKUP_AGE_RECIPIENT="$$(sed -n 's/^# public key: //p' $(AGE_KEY))"; \
	set -e; \
	$(COMPOSE) run --rm migrate; \
	$(COMPOSE) up -d; \
	echo "docker compose -f infra/compose.test.yml up -d: код $$?"
	@$(MAKE) --no-print-directory test-wait

test-wait:
	@echo "ожидание healthy: api"; \
	for i in $$(seq 1 60); do \
	  cid="$$($(COMPOSE) ps -q api)"; \
	  st="$$(docker inspect -f '{{.State.Health.Status}}' "$$cid" 2>/dev/null || echo none)"; \
	  if [ "$$st" = healthy ]; then echo "api: healthy"; break; fi; \
	  if [ $$i -eq 60 ]; then echo "api не стал healthy за 180 с (статус: $$st)"; $(COMPOSE) ps -a; $(COMPOSE) logs --no-color --tail=200; exit 1; fi; \
	  sleep 3; \
	done
	@for i in $$(seq 1 30); do \
	  if $(COMPOSE) cp caddy:/data/caddy/pki/authorities/local/root.crt $(CADDY_ROOT_CA) >/dev/null 2>&1; then echo "корневой сертификат Caddy: $(CADDY_ROOT_CA)"; exit 0; fi; \
	  sleep 2; \
	done; echo "корневой сертификат внутреннего CA Caddy не получен"; $(COMPOSE) logs --no-color --tail=100 caddy; exit 1

test-smoke:
	cd pos-api && SMOKE_BASE_URL=$(SMOKE_BASE_URL) NODE_EXTRA_CA_CERTS=$(CURDIR)/$(CADDY_ROOT_CA) \
	  npm run test:e2e -- smoke

# Проверки контура (RM-C-012 пп. 1, 3; 16 §8): ports только у caddy, сеть backend internal, состав таблиц после
# migrate, идемпотентность повторного migrate, зашифрованный дамп backup.
test-check:
	@mkdir -p $(TMP)
	$(COMPOSE) config --format json > $(TMP)/compose.json
	$(PY) infra/docker/scripts/check_compose_test.py $(TMP)/compose.json
	$(COMPOSE) exec -T -e PGOPTIONS="-c app.env=$${APP_ENV:-staging}" postgres \
	  sh -c 'psql -v ON_ERROR_STOP=1 -q -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -f -' < scripts/check_tables.sql
	$(COMPOSE) run --rm migrate
	@export BACKUP_AGE_RECIPIENT="$$(sed -n 's/^# public key: //p' $(AGE_KEY))"; \
	$(COMPOSE) run --rm backup once && \
	$(COMPOSE) run --rm --entrypoint sh backup -c 'ls -l /backups && test -n "$$(ls /backups/*.dump.age 2>/dev/null)"'

test-logs:
	$(COMPOSE) logs --no-color --tail=300

test-down:
	$(COMPOSE) down -v --remove-orphans

# ---------------------------------------------------------------------------------------------------------------
# Контракты (CONTRIBUTING.md §6; 13 §5.1, §5.3)
# ---------------------------------------------------------------------------------------------------------------

# Производные файлы из contracts/. После `make gen` изменения коммитятся; CI (contracts-lint) проверяет, что
# повторная генерация даёт пустой diff. Dart-enum-ы в pos-app появятся в RM-C-004 (тогда добавить сюда).
gen:
	$(PY) scripts/build_openapi.py
	$(PY) scripts/build_arb.py
	$(PY) scripts/gen_rbac_seed.py
	$(PY) scripts/gen_tokens_dart.py pos-app/lib/design_system/tokens
	$(PY) scripts/sync_contracts.py
	cd pos-api && npm run gen:enums && npm run gen:permissions

# Все проверки contracts-lint, которые выполнимы без Docker и Java. DDL — одноразовым PostgreSQL 17 из tools/pg
# (в CI — psql на сервисе postgres:17). Генерация клиента dart-dio (шаг 4) — только в CI.
check-contracts:
	@rm -rf $(TMP) && mkdir -p $(TMP)
	$(PY) scripts/build_openapi.py --check
	$(NPX) --yes @redocly/cli@$(REDOCLY_VERSION) lint contracts/openapi/pos-api.v1.yaml
	$(PY) scripts/check_api_paths.py
	$(PY) scripts/check_api_permissions.py --require-operations
	$(PY) scripts/check_openapi_dictionaries.py
	$(PY) scripts/check_enum_triangle.py
	$(NPX) --yes @redocly/cli@$(REDOCLY_VERSION) lint contracts/onec/onec-http-service.v1.yaml
	$(PY) scripts/check_onec_paths.py
	$(PY) -c "import json, jsonschema; jsonschema.Draft202012Validator(json.load(open('contracts/design-tokens/tokens.schema.json', encoding='utf-8'))).validate(json.load(open('contracts/design-tokens/tokens.json', encoding='utf-8'))); print('tokens.json: OK')"
	$(PY) scripts/gen_tokens_dart.py $(TMP)/tokens_a
	$(PY) scripts/gen_tokens_dart.py $(TMP)/tokens_b
	diff -r $(TMP)/tokens_a $(TMP)/tokens_b
	$(PY) scripts/gen_tokens_dart.py pos-app/lib/design_system/tokens --check
	$(PY) scripts/check_contrast.py
	$(PY) scripts/build_arb.py --check
	$(PY) scripts/check_arb_keys.py
	$(PY) -c "import json, jsonschema; jsonschema.Draft202012Validator(json.load(open('contracts/enums.schema.json', encoding='utf-8'))).validate(json.load(open('contracts/enums.json', encoding='utf-8'))); print('enums.json: OK')"
	$(PY) scripts/check_enums.py
	$(PY) scripts/gen_enums.py $(TMP)/enums_a
	$(PY) scripts/gen_enums.py $(TMP)/enums_b
	diff -r $(TMP)/enums_a $(TMP)/enums_b
	$(PY) scripts/gen_rbac_seed.py --check
	$(PY) scripts/sync_contracts.py --check
	$(PY) scripts/check_env_example.py
	$(PY) scripts/check_repo_layout.py
	bash scripts/check_no_double_money.sh
	node tools/pg/run-sql.mjs --set app.env=test --repeat-strict pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql pos-api/db/migrations-dev/0001_dev_outbox.sql --check scripts/check_tables.sql
	node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_tables.sql
	node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql pos-api/db/migrations-dev/0001_dev_outbox.sql --check pos-api/test/sql/check_ddl_behavior.sql
	cd pos-api && npm run check:permissions
	@echo "check-contracts: все проверки пройдены"

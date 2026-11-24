#!/usr/bin/env python3
"""Проверка серверных контуров и комплекта развёртывания (16 §4.1–§4.5, §7, §8, §11; RUNBOOK).

Вход — один из двух вариантов:
  * сам YAML (`infra/compose.prod.yml`) — без Docker. Проверяются конфигурации, которые реально запускает обёртка
    bin/dc (слияние как в Compose: карты — по ключам, списки secrets/networks — объединение, volumes — по точке
    монтирования; подстановка `${VAR…}` — значениями шаблонов):
      рабочий контур  — compose.prod.yml, с каждым дополнением compose.prod.*.yml, HS+OData, HS+CA и со всеми;
      тестовая копия  — те же наборы + compose.staging.yml последним, значения prod.env.example + test.env.example;
      общий caddy     — compose.edge.yml и compose.edge.yml + compose.edge.test.yml.
    Дополнительно сверяются: имена prod.env.example с каноническим перечнем 16 §4.3 (логика scripts/check_env_example.py)
    и со схемой pos-api (env.schema.ts: имена, типы, enum-значения), формат шаблонов .env (у пустой переменной нет
    встроенного комментария — Compose прочитал бы его как значение), безопасные значения первого запуска, замены
    test.env.example, константы infra/scripts/lib.sh (секреты, наборы 1С, GID, uid, каталоги, файлы комплекта),
    источники bind-mount, Caddyfile.edge и сайты (сниппет api_site = сайт infra/caddy/Caddyfile CI-контура),
    расписание копии вне ночных заданий синхронизации;
  * нормализованная конфигурация `bin/dc config --format json > cfg.json` или `bin/dc-edge config --format json`
    (на сервере с Docker) — проверяется то, что реально запустит Docker (профиль — по имени проекта).

Проверки контура (prod и test): ровно сервисы api, worker, migrate, postgres, backup; портов хоста нет (80/443 —
только у общего caddy); у postgres нет ports и expose, он только в internal-сети backend; сеть edge — внешняя с
явным именем, backend — internal; non-root user, read_only, cap_drop ALL у api/worker/migrate/backup; postgres —
non-root; no-new-privileges у всех; restart unless-stopped|always (migrate — "no"); healthcheck у api, worker,
postgres, backup (у backup — `backup.sh health`: отметки выгрузки вне сервера, архивация WAL, базовая копия); непрерывная
копия WAL у postgres (wal_level=replica, archive_mode из BACKUP_PITR, archive_timeout=60, archive_command —
wal-archive.sh, спул walspool смонтирован только у postgres и backup); лимиты памяти и CPU; ротация json-file; секреты —
только file: в ./secrets/, каждый `*_FILE=/run/secrets/x` смонтирован, значения секретов в environment не
передаются; group_add с GID группы секретов; образы optomstroy/* с неизменяемым тегом и pull_policy: never, без
build:; postgres — точный тег; depends_on (migrate → completed_successfully); APP_ENV закреплён (prod | staging) и
WORKERS_ENABLED по ролям; минимум прав по секретам (EQ-AUTH-08, 16 §4.4 прим. 6); backup — роль pos_backup без
пароля суперпользователя; UTF-8 LC_CTYPE; данные — bind в /srv/optomstroy/<контур>; в тестовой копии SMSPro не
используется (SMSPRO_*_FILE пустые).
Проверки общего caddy: проект optomstroy-edge, один сервис caddy, порты ровно 80 и 443, точный тег (как в CI),
cap_drop ALL + только NET_BIND_SERVICE, без healthcheck через /health и depends_on, внешние сети edge контуров,
persistent caddy_data/caddy_config, фото контуров только для чтения.

Использование: python -I -X utf8 infra/docker/scripts/check_compose_prod.py <infra/compose.prod.yml | cfg.json>
Код выхода: 0 — OK; 1 — нарушения; 2 — ошибка ввода. Сторонний модуль только для YAML-режима — PyYAML.
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path

EXPECTED_SERVICES = {"api", "worker", "migrate", "postgres", "backup"}
PROFILES = {
    "prod": {"project": "optomstroy-prod", "edge": "optomstroy_prod_edge", "backend": "optomstroy_prod_backend",
             "data_key": "DATA_DIR", "app_env": "prod"},
    "test": {"project": "optomstroy-test", "edge": "optomstroy_test_edge", "backend": "optomstroy_test_backend",
             "data_key": "TEST_DATA_DIR", "app_env": "staging"},
}
EDGE_PROJECT = "optomstroy-edge"
SERVICE_NETWORKS = {
    "api": {"edge", "backend"},
    "worker": {"edge", "backend"},
    "backup": {"edge", "backend"},
    "migrate": {"backend"},
    "postgres": {"backend"},
}
HARDENED = ("api", "worker", "migrate", "backup")
APP_SERVICES = ("api", "worker", "migrate")
HEALTHCHECKED = ("api", "worker", "postgres", "backup")
DATA_VOLUMES = ("pgdata", "media", "backups", "walspool")
SECRETISH = re.compile(r"(PASSWORD|SECRET|TOKEN|PEPPER|PRIVATE_KEY|API_KEY|PING_URL)$")
# Переменные уровня образа/контейнера (не читаются pos-api; 16 §4.3 «Состав словаря» п. (1)).
IMAGE_LEVEL_ENV = {
    "caddy": {"CADDY_SITE_ADDRESS", "CADDY_TLS", "CADDY_TEST_SITE_ADDRESS"},
    "postgres": {"POSTGRES_USER", "POSTGRES_DB", "POSTGRES_PASSWORD_FILE", "POSTGRES_INITDB_ARGS"},
    "backup": {"PGHOST", "PGUSER", "PGDATABASE", "PGPASSWORD_FILE", "RCLONE_CONFIG", "HOME", "HEALTHCHECKS_PING_URL_FILE"},
}
# Имена уровня compose в prod.env.example (pos-api их не читает; в 16 §4.3 место — `infra/env/prod.env.example`
# (уровень compose), а не `.env`, поэтому в каноническом перечне check_env_example.py и в /.env.example их нет):
# параметры Caddyfile общего caddy и память сервисов (16 §4.3 версии 1.16, §4.4 прим. 2); BACKUP_PITR — непрерывная
# копия WAL (archive_mode postgres и цикл WAL сервиса backup; RUNBOOK §4.8) — в 16 §4.3 ещё нет (передано владельцу 16).
COMPOSE_LEVEL_KEYS = {"CADDY_SITE_ADDRESS", "CADDY_TLS", "CADDY_TEST_SITE_ADDRESS",
                      "PG_SHARED_BUFFERS", "PG_MEM_LIMIT", "API_MEM_LIMIT", "WORKER_MEM_LIMIT", "BACKUP_PITR"}
# Безопасные значения первого запуска рабочего контура (16 §4.3, §14.1 шаг 8; OPS-027, DEPLOY-051…DEPLOY-055).
SAFE_VALUES = {
    "APP_ENV": "prod",
    "LOG_LEVEL": "info",
    "APP_READ_ONLY": "false",
    "OPENAPI_PUBLIC": "false",
    "CUSTOMER_SELF_SERVICE": "true",
    "KIOSK_MODE": "false",
    "AUTH_OTP_TEST_MODE": "false",
    "AUTH_OTP_TEST_PHONES": "",
    "AUTH_OTP_TEST_CODE": "",
    "OTP_PROVIDER": "internal",
    "AUTH_BIO_ALLOW_WEAK": "off",
    "AUTH_WINDOWS_HELLO_KEY": "off",
    "SMS_PROVIDER": "smspro",
    "SMSPRO_TEST_FLAG": "false",
    "SMSPRO_DLR_MODE": "poll",
    "ONEC_ODATA_WRITE_ENABLED": "false",
    "ONEC_INBOUND_ENABLED": "false",
    "QR_WEBHOOK_ENABLED": "false",
    "WORKERS_ENABLED": "false",
    "CADDY_TEST_SITE_ADDRESS": "",
    # 15 ADR-035 (дополнение: «ежедневная плюс WAL-архив»); 16 §8.1, OPS-006, Q-033.
    "BACKUP_PITR": "on",
}
# Обязательные значения замен тестовой копии (16 §11).
TEST_REQUIRED = {"APP_ENV": "staging", "SMS_PROVIDER": "fake", "AUTH_OTP_TEST_MODE": "true", "BACKUP_REMOTE": "",
                 "CADDY_TEST_SITE_ADDRESS": "", "QR_PROVIDER": "none", "ONEC_BASE_URL": "", "AUTH_OTP_TEST_PHONES": "",
                 "AUTH_OTP_TEST_CODE": "", "BACKUP_PITR": "off"}
ALLOWED_VALUES = {"ONEC_MODE": {"extension", "odata_only"}, "QR_PROVIDER": {"none", "onec"}, "BACKUP_PITR": {"on", "off"}}
# Непрерывная копия WAL (RUNBOOK §4.8): спул и каталог archive_command в контейнерах.
WAL_SPOOL_TARGET = "/walspool"
PG_SCRIPTS_TARGET = "/opt/optomstroy/pg"
ARCHIVE_COMMAND = '"archive_command=sh /opt/optomstroy/pg/wal-archive.sh %p %f"'
BACKUP_HEALTH_MARKERS = (".offsite_ok", "BACKUP_REMOTE", "pg_stat_archiver", "last_failed_time", ".wal_offsite_ok",
                         "wal-spool-stuck", "base-backup-older-26h", "1560")
REPLICATION_HBA = "host replication pos_backup all scram-sha-256"
# Ночные задания синхронизации (16 §4.3): SYNC_IMAGES_CRON 02:30, SYNC_COUNT_CHECK_CRON 03:30, SYNC_RECONCILE_CRON
# вс 04:00 — ежедневная копия не в эти часы.
NIGHT_SYNC_HOURS = {2, 3, 4}
INTERP = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?])([^}]*))?\}")
ACTIVE_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")
INLINE_COMMENT_EMPTY = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=[ \t]+#", re.M)


# ----------------------------------------------------------------------------------------------- разбор файлов
def dotenv_value(raw: str) -> str:
    """Значение строки .env так, как его читает Docker Compose (compose-go dotenv/parser.go): пробелы после «=»
    отбрасываются; в кавычках — до закрывающей кавычки; без кавычек — до « #», затем пробелы справа. Строка
    `X=   # c` поэтому даёт «# c», а не пусто."""
    v = raw.lstrip(" \t")
    if v[:1] in ('"', "'"):
        q = v[0]
        end = v.find(q, 1)
        return v[1:end] if end > 0 else v[1:]
    return v.split(" #", 1)[0].rstrip(" \t\r")


def parse_dotenv(text: str) -> tuple[dict[str, str], list[str]]:
    """Имя → значение (по правилам Compose) и список повторов."""
    values: dict[str, str] = {}
    dups: list[str] = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        m = ACTIVE_LINE.match(line)
        if not m:
            continue
        key = m.group(1)
        if key in values:
            dups.append(key)
        values[key] = dotenv_value(m.group(2))
    return values, dups


def inline_comment_keys(text: str) -> list[str]:
    """Имена строк `ИМЯ=<пробелы># …` — Compose прочитает комментарий как значение."""
    return INLINE_COMMENT_EMPTY.findall(text)


def self_test() -> list[str]:
    """Самопроверка разбора .env (семантика compose-go)."""
    cases = [("X=", ""), ("X=v # c", "v"), ("X=   # c", "# c"), ('X="" # c', ""), ('X="a b"   # c', "a b"),
             ("X=v#c", "v#c"), ("X=  v  ", "v")]
    errors = []
    for line, want in cases:
        got = parse_dotenv(line)[0].get("X")
        if got != want:
            errors.append(f"самопроверка parse_dotenv: {line!r} → {got!r}, ожидалось {want!r}")
    if inline_comment_keys("X=   # c\nY=\nZ=v # c\n") != ["X"]:
        errors.append("самопроверка inline_comment_keys: «X=   # c» должна находиться, «Y=» и «Z=v # c» — нет")
    return errors


def interpolate(value, env: dict[str, str], used: set[str]):
    if isinstance(value, str):
        def repl(m: re.Match) -> str:
            name, op, arg = m.group(1), m.group(2), m.group(3)
            used.add(name)
            val = env.get(name, "")
            if op in (":-", "-"):
                return val if val or (op == "-" and name in env) else (arg or "")
            if op in (":?", "?"):
                return val if val else f"__{name}__"  # обязательна при деплое — образец для проверки
            return val
        return INTERP.sub(repl, value.replace("$$", "\0")).replace("\0", "$")
    if isinstance(value, list):
        return [interpolate(v, env, used) for v in value]
    if isinstance(value, dict):
        return {k: interpolate(v, env, used) for k, v in value.items()}
    return value


def mount_target(v) -> str:
    if isinstance(v, dict):
        return str(v.get("target"))
    parts = str(v).split(":")
    return parts[1] if len(parts) > 1 else parts[0]


def deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in over.items():
        out[k] = deep_merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def merge_compose(base: dict, over: dict) -> dict:
    """Слияние файлов Compose (как compose-go для используемых здесь ключей): карты — по ключам; secrets и networks
    сервиса — объединение; volumes сервиса — по точке монтирования; верхние networks/volumes/secrets — по ключам."""
    out = json.loads(json.dumps(base))
    for key, value in over.items():
        if key == "services":
            services = out.setdefault("services", {})
            for name, svc in value.items():
                target = services.setdefault(name, {})
                for skey, sval in svc.items():
                    cur = target.get(skey)
                    if skey in ("secrets", "networks") and isinstance(sval, list) and isinstance(cur, list):
                        target[skey] = cur + [s for s in sval if s not in cur]
                    elif skey == "volumes" and isinstance(sval, list) and isinstance(cur, list):
                        by_target = {mount_target(v): v for v in cur}
                        for v in sval:
                            by_target[mount_target(v)] = v
                        target[skey] = list(by_target.values())
                    elif isinstance(sval, dict) and isinstance(cur, dict):
                        target[skey] = deep_merge(cur, sval)
                    else:
                        target[skey] = sval
        elif isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"не удалось загрузить {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def schema_info(text: str) -> tuple[dict[str, str], set[str]]:
    """envShape: имя → первая строка определения; SECRET_ENV_KEYS."""
    m = re.search(r"export const envShape = \{(.*?)\n\} as const;", text, re.S)
    if not m:
        raise RuntimeError("env.schema.ts: не найден объект envShape")
    shape = {k: v.strip() for k, v in re.findall(r"^\s{2}([A-Z][A-Z0-9_]*):\s*(.*)$", m.group(1), re.M)}
    s = re.search(r"export const SECRET_ENV_KEYS = \[(.*?)\]", text, re.S)
    secrets = set(re.findall(r"'([A-Z][A-Z0-9_]*)'", s.group(1))) if s else set()
    return shape, secrets


def enum_values(defn: str, text: str) -> set[str] | None:
    m = re.match(r"z\.enum\((\[[^\]]*\]|[A-Z_][A-Z0-9_]*)\)", defn)
    if not m:
        return None
    src = m.group(1)
    if not src.startswith("["):
        c = re.search(rf"export const {src} = (\[[^\]]*\])", text)
        if not c:
            return None
        src = c.group(1)
    return set(re.findall(r"'([^']*)'", src))


def check_value_type(key: str, value: str, defn: str, schema_text: str) -> str | None:
    if value == "":
        return None
    if defn.startswith("bool("):
        return None if value in ("true", "false") else "ожидается true|false"
    m = re.match(r"int\((\d+)(?:,\s*(\d+))?(?:,\s*(\d+))?\)", defn)
    if m:
        if not re.fullmatch(r"\d+", value):
            return "ожидается целое число"
        lo = int(m.group(2)) if m.group(2) else 0
        hi = int(m.group(3)) if m.group(3) else None
        if int(value) < lo or (hi is not None and int(value) > hi):
            return f"вне диапазона {lo}…{hi if hi is not None else '∞'}"
        return None
    if defn.startswith("cron("):
        return None if re.fullmatch(r"\S+(\s+\S+){4,5}", value) else "ожидается cron из 5–6 полей"
    if defn.startswith("z.url()"):
        return None if re.match(r"https?://", value) else "ожидается URL"
    if defn.startswith("platformVersions"):
        ok = re.fullmatch(r"[a-z]+=\d+\.\d+\.\d+(,[a-z]+=\d+\.\d+\.\d+)*", value)
        return None if ok else "ожидается platform=X.Y.Z через запятую"
    allowed = enum_values(defn, schema_text)
    if allowed is not None and value not in allowed:
        return f"допустимо {sorted(allowed)}"
    return None


def lib_constants(text: str) -> dict[str, str]:
    """Константы lib.sh вида ИМЯ="значение" или ИМЯ=значение (допускается комментарий в конце строки)."""
    found = re.findall(r'^([A-Z_][A-Z0-9_]*)=(?:"([^"\n]*)"|([^\s#"]*))[ \t]*(?:#.*)?$', text, re.M)
    return {name: quoted or bare for name, quoted, bare in found}


# ----------------------------------------------------------------------------------------------- проверка контура
def as_list(value) -> list:
    if value is None:
        return []
    if isinstance(value, dict):
        return list(value)
    return [v["source"] if isinstance(v, dict) and "source" in v else v for v in value]


def as_set(value) -> set[str]:
    return {str(v) for v in as_list(value)}


def port_target(p) -> int:
    if isinstance(p, dict):
        return int(p["target"])
    return int(str(p).split(":")[-1].split("/")[0])


def env_map(env) -> dict[str, str]:
    if env is None:
        return {}
    if isinstance(env, list):
        return dict(item.split("=", 1) if "=" in item else (item, "") for item in env)
    return {k: "" if v is None else str(v) for k, v in env.items()}


def common_service_checks(name: str, svc: dict, errors: list[str]) -> None:
    if "no-new-privileges:true" not in [str(s).replace(" ", "") for s in svc.get("security_opt") or []]:
        errors.append(f"{name}: нужен security_opt no-new-privileges:true")
    limits = ((svc.get("deploy") or {}).get("resources") or {}).get("limits") or {}
    if not limits.get("memory") or not limits.get("cpus"):
        errors.append(f"{name}: нужны deploy.resources.limits.memory и cpus")
    logging = svc.get("logging") or {}
    opts = logging.get("options") or {}
    if logging.get("driver") != "json-file" or not opts.get("max-size") or not opts.get("max-file"):
        errors.append(f"{name}: нужна ротация журнала json-file (max-size, max-file; 16 §9)")


def check_config(cfg: dict, ctx: dict, profile: str) -> list[str]:
    """ctx: secrets_gid, schema_keys, schema_secret_keys, env_keys, lib, base_dir."""
    prof = PROFILES[profile]
    errors: list[str] = []
    services = cfg.get("services") or {}
    if set(services) != EXPECTED_SERVICES:
        errors.append(f"состав сервисов {sorted(services)} ≠ {sorted(EXPECTED_SERVICES)} (caddy — в {EDGE_PROJECT})")
    if cfg.get("name") != prof["project"]:
        errors.append(f"name: ожидается {prof['project']}, получено {cfg.get('name')}")

    nets = cfg.get("networks") or {}
    for key in ("edge", "backend"):
        if (nets.get(key) or {}).get("name") != prof[key]:
            errors.append(f"сеть {key}: ожидается name: {prof[key]}")
    if (nets.get("backend") or {}).get("internal") is not True:
        errors.append("сеть backend: требуется internal: true (БД без выхода наружу)")
    edge_net = nets.get("edge") or {}
    if edge_net.get("internal"):
        errors.append("сеть edge не должна быть internal (ACME, SMSPro, 1С, внешнее хранилище)")
    if edge_net.get("external") is not True:
        errors.append("сеть edge: требуется external: true (общая с caddy проекта optomstroy-edge, создают скрипты)")

    declared = cfg.get("secrets") or {}
    for sname, sdef in declared.items():
        if not isinstance(sdef, dict) or "file" not in sdef:
            errors.append(f"секрет {sname}: допускается только file: (16 §4.3)")
        elif ctx.get("base_dir") is not None and not str(sdef["file"]).startswith("./secrets/"):
            errors.append(f"секрет {sname}: файл должен лежать в ./secrets/ каталога проекта")
    declared_volumes = cfg.get("volumes") or {}
    gid = ctx.get("secrets_gid")

    for name, svc in services.items():
        if svc.get("ports"):
            errors.append(f"{name}: ports: запрещены — 80/443 публикует только общий caddy ({EDGE_PROJECT}, 16 §4.2, §11)")
        if name in SERVICE_NETWORKS and as_set(svc.get("networks")) != SERVICE_NETWORKS[name]:
            errors.append(f"{name}: сети {sorted(as_set(svc.get('networks')))} ≠ {sorted(SERVICE_NETWORKS[name])}")
        common_service_checks(name, svc, errors)
        user = str(svc.get("user") or "")
        if name in HARDENED or name == "postgres":
            if user == "" or user.split(":")[0] in ("0", "root"):
                errors.append(f"{name}: нужен непривилегированный user")
        if name in HARDENED:
            if svc.get("read_only") is not True:
                errors.append(f"{name}: нужен read_only: true")
            if "ALL" not in [str(c).upper() for c in svc.get("cap_drop") or []]:
                errors.append(f"{name}: нужен cap_drop: [ALL]")

        restart = str(svc.get("restart") or "")
        if name == "migrate":
            if restart not in ("no", ""):
                errors.append('migrate: restart должен быть "no" (одноразовый)')
        elif restart not in ("unless-stopped", "always"):
            errors.append(f"{name}: restart unless-stopped|always (после перезагрузки сервера, 16 §15.6)")
        if name in HEALTHCHECKED:
            hc = svc.get("healthcheck") or {}
            if not hc.get("test") or hc.get("disable"):
                errors.append(f"{name}: нужен healthcheck")

        image = str(svc.get("image") or "")
        if "build" in svc:
            errors.append(f"{name}: build: на сервере не используется — образы собирает install.sh/update.sh")
        if image.startswith("optomstroy/"):
            tag = image.split(":", 1)[1] if ":" in image else ""
            if tag in ("", "latest"):
                errors.append(f"{name}: образ {image} — нужен неизменяемый тег (16 §10.1)")
            if svc.get("pull_policy") != "never":
                errors.append(f"{name}: pull_policy: never — образ optomstroy/* не тянется из Docker Hub")
        if name == "postgres" and not re.fullmatch(r"postgres:1[7-9]\.\d+", image):
            errors.append(f"postgres: нужен точный тег postgres:17.X (18 — после Q-104), получено {image}")

        mounted = as_set(svc.get("secrets"))
        for sname in mounted - set(declared):
            errors.append(f"{name}: секрет {sname} не объявлен в secrets:")
        if mounted and gid is not None and str(gid) not in as_set(svc.get("group_add")):
            errors.append(f"{name}: монтирует секреты, но нет group_add [{gid}] (файлы 640, группа optomstroy-secrets)")
        env = env_map(svc.get("environment"))
        for key, value in env.items():
            m = re.fullmatch(r"/run/secrets/(.+)", value)
            if key.endswith("_FILE") and m and m.group(1) not in mounted:
                errors.append(f"{name}: {key} ссылается на несмонтированный секрет {m.group(1)}")
            if SECRETISH.search(key) and not key.endswith("_FILE") and value != "":
                errors.append(f"{name}: {key} — секрет передан значением (нужен {key}_FILE)")
            allowed = ctx["schema_keys"] | ctx["env_keys"] | IMAGE_LEVEL_ENV.get(name, set())
            if key.endswith("_FILE"):
                base = key[: -len("_FILE")]
                if base not in ctx["schema_secret_keys"] and key not in IMAGE_LEVEL_ENV.get(name, set()):
                    errors.append(f"{name}: {key} — нет секрета {base} в SECRET_ENV_KEYS env.schema.ts (16 §4.3)")
            elif key not in allowed:
                errors.append(f"{name}: переменная {key} не входит в env.schema.ts / prod.env.example (16 §4.3)")
        for dep in as_set(svc.get("depends_on") or {}):
            if dep not in services:
                errors.append(f"{name}: depends_on на несуществующий сервис {dep}")
        for vol in svc.get("volumes") or []:
            src = vol.get("source") if isinstance(vol, dict) else str(vol).split(":")[0]
            vtype = vol.get("type") if isinstance(vol, dict) else ("bind" if str(src).startswith((".", "/")) else "volume")
            if vtype == "volume" and src not in declared_volumes:
                errors.append(f"{name}: том {src} не объявлен в volumes:")
            if vtype == "bind" and ctx.get("base_dir") is not None and not (ctx["base_dir"] / src).exists():
                errors.append(f"{name}: bind-источник {src} не существует")
            if name == "postgres" and str(src).startswith(("./secrets", "/run")):
                errors.append("postgres: секреты монтируются только через secrets:")

    # Роли процессов и минимум прав (D-45; 16 §4.4 прим. 6; EQ-AUTH-08).
    for svc_name, workers in (("api", "false"), ("worker", "true"), ("migrate", "false")):
        env = env_map((services.get(svc_name) or {}).get("environment"))
        if env.get("APP_ENV") != prof["app_env"]:
            errors.append(f"{svc_name}: APP_ENV должен быть закреплён как {prof['app_env']} в environment (OPS-027)")
        if env.get("WORKERS_ENABLED") != workers:
            errors.append(f"{svc_name}: WORKERS_ENABLED={workers} (D-45)")
        if svc_name != "migrate" and env.get("OTP_HMAC_SECRET_FILE") != "/run/secrets/otp_pepper":
            errors.append(f"{svc_name}: нужен OTP_HMAC_SECRET_FILE=/run/secrets/otp_pepper (EQ-AUTH-08)")
        if svc_name != "migrate" and env.get("DATABASE_URL_FILE") != "/run/secrets/database_url":
            errors.append(f"{svc_name}: нужен DATABASE_URL_FILE=/run/secrets/database_url")
        if svc_name != "migrate" and profile == "test":
            for key in ("SMSPRO_LOGIN_FILE", "SMSPRO_PASSWORD_FILE"):
                if env.get(key, "") != "":
                    errors.append(f"{svc_name}: {key} в тестовой копии — пусто (SMS_PROVIDER=fake; SMSPro рабочего контура не копируется, 16 §11)")
    worker = services.get("worker") or {}
    if "JWT_PRIVATE_KEY_FILE" in env_map(worker.get("environment")):
        errors.append("worker: JWT_PRIVATE_KEY_FILE не передаётся (минимум прав, 16 §4.4 прим. 6)")
    # pepper PIN нужен и worker: CryptoModule глобальный (ADR-115), без PIN_PEPPER при APP_ENV=prod/staging worker
    # завершается (SecretConfigError; проверено 2026-11-24). Секрет и указатель — оба или ни одного.
    for svc_name in ("api", "worker"):
        svc = services.get(svc_name) or {}
        if env_map(svc.get("environment")).get("PIN_PEPPER_FILE") != "/run/secrets/pin_pepper" or "pin_pepper" not in as_set(svc.get("secrets")):
            errors.append(f"{svc_name}: нужен PIN_PEPPER_FILE=/run/secrets/pin_pepper и секрет pin_pepper (CryptoModule, ADR-115)")
    for sname in ("jwt_private.pem", "db_migrator_password", "pg_password", "db_backup_password"):
        if sname in as_set(worker.get("secrets")):
            errors.append(f"worker: секрет {sname} не монтируется (минимум прав)")
    for sname in ("db_migrator_password", "pg_password", "db_backup_password"):
        if sname in as_set((services.get("api") or {}).get("secrets")):
            errors.append(f"api: секрет {sname} не монтируется (R0 §17.7, минимум прав)")
    migrate_secrets = as_set((services.get("migrate") or {}).get("secrets"))
    if migrate_secrets != {"database_url", "db_migrator_password"}:
        errors.append(f"migrate: секреты {sorted(migrate_secrets)} ≠ database_url, db_migrator_password (минимум прав)")
    backup = services.get("backup") or {}
    benv = env_map(backup.get("environment"))
    if benv.get("PGUSER") != "pos_backup" or benv.get("PGPASSWORD_FILE") != "/run/secrets/db_backup_password":
        errors.append("backup: PGUSER=pos_backup и PGPASSWORD_FILE=/run/secrets/db_backup_password (не суперпользователь)")
    if as_set(backup.get("secrets")) - {"db_backup_password", "rclone.conf", "healthchecks_url"}:
        errors.append(f"backup: лишние секреты {sorted(as_set(backup.get('secrets')) - {'db_backup_password', 'rclone.conf', 'healthchecks_url'})} (пароль суперпользователя не нужен)")
    bhc = json.dumps((backup.get("healthcheck") or {}).get("test") or [])
    if "backup.sh" not in bhc or "health" not in bhc:
        errors.append("backup: healthcheck — backup.sh health (копия, выгрузка вне сервера, архивация WAL, базовая копия)")
    backup_targets = {mount_target(v) for v in backup.get("volumes") or []}
    if "/data/media" not in backup_targets:
        errors.append("backup: нужен том media:/data/media:ro (копия фото, 16 §8.2)")
    if WAL_SPOOL_TARGET not in backup_targets:
        errors.append(f"backup: нужен том walspool:{WAL_SPOOL_TARGET} (спул WAL: шифрование и удаление, RUNBOOK §4.8)")
    for sname, sdef in services.items():
        if sname in ("postgres", "backup"):
            continue
        for v in sdef.get("volumes") or []:
            src = v.get("source") if isinstance(v, dict) else str(v).split(":")[0]
            if src == "walspool" or mount_target(v) == WAL_SPOOL_TARGET:
                errors.append(f"{sname}: спул WAL (незашифрованные сегменты) монтируют только postgres и backup")
    pg_secrets = as_set((services.get("postgres") or {}).get("secrets"))
    if "db_backup_password" not in pg_secrets:
        errors.append("postgres: нужен секрет db_backup_password (пароль pos_backup в initdb 10-roles.sh)")
    images = {str((services.get(s) or {}).get("image")) for s in APP_SERVICES}
    if len(images) != 1 or not next(iter(images)).startswith("optomstroy/api:"):
        errors.append(f"api/worker/migrate: один образ optomstroy/api:<тег> (D-45), получено {sorted(images)}")
    if not str(backup.get("image")).startswith("optomstroy/backup:"):
        errors.append("backup: образ optomstroy/backup:<тег>")
    for dependent in ("api", "worker"):
        deps = (services.get(dependent) or {}).get("depends_on") or {}
        cond = (deps.get("migrate") or {}).get("condition") if isinstance(deps, dict) else None
        if cond != "service_completed_successfully":
            errors.append(f"{dependent}: depends_on migrate должен быть service_completed_successfully")
    for dependent in ("api", "worker", "migrate", "backup"):
        deps = (services.get(dependent) or {}).get("depends_on") or {}
        cond = (deps.get("postgres") or {}).get("condition") if isinstance(deps, dict) else None
        if cond != "service_healthy":
            errors.append(f"{dependent}: depends_on postgres должен быть service_healthy")

    postgres = services.get("postgres") or {}
    if postgres.get("expose"):
        errors.append("postgres: expose запрещён — порт БД не объявляется (только сеть backend)")
    initdb = env_map(postgres.get("environment")).get("POSTGRES_INITDB_ARGS", "")
    ctype = re.search(r"--lc-ctype[= ](\S+)", initdb) or re.search(r"--locale[= ](\S+)", initdb)
    if not ctype or not re.search(r"utf-?8", ctype.group(1), re.IGNORECASE):
        errors.append("postgres: POSTGRES_INITDB_ARGS должен задавать UTF-8 LC_CTYPE (16 §4.4, EQ-SRCH-01)")
    if "pg_isready" not in json.dumps(postgres.get("healthcheck") or {}):
        errors.append("postgres: healthcheck — pg_isready")
    pg_cmd = " ".join(postgres.get("command")) if isinstance(postgres.get("command"), list) else str(postgres.get("command") or "")
    if not re.search(r"shared_buffers=\d+[kMG]B\b", pg_cmd):
        errors.append(f"postgres: shared_buffers после подстановки — размер (…MB|GB), получено {pg_cmd!r}")
    # Непрерывная копия WAL (RUNBOOK §4.8; 15 ADR-035; 16 §8.1 «RPO при PITR ≤ 15 мин»).
    if "wal_level=replica" not in pg_cmd:
        errors.append("postgres: нужен -c wal_level=replica (базовая копия и архив WAL)")
    if not re.search(r"archive_mode=(on|off)(\s|$)", pg_cmd):
        errors.append(f"postgres: archive_mode после подстановки — on или off (BACKUP_PITR), получено {pg_cmd!r}")
    if not re.search(r"archive_timeout=60(\s|$)", pg_cmd):
        errors.append("postgres: нужен -c archive_timeout=60 (сегмент закрывается не реже раза в минуту)")
    if ARCHIVE_COMMAND not in pg_cmd:
        errors.append(f"postgres: archive_command — -c {ARCHIVE_COMMAND}")
    pg_targets = {mount_target(v) for v in postgres.get("volumes") or []}
    if "/var/lib/postgresql/data" not in pg_targets and "/var/lib/postgresql" not in pg_targets:
        errors.append("postgres: том данных не смонтирован в /var/lib/postgresql/data (17) или /var/lib/postgresql (18+)")
    if WAL_SPOOL_TARGET not in pg_targets:
        errors.append(f"postgres: нужен том walspool:{WAL_SPOOL_TARGET} (archive_command пишет в спул)")
    if PG_SCRIPTS_TARGET not in pg_targets:
        errors.append(f"postgres: нужен ./docker/postgres/scripts:{PG_SCRIPTS_TARGET}:ro (archive_command)")

    data_dir = (ctx.get("lib") or {}).get(prof["data_key"])
    for vname in DATA_VOLUMES:
        vdef = declared_volumes.get(vname) or {}
        device = ((vdef.get("driver_opts") or {}).get("device")) or ""
        if not data_dir or device != f"{data_dir}/{vname}":
            errors.append(f"том {vname}: ожидается bind в {data_dir}/{vname} (16 §4.2), получено {device or 'нет'}")
    return errors


# ----------------------------------------------------------------------------------------------- общий caddy
def check_edge(cfg: dict, ctx: dict, with_test: bool) -> list[str]:
    errors: list[str] = []
    if cfg.get("name") != EDGE_PROJECT:
        errors.append(f"name: ожидается {EDGE_PROJECT}")
    services = cfg.get("services") or {}
    if set(services) != {"caddy"}:
        errors.append(f"состав сервисов {sorted(services)} ≠ ['caddy']")
    caddy = services.get("caddy") or {}
    if sorted(port_target(p) for p in caddy.get("ports") or []) != [80, 443]:
        errors.append("caddy: ожидаются порты ровно 80 и 443 (единственные публичные порты сервера, 16 §4.2)")
    common_service_checks("caddy", caddy, errors)
    if str(caddy.get("restart") or "") not in ("unless-stopped", "always"):
        errors.append("caddy: restart unless-stopped|always")
    image = str(caddy.get("image") or "")
    if not re.fullmatch(r"caddy:\d+\.\d+\.\d+(-alpine)?", image):
        errors.append(f"caddy: нужен точный тег caddy:X.Y.Z, получено {image}")
    if ctx.get("ci_caddy_image") and image != ctx["ci_caddy_image"]:
        errors.append(f"caddy: тег {image} ≠ {ctx['ci_caddy_image']} CI-контура (compose.test.yml) — проверенный CI")
    if "ALL" not in [str(c).upper() for c in caddy.get("cap_drop") or []]:
        errors.append("caddy: нужен cap_drop: [ALL]")
    extra = {str(c).upper().removeprefix("CAP_") for c in caddy.get("cap_add") or []} - {"NET_BIND_SERVICE"}
    if extra:
        errors.append(f"caddy: cap_add сверх NET_BIND_SERVICE: {sorted(extra)}")
    if "/health" in json.dumps(caddy.get("healthcheck") or {}):
        errors.append("caddy: healthcheck через /health запрещён — proxy не зависит от api (16 §4.1, §4.4 прим. 7)")
    if caddy.get("depends_on"):
        errors.append("caddy: depends_on запрещён (16 §4.4 прим. 7)")
    want_nets = {"prod_edge"} | ({"test_edge"} if with_test else set())
    if as_set(caddy.get("networks")) != want_nets:
        errors.append(f"caddy: сети {sorted(as_set(caddy.get('networks')))} ≠ {sorted(want_nets)}")
    nets = cfg.get("networks") or {}
    for key, name in (("prod_edge", "optomstroy_prod_edge"), ("test_edge", "optomstroy_test_edge")):
        if key not in want_nets:
            continue
        if (nets.get(key) or {}).get("name") != name or (nets.get(key) or {}).get("external") is not True:
            errors.append(f"сеть {key}: name: {name}, external: true")
    vols = cfg.get("volumes") or {}
    for vname in ("caddy_data", "caddy_config"):
        if vname not in vols:
            errors.append(f"том {vname} не объявлен (сертификаты ACME — persistent, 16 §4.2)")
    mounts = {mount_target(v): v for v in caddy.get("volumes") or []}
    want_mounts = {"/etc/caddy/Caddyfile", "/etc/caddy/sites/prod.caddy", "/data", "/config", "/srv/media/prod"}
    if with_test:
        want_mounts |= {"/etc/caddy/sites/test.caddy", "/srv/media/test"}
    for t in sorted(want_mounts - set(mounts)):
        errors.append(f"caddy: нет монтирования {t}")
    for t in ("/etc/caddy/Caddyfile", "/etc/caddy/sites/prod.caddy", "/etc/caddy/sites/test.caddy",
              "/srv/media/prod", "/srv/media/test"):
        v = mounts.get(t)
        if v is not None and not (v.get("read_only") if isinstance(v, dict) else str(v).endswith(":ro")):
            errors.append(f"caddy: {t} — только для чтения (:ro)")
    lib = ctx.get("lib") or {}
    for vname, key, contour in (("prod_media", "DATA_DIR", True), ("test_media", "TEST_DATA_DIR", with_test)):
        if not contour:
            continue
        device = (((vols.get(vname) or {}).get("driver_opts") or {}).get("device")) or ""
        if device != f"{lib.get(key)}/media":
            errors.append(f"том {vname}: ожидается bind в {lib.get(key)}/media, получено {device or 'нет'}")
    for vol in caddy.get("volumes") or []:
        src = vol.get("source") if isinstance(vol, dict) else str(vol).split(":")[0]
        if str(src).startswith(".") and ctx.get("base_dir") is not None and not (ctx["base_dir"] / src).exists():
            errors.append(f"caddy: bind-источник {src} не существует")
    env = env_map(caddy.get("environment"))
    for key in ["CADDY_SITE_ADDRESS", "CADDY_TLS"] + (["CADDY_TEST_SITE_ADDRESS"] if with_test else []):
        if key not in env:
            errors.append(f"caddy: нет переменной {key}")
    for key in env:
        if key not in IMAGE_LEVEL_ENV["caddy"]:
            errors.append(f"caddy: лишняя переменная {key}")
    return errors


# ----------------------------------------------------------------------------------------------- Caddyfile
def strip_caddy(lines: list[str]) -> list[str]:
    return [ln.strip() for ln in lines if ln.strip() and not ln.strip().startswith("#")]


def caddy_ci_site_body(text: str) -> list[str]:
    lines = text.splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.startswith("{$CADDY_SITE_ADDRESS"))
    end = max(i for i, ln in enumerate(lines) if ln.strip() == "}")
    body = [ln for ln in lines[start + 1:end] if not ln.strip().startswith("tls ")]
    out = []
    for ln in strip_caddy(body):
        ln = ln.replace("{$API_UPSTREAM:api:3000}", "{args[0]}")
        if ln == "root * /srv/media":
            ln = "root * {args[1]}"
        out.append(ln)
    return out


def caddy_snippet_body(text: str, name: str) -> list[str]:
    lines = text.splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.strip() == f"({name}) {{")
    depth, end = 0, start
    for i in range(start, len(lines)):
        code = lines[i].split("#", 1)[0] if lines[i].strip().startswith("#") else lines[i]
        depth += code.count("{") - code.count("}")
        if depth == 0:
            end = i
            break
    return strip_caddy(lines[start + 1:end])


def check_caddy(infra: Path) -> list[str]:
    errors: list[str] = []
    ci = (infra / "caddy/Caddyfile").read_text(encoding="utf-8")
    edge = (infra / "caddy/Caddyfile.edge").read_text(encoding="utf-8")
    try:
        ci_body = caddy_ci_site_body(ci)
        snippet = caddy_snippet_body(edge, "api_site")
    except (StopIteration, ValueError):
        return ["Caddyfile.edge / Caddyfile: не найден сниппет (api_site) или сайт {$CADDY_SITE_ADDRESS…}"]
    if ci_body != snippet:
        diff = [f"CI: {a!r} ≠ edge: {b!r}" for a, b in zip(ci_body, snippet) if a != b][:3]
        if len(ci_body) != len(snippet):
            diff.append(f"строк правил: CI {len(ci_body)}, edge {len(snippet)}")
        errors.append("Caddyfile.edge: сниппет api_site расходится с сайтом infra/caddy/Caddyfile (правка — в обоих): "
                      + "; ".join(diff))
    if not re.search(r"^import /etc/caddy/sites/\*\.caddy$", edge, re.M):
        errors.append("Caddyfile.edge: нет import /etc/caddy/sites/*.caddy")
    for fname, var, upstream, media in (("prod.caddy", "CADDY_SITE_ADDRESS", "optomstroy-prod-api-1:3000", "/srv/media/prod"),
                                        ("test.caddy", "CADDY_TEST_SITE_ADDRESS", "optomstroy-test-api-1:3000", "/srv/media/test")):
        site = (infra / "caddy/sites" / fname).read_text(encoding="utf-8")
        code = strip_caddy(site.splitlines())
        want = ["{$" + var + "} {", "tls {$CADDY_TLS}", f"import api_site {upstream} {media}", "}"]
        if code != want:
            errors.append(f"caddy/sites/{fname}: ожидается {want}, получено {code}")
    for name, text in (("Caddyfile", ci), ("Caddyfile.edge", edge)):
        code = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
        for directive in ("basic_auth", "basicauth", "forward_auth"):
            if re.search(rf"\b{directive}\b", code):
                errors.append(f"{name}: {directive} — proxy не авторизует (DEPLOY-049)")
    return errors


# ----------------------------------------------------------------------------------------------- проверка комплекта
def check_kit(infra: Path, repo: Path, env_values: dict[str, str], env_dups: list[str], test_over: dict[str, str],
              used_vars: set[str], shape: dict[str, str], schema_text: str, lib: dict[str, str],
              configs: dict[str, dict]) -> list[str]:
    errors: list[str] = []
    env_keys = set(env_values)
    for k in env_dups:
        errors.append(f"prod.env.example: {k} задана несколько раз")

    # Формат шаблонов: у пустой переменной нет встроенного комментария (Compose прочитал бы его как значение).
    for rel in ("infra/env/prod.env.example", "infra/env/test.env.example", ".env.example"):
        for k in inline_comment_keys((repo / rel).read_text(encoding="utf-8")):
            errors.append(f"{rel}: «{k}=   # …» — Compose прочитает комментарий как значение; комментарий — строкой выше")

    # Имена: канонический перечень 16 §4.3 (как scripts/check_env_example.py) + имена уровня compose.
    cee = load_module(repo / "scripts/check_env_example.py", "check_env_example")
    sec = cee.section_43((repo / cee.SPEC).read_text(encoding="utf-8"))
    table = cee.parse_table(sec)
    expected = {n for n, w in table.items() if "`.env`" in w} - cee.parse_r2_conditional(sec)
    for n in sorted(expected - env_keys):
        errors.append(f"prod.env.example: нет {n} (16 §4.3, место `.env`)")
    for n in sorted(env_keys - expected - COMPOSE_LEVEL_KEYS):
        errors.append(f"prod.env.example: лишняя {n} (нет в 16 §4.3 с местом `.env` или в перечне «R2 и условные»)")
    root_keys, _ = parse_dotenv((repo / ".env.example").read_text(encoding="utf-8"))
    if set(root_keys) != env_keys - COMPOSE_LEVEL_KEYS:
        diff = sorted(set(root_keys) ^ (env_keys - COMPOSE_LEVEL_KEYS))
        errors.append(f"prod.env.example и /.env.example расходятся по именам: {diff}")

    # Типы и значения — по env.schema.ts; рабочий контур и тестовая копия.
    test_values = {**env_values, **test_over}
    for label, values in (("prod.env.example", env_values), ("prod.env.example + test.env.example", test_values)):
        for key, value in values.items():
            if key in shape:
                problem = check_value_type(key, value, shape[key], schema_text)
                if problem:
                    errors.append(f"{label}: {key}={value!r} — {problem} (env.schema.ts)")
    for key, value in SAFE_VALUES.items():
        if env_values.get(key) != value:
            errors.append(f"prod.env.example: {key} должна быть {value!r} для первого запуска (получено {env_values.get(key)!r})")
    for key, allowed in ALLOWED_VALUES.items():
        if env_values.get(key) not in allowed:
            errors.append(f"prod.env.example: {key} ∈ {sorted(allowed)} (16 §4.3, OPS-027)")
    if env_values.get("QR_PROVIDER") == "onec" and env_values.get("ONEC_MODE") != "extension":
        errors.append("prod.env.example: QR_PROVIDER=onec требует ONEC_MODE=extension (env.schema.ts)")
    for name in sorted(used_vars - env_keys):
        errors.append(f"compose: переменная ${{{name}}} не задана в prod.env.example")
    # Замены тестовой копии (16 §11).
    for k in sorted(set(test_over) - env_keys):
        errors.append(f"test.env.example: {k} нет в prod.env.example (только замены существующих строк)")
    for k, v in TEST_REQUIRED.items():
        if test_over.get(k) != v:
            errors.append(f"test.env.example: {k} должна быть {v!r} (16 §11), получено {test_over.get(k)!r}")
    if test_over.get("POSTGRES_DB") in (None, env_values.get("POSTGRES_DB")):
        errors.append("test.env.example: POSTGRES_DB тестовой копии должна отличаться от рабочей")
    # Ежедневная копия — вне ночных заданий синхронизации 02:00–05:00 (16 §4.3, §8.2).
    for label, values in (("prod.env.example", env_values), ("test.env.example", test_values)):
        fields = values.get("BACKUP_SCHEDULE", "").split()
        if len(fields) != 5 or not fields[1].isdigit() or not fields[0].isdigit():
            errors.append(f"{label}: BACKUP_SCHEDULE — одно время в сутки «М Ч * * *», получено {values.get('BACKUP_SCHEDULE')!r}")
        elif int(fields[1]) in NIGHT_SYNC_HOURS:
            errors.append(f"{label}: BACKUP_SCHEDULE {values.get('BACKUP_SCHEDULE')!r} внутри ночных заданий синхронизации 02:00–05:00")

    # Константы lib.sh ↔ compose.
    base = configs["base"]

    def words(name: str) -> set[str]:
        return set(lib.get(name, "").split())

    if words("BASE_SECRETS") != set(base.get("secrets") or {}):
        errors.append(f"lib.sh BASE_SECRETS ≠ secrets: compose.prod.yml ({sorted(set(base.get('secrets') or {}) ^ words('BASE_SECRETS'))})")
    if not words("GENERATED_SECRETS") | words("OPERATOR_SECRETS") | {"rclone.conf"} >= set(base.get("secrets") or {}):
        errors.append("lib.sh: не все секреты compose.prod.yml создаются install.sh (GENERATED/OPERATOR)")
    if words("ONEC_HS_SECRETS") & words("ONEC_ODATA_SECRETS"):
        errors.append("lib.sh: наборы ONEC_HS_SECRETS и ONEC_ODATA_SECRETS пересекаются")
    overlay_map = {"compose.prod.onec.yml": words("ONEC_HS_SECRETS"),
                   "compose.prod.onec-odata.yml": words("ONEC_ODATA_SECRETS"),
                   "compose.prod.onec-ca.yml": words("ONEC_CA_SECRET"),
                   "compose.prod.healthchecks.yml": words("HEALTHCHECKS_SECRET")}
    overlays = {k: v for k, v in configs.items() if k.startswith("compose.prod.")}
    for fname, names in overlay_map.items():
        ov = overlays.get(fname)
        if ov is None:
            errors.append(f"нет дополнения {fname}")
        elif set(ov.get("secrets") or {}) != names:
            errors.append(f"lib.sh: секреты {fname} {sorted(set(ov.get('secrets') or {}))} ≠ {sorted(names)}")
        elif ov.get("name"):
            errors.append(f"{fname}: без name: — имя проекта задают compose.prod.yml / compose.staging.yml")
    for fname in sorted(set(overlays) - set(overlay_map)):
        errors.append(f"дополнение {fname} не известно lib.sh (compose_init его не подключит)")
    if "ONEC_USER_FILE" in json.dumps(overlays.get("compose.prod.onec.yml") or {}):
        errors.append("compose.prod.onec.yml: OData (ONEC_USER_FILE) — только в compose.prod.onec-odata.yml (разведённые пользователи: 05 ONEC-052, 16 §12.5 P-4)")
    services = base.get("services") or {}
    gid = lib.get("SECRETS_GID")
    for svc_name in ("api", "worker", "migrate", "backup", "postgres"):
        if as_set((services.get(svc_name) or {}).get("group_add")) != {gid}:
            errors.append(f"{svc_name}: group_add ≠ [{gid}] (lib.sh SECRETS_GID)")
    uid_expect = {"api": lib.get("APP_UID"), "worker": lib.get("APP_UID"), "migrate": lib.get("APP_UID"),
                  "backup": lib.get("BACKUP_UID"), "postgres": lib.get("PG_UID")}
    for svc_name, uid in uid_expect.items():
        if str((services.get(svc_name) or {}).get("user") or "").split(":")[0] != uid:
            errors.append(f"{svc_name}: user ≠ {uid} (lib.sh — владельцы каталогов данных)")
    if lib.get("EDGE_PROJECT") != EDGE_PROJECT:
        errors.append(f"lib.sh EDGE_PROJECT ≠ {EDGE_PROJECT}")
    for f in words("KIT_FILES") | words("EDGE_KIT_FILES"):
        if not (infra / f).is_file():
            errors.append(f"lib.sh KIT_FILES/EDGE_KIT_FILES: нет infra/{f}")
    for f in sorted(p.name for p in infra.glob("compose.prod*.yml")) + ["compose.staging.yml"]:
        if f not in words("KIT_FILES"):
            errors.append(f"lib.sh KIT_FILES: нет {f} (install.sh его не скопирует)")
    # Каталоги комплекта, смонтированные bind (initdb, archive_command): каждый их файл копирует install.sh/update.sh.
    for svc_name, sdef in services.items():
        for v in sdef.get("volumes") or []:
            src = v.get("source") if isinstance(v, dict) else str(v).split(":")[0]
            if not str(src).startswith("./"):
                continue
            src_path = infra / str(src)[2:]
            files = [src_path] if src_path.is_file() else sorted(q for q in src_path.rglob("*") if q.is_file())
            for q in files:
                rel = q.relative_to(infra).as_posix()
                if rel not in words("KIT_FILES"):
                    errors.append(f"lib.sh KIT_FILES: нет {rel} — {svc_name} монтирует {src}, install.sh файл не скопирует")
    edge_needed = {p.name for p in infra.glob("compose.edge*.yml")} | {"caddy/Caddyfile.edge"} | \
                  {f"caddy/sites/{p.name}" for p in (infra / "caddy/sites").glob("*.caddy")}
    for f in sorted(edge_needed - words("EDGE_KIT_FILES")):
        errors.append(f"lib.sh EDGE_KIT_FILES: нет {f}")
    for f in words("KIT_SCRIPTS"):
        if not (infra / "scripts" / f).is_file():
            errors.append(f"lib.sh KIT_SCRIPTS: нет infra/scripts/{f}")
    for script in sorted(p for p in (infra / "scripts").iterdir() if p.is_file()):
        if script.name not in words("KIT_SCRIPTS"):
            errors.append(f"lib.sh KIT_SCRIPTS: нет {script.name} (install.sh его не скопирует)")
    shell_files = [p for p in (infra / "scripts").iterdir() if p.is_file()] + [
        infra / "docker/backup/backup.sh", infra / "docker/scripts/test_lib.sh",
        infra / "docker/postgres/scripts/wal-archive.sh", infra / "docker/postgres/initdb/10-roles.sh"]
    # Непрерывная копия WAL (RUNBOOK §4.8): healthcheck, archive_command, роль репликации.
    backup_sh = (infra / "docker/backup/backup.sh").read_text(encoding="utf-8")
    for marker in BACKUP_HEALTH_MARKERS:
        if marker not in backup_sh:
            errors.append(f"backup.sh health: нет проверки «{marker}» (RUNBOOK §4.1, §4.8)")
    archive_sh = (infra / "docker/postgres/scripts/wal-archive.sh").read_text(encoding="utf-8")
    for marker in ('cmp -s', 'sync "$tmp"', 'ln "$tmp" "$dst"', 'sync "$dir"', 'exit 1'):
        if marker not in archive_sh:
            errors.append(f"wal-archive.sh: нет «{marker}» (без перезаписи, fsync, ненулевой код при сбое)")
    roles_sh = (infra / "docker/postgres/initdb/10-roles.sh").read_text(encoding="utf-8")
    if "LOGIN REPLICATION" not in roles_sh or REPLICATION_HBA not in roles_sh:
        errors.append("10-roles.sh: pos_backup — REPLICATION и строка pg_hba для pg_basebackup (RUNBOOK §4.8)")
    lib_sh = (infra / "scripts/lib.sh").read_text(encoding="utf-8")
    if REPLICATION_HBA not in lib_sh or "LOGIN REPLICATION" not in lib_sh:
        errors.append("lib.sh pg_sync_backup_role: REPLICATION и строка pg_hba — как в 10-roles.sh")
    for script in sorted(shell_files):
        if not script.is_file():
            errors.append(f"нет {script.relative_to(infra)}")
            continue
        text = script.read_text(encoding="utf-8")
        if re.search(r"^\s*set\s+-[a-wyz]*x", text, re.M) or "set -o xtrace" in text:
            errors.append(f"{script.name}: трассировка set -x запрещена (показала бы значения секретов)")
        if "\r" in text:
            errors.append(f"{script.name}: окончания строк CRLF (нужен LF)")
        for no, line in enumerate(text.splitlines(), 1):
            if re.search(r"\\[ \t]+(#|$)", line):
                errors.append(f"{script.name}:{no}: пробел или комментарий после «\\» — продолжение строки разорвано")
    errors.extend(check_caddy(infra))
    return errors


def ci_caddy_image(infra: Path) -> str | None:
    m = re.search(r"^\s*image:\s*(caddy:\S+)", (infra / "compose.test.yml").read_text(encoding="utf-8"), re.M)
    return m.group(1) if m else None


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("использование: check_compose_prod.py <infra/compose.prod.yml | cfg.json>", file=sys.stderr)
        return 2
    path = Path(argv[1])
    repo = Path(__file__).resolve().parents[3]
    try:
        schema_text = (repo / "pos-api/src/common/config/env.schema.ts").read_text(encoding="utf-8")
        shape, schema_secret_keys = schema_info(schema_text)
        lib = lib_constants((repo / "infra/scripts/lib.sh").read_text(encoding="utf-8"))
        env_values, env_dups = parse_dotenv((repo / "infra/env/prod.env.example").read_text(encoding="utf-8"))
        test_over, _ = parse_dotenv((repo / "infra/env/test.env.example").read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 — понятное сообщение вместо трассировки
        print(f"не удалось прочитать файлы комплекта: {exc}", file=sys.stderr)
        return 2
    ctx = {
        "secrets_gid": lib.get("SECRETS_GID"),
        "schema_keys": set(shape),
        "schema_secret_keys": schema_secret_keys,
        "env_keys": set(env_values),
        "lib": lib,
        "base_dir": None,
        "ci_caddy_image": None,
    }
    errors: list[str] = [f"[самопроверка] {e}" for e in self_test()]
    summaries: list[str] = []
    try:
        if path.suffix in (".yml", ".yaml"):
            import yaml  # PyYAML: поддерживает слияние якорей `<<:` (как Compose)

            infra = path.resolve().parent
            ctx["base_dir"] = infra
            ctx["ci_caddy_image"] = ci_caddy_image(infra)
            test_env = {**env_values, **test_over}
            used: set[str] = set()

            def load(name: str, env: dict[str, str]) -> dict:
                return interpolate(yaml.safe_load((infra / name).read_text(encoding="utf-8")), env, used)

            configs = {"base": load(path.name, env_values)}
            for ov in sorted(infra.glob("compose.prod.*.yml")):
                configs[ov.name] = load(ov.name, env_values)
            overlay_names = [k for k in configs if k != "base"]
            combos = [()] + [(n,) for n in overlay_names] + [
                ("compose.prod.onec.yml", "compose.prod.onec-odata.yml"),
                ("compose.prod.onec.yml", "compose.prod.onec-ca.yml"),
                tuple(overlay_names)]
            combos = [c for c in combos if all(n in configs for n in c)]
            test_configs = {"base": load(path.name, test_env), "staging": load("compose.staging.yml", test_env)}
            for n in overlay_names:
                test_configs[n] = load(n, test_env)
            for profile, cfgs, tail in (("prod", configs, ()), ("test", test_configs, ("staging",))):
                for combo in ([(), ("compose.prod.onec.yml",), tuple(overlay_names)] if profile == "test" else combos):
                    merged = cfgs["base"]
                    for n in combo + tail:
                        merged = merge_compose(merged, cfgs[n])
                    label = ("тест: " if profile == "test" else "") + "compose.prod.yml" + \
                        "".join(f" + {n}" for n in combo) + (" + compose.staging.yml" if tail else "")
                    errs = check_config(merged, ctx, profile)
                    errors.extend(f"[{label}] {e}" for e in errs)
                    summaries.append(f"{label}: {'OK' if not errs else f'нарушений {len(errs)}'}")
            # Профиль памяти 4 GB (install.sh/update.sh, 16 §4.4 прим. 2) — значения .env, а не правка compose-файла.
            mem4 = {**env_values, "PG_SHARED_BUFFERS": "512MB", "PG_MEM_LIMIT": "1536M", "API_MEM_LIMIT": "768M",
                    "WORKER_MEM_LIMIT": "768M"}
            cfg4 = load(path.name, mem4)
            errs = check_config(cfg4, ctx, "prod")
            svc4 = cfg4.get("services") or {}
            limits4 = {n: (((svc4.get(n) or {}).get("deploy") or {}).get("resources") or {}).get("limits", {}).get("memory")
                       for n in ("postgres", "api", "worker")}
            if limits4 != {"postgres": "1536M", "api": "768M", "worker": "768M"} or \
                    "shared_buffers=512MB" not in str((svc4.get("postgres") or {}).get("command")):
                errs.append(f"профиль 4 GB не доходит до compose: лимиты {limits4}")
            errors.extend(f"[compose.prod.yml, профиль памяти 4 GB] {e}" for e in errs)
            summaries.append(f"compose.prod.yml, профиль памяти 4 GB: {'OK' if not errs else f'нарушений {len(errs)}'}")
            edge = load("compose.edge.yml", env_values)
            edge_test = merge_compose(edge, load("compose.edge.test.yml", {**env_values, "CADDY_TEST_SITE_ADDRESS": "api-test.example"}))
            published = {}
            for label, cfg, with_test in (("compose.edge.yml", edge, False),
                                          ("compose.edge.yml + compose.edge.test.yml", edge_test, True)):
                errs = check_edge(cfg, ctx, with_test)
                errors.extend(f"[{label}] {e}" for e in errs)
                summaries.append(f"{label}: {'OK' if not errs else f'нарушений {len(errs)}'}")
                published[label] = sorted(port_target(p) for p in ((cfg.get("services") or {}).get("caddy") or {}).get("ports") or [])
            errors.extend(f"[комплект] {e}" for e in check_kit(infra, repo, env_values, env_dups, test_over, used, shape,
                                                               schema_text, lib, configs))
            for label, cfg in (("рабочий контур", configs["base"]),):
                for n, s in (cfg.get("services") or {}).items():
                    if s.get("ports"):
                        published[f"{label}/{n}"] = sorted(port_target(p) for p in s["ports"])
        else:
            cfg = json.loads(path.read_text(encoding="utf-8"))
            name = cfg.get("name")
            if name == EDGE_PROJECT:
                errs = check_edge(cfg, ctx, "test_edge" in (cfg.get("networks") or {}))
            else:
                profile = "test" if name == PROFILES["test"]["project"] else "prod"
                errs = check_config(cfg, ctx, profile)
            errors.extend(errs)
            summaries.append(f"{path.name} ({name}): {'OK' if not errs else f'нарушений {len(errs)}'}")
            published = {n: sorted(port_target(p) for p in (s.get("ports") or []))
                         for n, s in (cfg.get("services") or {}).items() if s.get("ports")}
    except Exception as exc:  # noqa: BLE001
        print(f"не удалось проверить {path}: {exc}", file=sys.stderr)
        return 2
    for e in errors:
        print(f"FAIL {e}")
    for s in summaries:
        print(f"  {s}")
    print(f"опубликованные порты: {published}")
    print("ИТОГ: " + ("OK — нарушений нет" if not errors else f"нарушений {len(errors)}"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

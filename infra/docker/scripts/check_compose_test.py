#!/usr/bin/env python3
"""Проверка структуры тестового контура infra/compose.test.yml (RM-C-012 п. 3; 16 §4.1–§4.4).

Вход — один из двух вариантов:
  * нормализованная конфигурация `docker compose -f infra/compose.test.yml config --format json > cfg.json`
    (CI, Makefile `test-check`) — проверяется то, что реально запустит Docker;
  * сам YAML-файл (`*.yml`) — без Docker: подстановка `${VAR:-default}` выполняется скриптом (значения по
    умолчанию), дополнительно проверяется наличие файлов, на которые ссылается compose.

Проверки: ровно сервисы caddy, api, worker, migrate, postgres, backup; `ports:` только у caddy и только 80/443;
сети optomstroy_test_edge и optomstroy_test_backend (internal: true); postgres и migrate — только backend;
caddy — только edge; api/worker/backup — обе сети; api/worker/migrate/backup — non-root (`user`), read_only,
cap_drop ALL; каждая ссылка `*_FILE=/run/secrets/<x>` смонтирована сервису; секреты объявлены и только файлами;
в environment нет значений, похожих на секреты; depends_on ссылается на существующие сервисы; postgres — UTF-8
LC_CTYPE (16 §4.4); OTP_HMAC_SECRET_FILE у api и worker, JWT_PRIVATE_KEY_FILE/PIN_PEPPER_FILE — не у worker (EQ-AUTH-08);
сервисы с ONEC_MODE=fixtures собираются стадией `test-fixtures` (FQ-INT-08). В YAML-режиме дополнительно — образ api
(infra/docker/api/Dockerfile + .dockerignore; 16 §4.4 прим. (1)–(2), FQ-INT-09): runtime копирует `pos-api/assets`,
стадия `test-fixtures` — `contracts/onec/fixtures`, последняя стадия (по умолчанию, прод) фикстур не копирует, белый
список контекста пропускает assets и фикстуры.

Использование: python -I -X utf8 infra/docker/scripts/check_compose_test.py <cfg.json | compose.test.yml>
Код выхода: 0 — OK; 1 — нарушения; 2 — ошибка ввода. Сторонний модуль только для YAML-режима — PyYAML.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

EXPECTED_SERVICES = {"caddy", "api", "worker", "migrate", "postgres", "backup"}
NETWORK_NAMES = {"edge": "optomstroy_test_edge", "backend": "optomstroy_test_backend"}
SERVICE_NETWORKS = {
    "caddy": {"edge"},
    "api": {"edge", "backend"},
    "worker": {"edge", "backend"},
    "backup": {"edge", "backend"},
    "migrate": {"backend"},
    "postgres": {"backend"},
}
HARDENED = ("api", "worker", "migrate", "backup")
FIXTURES_TARGET = "test-fixtures"
SECRETISH = re.compile(r"(PASSWORD|SECRET|TOKEN|PEPPER|PRIVATE_KEY|API_KEY)$")
INTERP = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^}]*))?\}")


def interpolate(value):
    if isinstance(value, str):
        return INTERP.sub(lambda m: os.environ.get(m.group(1)) or (m.group(2) or ""), value).replace("$$", "$")
    if isinstance(value, list):
        return [interpolate(v) for v in value]
    if isinstance(value, dict):
        return {k: interpolate(v) for k, v in value.items()}
    return value


def as_set(value) -> set[str]:
    if value is None:
        return set()
    if isinstance(value, dict):
        return set(value)
    return {v["source"] if isinstance(v, dict) else str(v) for v in value}


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


def check(cfg: dict, base_dir: Path | None) -> list[str]:
    errors: list[str] = []
    services = cfg.get("services") or {}
    if set(services) != EXPECTED_SERVICES:
        errors.append(f"состав сервисов {sorted(services)} ≠ {sorted(EXPECTED_SERVICES)}")
    if cfg.get("name") not in (None, "optomstroy-test"):
        errors.append(f"name: ожидается optomstroy-test, получено {cfg.get('name')}")

    nets = cfg.get("networks") or {}
    for key, name in NETWORK_NAMES.items():
        if (nets.get(key) or {}).get("name") != name:
            errors.append(f"сеть {key}: ожидается name: {name}")
    if (nets.get("backend") or {}).get("internal") is not True:
        errors.append("сеть backend: требуется internal: true")
    if (nets.get("edge") or {}).get("internal"):
        errors.append("сеть edge не должна быть internal (api/worker/backup ходят наружу: 1С, SMSPro, хранилище)")

    declared_secrets = cfg.get("secrets") or {}
    for sname, sdef in declared_secrets.items():
        if not isinstance(sdef, dict) or "file" not in sdef:
            errors.append(f"секрет {sname}: допускается только file: (16 §4.3)")
        elif base_dir is not None and not (base_dir / sdef["file"]).resolve().is_relative_to((base_dir / "secrets").resolve()):
            errors.append(f"секрет {sname}: файл должен лежать в infra/secrets/ (вне git)")
    declared_volumes = set(cfg.get("volumes") or {})

    for name, svc in services.items():
        ports = svc.get("ports") or []
        if name == "caddy":
            targets = sorted(port_target(p) for p in ports)
            if targets != [80, 443]:
                errors.append(f"caddy: ожидаются порты 80 и 443, получено {targets}")
        elif ports:
            errors.append(f"{name}: ports: запрещены — публикуется только caddy (RM-C-012 п. 3)")
        if name in SERVICE_NETWORKS and as_set(svc.get("networks")) != SERVICE_NETWORKS[name]:
            errors.append(f"{name}: сети {sorted(as_set(svc.get('networks')))} ≠ {sorted(SERVICE_NETWORKS[name])}")
        if name in HARDENED:
            user = str(svc.get("user") or "")
            if user == "" or user.split(":")[0] in ("0", "root"):
                errors.append(f"{name}: нужен непривилегированный user")
            if svc.get("read_only") is not True:
                errors.append(f"{name}: нужен read_only: true")
            if "ALL" not in [str(c).upper() for c in svc.get("cap_drop") or []]:
                errors.append(f"{name}: нужен cap_drop: [ALL]")
        if "no-new-privileges:true" not in [str(s).replace(" ", "") for s in svc.get("security_opt") or []]:
            errors.append(f"{name}: нужен security_opt no-new-privileges:true")

        mounted = as_set(svc.get("secrets"))
        for sname in mounted - set(declared_secrets):
            errors.append(f"{name}: секрет {sname} не объявлен в secrets:")
        env = env_map(svc.get("environment"))
        for key, value in env.items():
            m = re.fullmatch(r"/run/secrets/(.+)", value)
            if key.endswith("_FILE") and m and m.group(1) not in mounted:
                errors.append(f"{name}: {key} ссылается на несмонтированный секрет {m.group(1)}")
            if SECRETISH.search(key) and not key.endswith("_FILE") and value != "":
                errors.append(f"{name}: {key} — секрет передан значением (нужен {key}_FILE)")
        for dep in as_set(svc.get("depends_on")):
            if dep not in services:
                errors.append(f"{name}: depends_on на несуществующий сервис {dep}")
        for vol in svc.get("volumes") or []:
            src = vol.get("source") if isinstance(vol, dict) else str(vol).split(":")[0]
            vtype = vol.get("type") if isinstance(vol, dict) else ("bind" if src.startswith((".", "/")) else "volume")
            if vtype == "volume" and src not in declared_volumes:
                errors.append(f"{name}: том {src} не объявлен в volumes:")
            if vtype == "bind" and base_dir is not None and not (base_dir / src).exists():
                errors.append(f"{name}: bind-источник {src} не существует")
        build = svc.get("build")
        if isinstance(build, dict) and base_dir is not None:
            ctx = base_dir / build.get("context", ".")
            dockerfile = ctx / build.get("dockerfile", "Dockerfile")
            if not dockerfile.is_file():
                errors.append(f"{name}: Dockerfile {dockerfile} не найден")

        # FQ-INT-08 (16 §4.4 прим. (2)): FakeOnecGateway читает /contracts/onec/fixtures — фикстуры в образе
        # тестового контура (стадия test-fixtures), а не в прод-образе.
        if env_map(svc.get("environment")).get("ONEC_MODE") == "fixtures" and isinstance(build, dict):
            if build.get("target") != FIXTURES_TARGET:
                errors.append(f"{name}: ONEC_MODE=fixtures требует build.target: {FIXTURES_TARGET} (FQ-INT-08)")

    postgres = services.get("postgres") or {}
    # 16 §4.4 (07 §10.1, EQ-SRCH-01): кластер с UTF-8 LC_CTYPE — иначе pg_trgm и FTS по-русски не работают.
    initdb = env_map(postgres.get("environment")).get("POSTGRES_INITDB_ARGS", "")
    ctype = re.search(r"--lc-ctype[= ](\S+)", initdb) or re.search(r"--locale[= ](\S+)", initdb)
    if not ctype or not re.search(r"utf-?8", ctype.group(1), re.IGNORECASE):
        errors.append("postgres: POSTGRES_INITDB_ARGS должен задавать UTF-8 LC_CTYPE (--lc-ctype=C.UTF-8 или --locale=C.UTF-8)")
    # 16 §4.4 (EQ-AUTH-08): HMAC OTP — у api и worker (одно значение); ключ подписи JWT и pepper PIN — только api.
    for svc_name in ("api", "worker"):
        env = env_map((services.get(svc_name) or {}).get("environment"))
        if env.get("OTP_HMAC_SECRET_FILE") != "/run/secrets/otp_pepper":
            errors.append(f"{svc_name}: нужен OTP_HMAC_SECRET_FILE=/run/secrets/otp_pepper (16 §4.4, EQ-AUTH-08)")
    worker_env = env_map((services.get("worker") or {}).get("environment"))
    for key in ("JWT_PRIVATE_KEY_FILE", "PIN_PEPPER_FILE"):
        if key in worker_env:
            errors.append(f"worker: {key} не передаётся (минимум прав, 16 §4.4 прим. 6)")
    if "healthcheck" not in postgres:
        errors.append("postgres: нужен healthcheck (pg_isready) — от него зависят migrate/api/worker")
    for dependent in ("api", "worker"):
        deps = (services.get(dependent) or {}).get("depends_on") or {}
        cond = (deps.get("migrate") or {}).get("condition") if isinstance(deps, dict) else None
        if cond != "service_completed_successfully":
            errors.append(f"{dependent}: depends_on migrate должен быть service_completed_successfully")
    if (services.get("migrate") or {}).get("restart") not in ("no", None):
        errors.append("migrate: restart должен быть \"no\" (одноразовый)")
    if base_dir is not None:
        errors.extend(check_api_image(base_dir.parent))
    return errors


def dockerfile_stages(text: str) -> list[tuple[str, str]]:
    """Стадии Dockerfile: [(имя, тело)], имя — `AS <name>` или порядковый номер."""
    stages: list[tuple[str, str]] = []
    name, body = None, []
    for line in text.splitlines():
        m = re.match(r"\s*FROM\s+\S+(?:\s+AS\s+(\S+))?\s*$", line, re.IGNORECASE)
        if m:
            if name is not None:
                stages.append((name, "\n".join(body)))
            name, body = (m.group(1) or str(len(stages))), []
        elif name is not None and not line.lstrip().startswith("#"):
            body.append(line)
    if name is not None:
        stages.append((name, "\n".join(body)))
    return stages


def check_api_image(repo: Path) -> list[str]:
    """Образ optomstroy/api (16 §4.4 прим. (1)–(2); FQ-INT-08, FQ-INT-09): assets и фикстуры по стадиям."""
    errors: list[str] = []
    dockerfile = repo / "infra/docker/api/Dockerfile"
    ignore = repo / "infra/docker/api/Dockerfile.dockerignore"
    if not dockerfile.is_file() or not ignore.is_file():
        return [f"образ api: нет {dockerfile.name} или {ignore.name}"]
    stages = dockerfile_stages(dockerfile.read_text(encoding="utf-8"))
    by_name = dict(stages)
    copies_assets = re.compile(r"^\s*COPY\b.*\bpos-api/assets\s+\./assets\s*$", re.MULTILINE)
    copies_fixtures = re.compile(r"^\s*COPY\b.*\bcontracts/onec/fixtures\s+/contracts/onec/fixtures\s*$", re.MULTILINE)
    if not copies_assets.search(by_name.get("runtime", "")):
        errors.append("образ api: стадия runtime должна копировать pos-api/assets → ./assets (FQ-INT-09)")
    if not copies_fixtures.search(by_name.get(FIXTURES_TARGET, "")):
        errors.append(f"образ api: стадия {FIXTURES_TARGET} должна копировать contracts/onec/fixtures (FQ-INT-08)")
    if not stages or stages[-1][0] == FIXTURES_TARGET or copies_fixtures.search(stages[-1][1]):
        errors.append("образ api: стадия по умолчанию (последняя) не должна содержать фикстуры 1С (прод-образ)")
    for name, body in stages:
        if name not in (FIXTURES_TARGET,) and "contracts/onec/fixtures" in body:
            errors.append(f"образ api: фикстуры 1С копируются в стадии {name} (допустимо только {FIXTURES_TARGET})")
    allowed = {ln.strip() for ln in ignore.read_text(encoding="utf-8").splitlines() if ln.strip().startswith("!")}
    for needed in ("!pos-api/assets/fonts/**", "!pos-api/assets/templates/**", "!contracts/onec/fixtures/**"):
        if needed not in allowed:
            errors.append(f"образ api: в белом списке {ignore.name} нет {needed}")
    if not any((repo / "contracts/onec/fixtures").glob("*.json")):
        errors.append("образ api: каталог contracts/onec/fixtures пуст или отсутствует")
    return errors


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    path = Path(argv[1])
    try:
        if path.suffix in (".yml", ".yaml"):
            import yaml  # PyYAML: поддерживает слияние якорей `<<:` (как Compose)

            cfg = interpolate(yaml.safe_load(path.read_text(encoding="utf-8")))
            base_dir: Path | None = path.resolve().parent
        else:
            cfg = json.loads(path.read_text(encoding="utf-8"))
            base_dir = None
    except Exception as exc:  # noqa: BLE001 — понятное сообщение вместо трассировки
        print(f"не удалось прочитать {path}: {exc}", file=sys.stderr)
        return 2
    errors = check(cfg, base_dir)
    for e in errors:
        print(f"FAIL {e}")
    services = sorted((cfg.get("services") or {}))
    published = {n: sorted(port_target(p) for p in (s.get("ports") or [])) for n, s in (cfg.get("services") or {}).items() if s.get("ports")}
    print(f"сервисы: {', '.join(services)}; опубликованные порты: {published}")
    print("ИТОГ: " + ("OK — нарушений нет" if not errors else f"нарушений {len(errors)}"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

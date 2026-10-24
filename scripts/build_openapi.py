#!/usr/bin/env python3
"""RM-B-003: детерминированная сборка contracts/openapi/pos-api.v1.yaml из contracts/openapi/parts/*.yaml.

Правила (contracts/openapi/NOTES.md §1, §7):
  * parts/00_root.yaml — корень: openapi, info, servers, security, tags, components (paths: {}).
  * parts/NN_<module>.yaml — фрагменты: в сборку берутся только `paths` и `components`; ключи `openapi`
    (обязан совпадать с корнем) и `info` (заголовок фрагмента) игнорируются; любые другие ключи
    верхнего уровня (servers, security, tags, x-*) во фрагменте — ошибка сборки.
  * paths: один и тот же путь может встречаться в нескольких частях только с разными HTTP-методами;
    одинаковый метод (или одинаковый не-методный ключ пути, например parameters) с разным содержимым —
    ошибка; полностью одинаковое содержимое — дубликат, сливается молча.
  * components.<section>.<name>: одинаковое имя с разным содержимым в двух частях — ошибка
    (переопределять имена корня запрещено); одинаковое содержимое — сливается.
  * Сортировка: пути — по алфавиту; методы внутри пути — get, put, post, delete, options, head, patch,
    trace (порядок OAS), не-методные ключи пути — перед методами; секции components — в порядке OAS 3.0,
    имена внутри секции — по алфавиту. Порядок ключей внутри операций и схем — как у автора части.
  * operationId: обязателен у каждой операции и уникален во всём документе (08 §8).
  * Все локальные $ref (#/...) обязаны разрешаться в собранном документе; внешние $ref запрещены.
  * Теги операций — только из списка tags корня.

Запуск (без сети; код выхода 0 — успех, 1 — ошибки сборки/рассинхрон, 2 — ошибка запуска):
  python -I -X utf8 scripts/build_openapi.py [--root D:/optomstroy] [--check] [--out FILE]
  --check — ничего не пишет; сравнивает результат сборки с файлом на диске (код 1 при расхождении).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: нужен пакет pyyaml", file=sys.stderr)
    sys.exit(2)

PARTS_DIR = "contracts/openapi/parts"
OUT_FILE = "contracts/openapi/pos-api.v1.yaml"
ROOT_PART = "00_root.yaml"
METHODS = ("get", "put", "post", "delete", "options", "head", "patch", "trace")
COMPONENT_ORDER = ("schemas", "responses", "parameters", "examples", "requestBodies", "headers",
                   "securitySchemes", "links", "callbacks")
FRAGMENT_KEYS = {"openapi", "info", "paths", "components"}
HEADER = (
    "# =====================================================================================\n"
    "# ФАЙЛ СОБРАН АВТОМАТИЧЕСКИ — НЕ РЕДАКТИРОВАТЬ ВРУЧНУЮ.\n"
    "# Источник: contracts/openapi/parts/*.yaml; сборщик: scripts/build_openapi.py (RM-B-003).\n"
    "# Правила частей и решения авторов — contracts/openapi/NOTES.md и комментарии в шапках частей.\n"
    "# Части: {parts}\n"
    "# =====================================================================================\n"
)


class BuildError(Exception):
    pass


class _NoAliasDumper(yaml.SafeDumper):
    def ignore_aliases(self, data):  # noqa: D401 - PyYAML API
        return True


def _str_presenter(dumper: yaml.SafeDumper, data: str):
    style = "|" if "\n" in data else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style=style)


_NoAliasDumper.add_representer(str, _str_presenter)


class _UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader, который отвергает повторяющиеся ключи в одном отображении."""


def _construct_mapping(loader: _UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False):
    loader.flatten_mapping(node)
    seen: set = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise yaml.constructor.ConstructorError(
                None, None, f"повторяющийся ключ {key!r}", key_node.start_mark)
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


_UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)


def canon(obj) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def load_part(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=_UniqueKeyLoader)  # noqa: S506 - SafeLoader subclass
    except yaml.YAMLError as exc:
        raise BuildError(f"{path.name}: ошибка YAML: {exc}") from exc
    if not isinstance(data, dict):
        raise BuildError(f"{path.name}: верхний уровень должен быть отображением")
    return data


def sort_path_item(item: dict) -> dict:
    non_methods = [k for k in item if k not in METHODS]
    return {**{k: item[k] for k in non_methods}, **{m: item[m] for m in METHODS if m in item}}


def iter_refs(node, where: str):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "$ref" and isinstance(v, str):
                yield v, where
            else:
                yield from iter_refs(v, f"{where}/{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from iter_refs(v, f"{where}/{i}")


def resolve_pointer(doc, ref: str) -> bool:
    if not ref.startswith("#/"):
        return False
    cur = doc
    for raw in ref[2:].split("/"):
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(cur, dict) and token in cur:
            cur = cur[token]
        elif isinstance(cur, list) and token.isdigit() and int(token) < len(cur):
            cur = cur[int(token)]
        else:
            return False
    return True


def build(root_dir: Path) -> tuple[dict, list[str], list[str]]:
    parts_dir = root_dir / PARTS_DIR
    files = sorted(p for p in parts_dir.glob("*.yaml") if p.is_file())
    if not files or files[0].name != ROOT_PART:
        raise BuildError(f"нет {PARTS_DIR}/{ROOT_PART} или он не первый по порядку")
    errors: list[str] = []
    warnings: list[str] = []

    root = load_part(files[0])
    for key in ("openapi", "info", "paths", "components"):
        if key not in root:
            errors.append(f"{ROOT_PART}: нет ключа {key}")
    if errors:
        raise BuildError("; ".join(errors))
    if root.get("paths"):
        errors.append(f"{ROOT_PART}: корень не должен содержать paths (NOTES §1)")

    paths: dict[str, dict] = {}
    path_origin: dict[tuple[str, str], str] = {}
    components: dict[str, dict] = {}
    comp_origin: dict[tuple[str, str], str] = {}

    def add_components(src_name: str, comps) -> None:
        if comps is None:
            return
        if not isinstance(comps, dict):
            errors.append(f"{src_name}: components должен быть отображением")
            return
        for section, entries in comps.items():
            if section not in COMPONENT_ORDER:
                errors.append(f"{src_name}: неизвестная секция components.{section}")
                continue
            if not isinstance(entries, dict):
                errors.append(f"{src_name}: components.{section} должен быть отображением")
                continue
            target = components.setdefault(section, {})
            for name, value in entries.items():
                key = (section, name)
                if name in target:
                    if canon(target[name]) != canon(value):
                        errors.append(
                            f"конфликт имён: components.{section}.{name} — разное содержимое в "
                            f"{comp_origin[key]} и {src_name}")
                    else:
                        warnings.append(
                            f"дубликат components.{section}.{name} в {comp_origin[key]} и {src_name} "
                            f"(содержимое совпадает, слито)")
                    continue
                target[name] = value
                comp_origin[key] = src_name

    add_components(ROOT_PART, root.get("components"))

    for part in files[1:]:
        data = load_part(part)
        extra = set(data) - FRAGMENT_KEYS
        if extra:
            errors.append(f"{part.name}: недопустимые ключи верхнего уровня во фрагменте: {sorted(extra)}")
        if "openapi" in data and str(data["openapi"]) != str(root["openapi"]):
            errors.append(f"{part.name}: openapi {data['openapi']} ≠ корневому {root['openapi']}")
        add_components(part.name, data.get("components"))
        part_paths = data.get("paths") or {}
        if not isinstance(part_paths, dict):
            errors.append(f"{part.name}: paths должен быть отображением")
            continue
        for p, item in part_paths.items():
            if not isinstance(p, str) or not p.startswith("/"):
                errors.append(f"{part.name}: путь {p!r} должен начинаться с '/'")
                continue
            if not isinstance(item, dict):
                errors.append(f"{part.name}: {p}: элемент пути должен быть отображением")
                continue
            target = paths.setdefault(p, {})
            for k, v in item.items():
                okey = (p, k)
                if k in target:
                    if canon(target[k]) != canon(v):
                        errors.append(f"конфликт пути: {p} [{k}] — разное содержимое в "
                                      f"{path_origin[okey]} и {part.name}")
                    else:
                        warnings.append(f"дубликат {p} [{k}] в {path_origin[okey]} и {part.name} (слито)")
                    continue
                target[k] = v
                path_origin[okey] = part.name

    # Сборка документа: порядок ключей верхнего уровня — как в корне, paths — отсортированы.
    sorted_paths = {p: sort_path_item(paths[p]) for p in sorted(paths)}
    sorted_components = {}
    for section in COMPONENT_ORDER:
        if section in components:
            sorted_components[section] = {n: components[section][n] for n in sorted(components[section])}
    doc: dict = {}
    for key, value in root.items():
        if key == "paths":
            doc["paths"] = sorted_paths
        elif key == "components":
            doc["components"] = sorted_components
        else:
            doc[key] = value

    # operationId: обязателен и уникален; теги — из корня.
    root_tags = {t.get("name") for t in root.get("tags") or [] if isinstance(t, dict)}
    op_ids: dict[str, str] = {}
    op_count = 0
    for p, item in sorted_paths.items():
        for m in METHODS:
            if m not in item:
                continue
            op_count += 1
            op = item[m]
            label = f"{m.upper()} {p}"
            if not isinstance(op, dict):
                errors.append(f"{label}: операция должна быть отображением")
                continue
            oid = op.get("operationId")
            if not oid:
                errors.append(f"{label}: нет operationId")
            elif oid in op_ids:
                errors.append(f"operationId {oid!r} не уникален: {op_ids[oid]} и {label}")
            else:
                op_ids[oid] = label
            for tag in op.get("tags") or []:
                if tag not in root_tags:
                    errors.append(f"{label}: тег {tag!r} отсутствует в tags корня")

    # $ref: только локальные и разрешимые.
    for ref, where in iter_refs(doc, "#"):
        if not ref.startswith("#/"):
            errors.append(f"внешний $ref {ref!r} в {where} (во фрагментах ссылки пишутся как #/components/...)")
        elif not resolve_pointer(doc, ref):
            errors.append(f"неразрешимый $ref {ref!r} в {where}")

    stats = (f"части: {len(files)} ({', '.join(f.name for f in files)}); путей: {len(sorted_paths)}; "
             f"операций: {op_count}; компонентов: "
             + ", ".join(f"{s}={len(v)}" for s, v in sorted_components.items()))
    warnings.insert(0, stats)
    doc["__parts__"] = [f.name for f in files]
    return doc, errors, warnings


def render(doc: dict) -> str:
    parts = doc.pop("__parts__")
    body = yaml.dump(doc, Dumper=_NoAliasDumper, sort_keys=False, allow_unicode=True,
                     width=4096, default_flow_style=False, indent=2)
    return HEADER.format(parts=", ".join(parts)) + body


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--out", default=None, help=f"файл результата (по умолчанию {OUT_FILE})")
    ap.add_argument("--check", action="store_true", help="сравнить с файлом на диске, ничего не писать")
    args = ap.parse_args()
    root_dir = Path(args.root)
    out = Path(args.out) if args.out else root_dir / OUT_FILE
    try:
        doc, errors, warnings = build(root_dir)
    except BuildError as exc:
        print(f"ERROR: {exc}")
        return 1
    except OSError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    for w in warnings:
        print(f"INFO: {w}")
    if errors:
        for e in errors:
            print(f"ERROR: {e}")
        print(f"FAIL: ошибок сборки: {len(errors)}; файл не записан")
        return 1
    text = render(doc)
    # Самопроверка: результат читается обратно без потерь.
    reread = yaml.safe_load(text)
    if canon(reread) != canon({k: v for k, v in doc.items()}):
        print("ERROR: собранный YAML при повторном чтении отличается от модели")
        return 1
    data = text.encode("utf-8")
    digest = hashlib.sha256(data).hexdigest()
    if args.check:
        current = out.read_bytes() if out.exists() else b""
        if current != data:
            print(f"FAIL: {out} не совпадает с результатом сборки (пересоберите: python scripts/build_openapi.py)")
            return 1
        print(f"OK: {out} актуален; sha256={digest}")
        return 0
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("wb") as fh:
        fh.write(data)
    print(f"OK: записан {out} ({len(data)} байт); sha256={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

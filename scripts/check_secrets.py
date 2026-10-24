#!/usr/bin/env python3
"""RM-C-001: поиск секретов в репозитории (временная замена `gitleaks detect` до RM-C-011).

Что проверяется. Код выхода: 0 — находок нет, 1 — есть находки, 2 — ошибка запуска.
  1. Запрещённые имена файлов: .env (кроме .env.example), *.pfx, *.p12, *.pem, *.key, *.jks,
     *.keystore, key.properties, id_rsa/id_ed25519, secrets/** (CONTRIBUTING.md §1 п. 7; 16 §4.3).
  2. Высокоточные шаблоны по всем файлам, включая документацию:
     - блоки приватных ключей PEM;
     - ключи AWS, GitHub, GitLab, Slack, Google API, Stripe live, OpenAI/Anthropic;
     - токены Telegram-бота;
     - JWT с подписью;
     - URL с паролем (`scheme://user:password@host`).
  3. Общие шаблоны «имя = значение» (password, secret, token, api_key, …) с непустым значением.
     Они не проверяются в файлах документации (белый список DOC_ALLOW), иначе ТЗ с примерами
     дало бы ложные находки. Значения-заглушки (<...>, ${...}, changeme, example, *_FILE, …)
     не считаются секретами.

Набор файлов по умолчанию — то, что может попасть в git:
`git ls-files` (отслеживаемые) + `git ls-files --others --exclude-standard` (новые, не игнорируемые).
Режим --all обходит дерево целиком, кроме служебных каталогов (node_modules, .dart_tool, build, .git).
Двоичные файлы (есть байт 0) и файлы больше 5 МБ пропускаются.

Подавление находки в строке: комментарий `check-secrets: allow` с причиной в той же строке.

Самопроверка шаблонов (положительный контроль, без чтения репозитория): --self-test.

Сетевых запросов нет. Запуск: python -I -X utf8 scripts/check_secrets.py [--root D:/optomstroy] [--all] [--self-test] [-v]
"""
from __future__ import annotations

import argparse
import fnmatch
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

MAX_BYTES = 5 * 1024 * 1024
ALLOW_MARK = "check-secrets: allow"

# Каталоги, которые не обходятся в режиме --all (генерируемые / сторонние).
SKIP_DIRS = {
    ".git", "node_modules", ".dart_tool", "build", ".gradle", ".idea", ".tmp",
    "__pycache__", ".pub-cache", "Pods", ".venv", "dist", "coverage",
}

# 1. Запрещённые имена файлов (glob по имени файла или по пути POSIX).
FORBIDDEN_FILES = [
    (".env", "dotenv-file"),
    (".env.*", "dotenv-file"),
    ("*.pfx", "certificate-bundle"),
    ("*.p12", "certificate-bundle"),
    ("*.pem", "pem-file"),
    ("*.key", "private-key-file"),
    ("*.jks", "java-keystore"),
    ("*.keystore", "java-keystore"),
    ("key.properties", "android-signing-properties"),
    ("id_rsa", "ssh-private-key"),
    ("id_ed25519", "ssh-private-key"),
    ("id_ecdsa", "ssh-private-key"),
]
FORBIDDEN_ALLOW = {".env.example"}
FORBIDDEN_DIR_PARTS = {"secrets"}

# Белый список документации: только для общих шаблонов (п. 3).
DOC_ALLOW = [
    "docs/**",
    "resursi/**",
    "*.md",
    "**/*.md",
    "contracts/l10n/*.arb",  # тексты UI («Пароль», «Токен» и т. п.)
]

# 2. Высокоточные шаблоны — проверяются везде.
STRICT_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("private-key-block", re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----")),
    ("aws-access-key-id", re.compile(r"\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b")),
    ("github-token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b")),
    ("github-fine-grained-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{60,}\b")),
    ("gitlab-pat", re.compile(r"\bglpat-[A-Za-z0-9_\-]{20,}\b")),
    ("slack-token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}\b")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("stripe-live-key", re.compile(r"\b(?:sk|rk)_live_[0-9A-Za-z]{20,}\b")),
    ("openai-anthropic-key", re.compile(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{32,}\b")),
    ("telegram-bot-token", re.compile(r"\b\d{8,10}:AA[A-Za-z0-9_\-]{33}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{20,}")),
    ("url-with-password", re.compile(
        r"\b[a-z][a-z0-9+.\-]{1,20}://[^\s:/@'\"<>{}]{1,64}:([^\s:/@'\"<>{}]{3,128})@[A-Za-z0-9.\-\[\]]+")),
]

# 3. Общие шаблоны «ключ = значение». Группа 'val' — значение.
GENERIC_KEY = (
    r"(?:password|passwd|pwd|pass|secret|client_secret|api[_\-]?key|apikey|access[_\-]?key|"
    r"secret[_\-]?key|private[_\-]?key|auth[_\-]?token|access[_\-]?token|refresh[_\-]?token|"
    r"bearer|token|sms[_\-]?pro[_\-]?(?:password|key)|jwt[_\-]?secret|pepper|salt)"
)
GENERIC_RULE = re.compile(
    r"(?i)(?:^|[^A-Za-z0-9])[A-Za-z0-9_.\-]*" + GENERIC_KEY + r"[A-Za-z0-9_\-]*['\"]?\s*(?::=|=|:)\s*"
    r"(?P<q>['\"]?)(?P<val>[^\s'\",;#}{)(\]\[]{8,})(?P=q)"
)

# Значения-заглушки и ссылки, которые не являются секретами.
PLACEHOLDER_RE = re.compile(
    r"(?i)^(?:<.*>|\$\{.*\}|\$\(.*\)|\{\{.*\}\}|%[A-Z_]+%|\*+|x{3,}|\.{3,}|"
    r".*(?:changeme|change_me|example|placeholder|dummy|sample|redacted|your[_\-]|todo|fixme).*|"
    r".*_FILE|/run/secrets/.*|process\.env\..*|env\(.*\)|os\.environ.*|"
    r"(?:true|false|null|none|undefined|string|integer|number|boolean|required|optional))$"
)
# Значение похоже на идентификатор/ссылку, а не на секрет: имя переменной, путь, тип, ключ ARB.
IDENT_RE = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*(?:\(\))?|[./~][\w./\-]*)$")


@dataclass
class Finding:
    path: str
    line: int
    rule: str
    excerpt: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: [{self.rule}] {self.excerpt}"


def mask(value: str) -> str:
    v = value.strip()
    if len(v) <= 8:
        return "*" * len(v)
    return v[:4] + "…" + "*" * 4 + f" ({len(v)} симв.)"


def match_any(path: str, patterns: list[str]) -> bool:
    p = PurePosixPath(path)
    return any(fnmatch.fnmatch(path, pat) or p.match(pat) for pat in patterns)


def is_placeholder(value: str, quoted: bool = False) -> bool:
    v = value.strip().strip("'\"")
    if not v.isascii():
        # Секреты — ASCII; кириллица в значении — это текст («= расшифрованный …»), а не ключ.
        return True
    if PLACEHOLDER_RE.match(v):
        return True
    # Без кавычек значение может быть ссылкой на переменную/поле/тип (response.data.token, string).
    # Считаем это идентификатором, если в нём нет цифр или есть точка/вызов.
    if not quoted and IDENT_RE.match(v) and (not any(c.isdigit() for c in v) or "." in v or "(" in v):
        return True
    # Значение enum-а / ключа словаря: только строчные латинские слова через «_» («registration», «sms_pro»).
    if re.fullmatch(r"[a-z_]+", v):
        return True
    # Строчные слова через «-» («step-token», «correct-horse-battery-staple») — НЕ заглушка нигде, в том числе в
    # файлах тестов: парольная фраза из строчных слов через дефис — секрет (ревью E R2-N-01, RC-7: исключение
    # для тестовых путей снято). Метка тестовых данных освобождается только точечно: `check-secrets: allow — причина`.
    # Низкая энтропия: одно повторяющееся значение («aaaaaaaa», «12345678»).
    if len(set(v)) <= 3:
        return True
    return False


def check_file_name(rel: str) -> Finding | None:
    name = PurePosixPath(rel).name
    if name in FORBIDDEN_ALLOW:
        return None
    for pat, rule in FORBIDDEN_FILES:
        if fnmatch.fnmatch(name, pat):
            return Finding(rel, 0, f"forbidden-file:{rule}", "файл с секретом не должен быть в репозитории")
    parts = PurePosixPath(rel).parts[:-1]
    if any(part in FORBIDDEN_DIR_PARTS for part in parts):
        return Finding(rel, 0, "forbidden-file:secrets-dir", "каталог secrets/ не должен быть в репозитории")
    return None


def scan_text(rel: str, text: str, is_doc: bool) -> list[Finding]:
    out: list[Finding] = []
    for no, line in enumerate(text.splitlines(), start=1):
        if ALLOW_MARK in line:
            continue
        for rule, rx in STRICT_RULES:
            m = rx.search(line)
            if not m:
                continue
            if rule == "url-with-password" and is_placeholder(m.group(1)):
                continue
            out.append(Finding(rel, no, rule, mask(m.group(0))))
        if is_doc:
            continue
        for m in GENERIC_RULE.finditer(line):
            val = m.group("val")
            if is_placeholder(val, quoted=bool(m.group("q"))):
                continue
            out.append(Finding(rel, no, "generic-secret-assignment", mask(val)))
    return out


def scan_path(root: Path, rel: str) -> list[Finding]:
    findings: list[Finding] = []
    f = check_file_name(rel)
    if f:
        findings.append(f)
    full = root / rel
    try:
        if not full.is_file() or full.stat().st_size > MAX_BYTES:
            return findings
        data = full.read_bytes()
    except OSError:
        return findings
    if b"\x00" in data[:8192]:
        return findings
    text = data.decode("utf-8", errors="replace")
    findings.extend(scan_text(rel, text, match_any(rel, DOC_ALLOW)))
    return findings


def git_files(root: Path) -> list[str]:
    def run(args: list[str]) -> list[str]:
        res = subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=True)
        return [p for p in res.stdout.decode("utf-8").split("\0") if p]

    tracked = run(["ls-files", "-z", "--cached"])
    untracked = run(["ls-files", "-z", "--others", "--exclude-standard"])
    # Удалённые в рабочей копии (перенос без коммита) не существуют на диске — scan_path их пропустит.
    return sorted(set(tracked) | set(untracked))


def walk_files(root: Path) -> list[str]:
    out: list[str] = []
    stack = [root]
    while stack:
        d = stack.pop()
        for entry in d.iterdir():
            if entry.is_dir():
                if entry.name not in SKIP_DIRS:
                    stack.append(entry)
            elif entry.is_file():
                out.append(entry.relative_to(root).as_posix())
    return sorted(out)


def self_test() -> int:
    """Положительный и отрицательный контроль. Образцы собираются из частей, чтобы
    исходный текст этого файла не содержал строк, похожих на секреты."""
    j = "".join
    positives = {
        "private-key-block": j(["-----BEGIN ", "RSA PRIVATE", " KEY-----"]),
        "aws-access-key-id": j(["AKIA", "Q7ZB3K2M9XW4TL6P"]),
        "github-token": j(["ghp", "_", "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"]),
        "google-api-key": j(["AIza", "SyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q"]),
        "jwt": j(["eyJ", "hbGciOiJIUzI1NiJ9", ".eyJ", "zdWIiOiIxMjM0NSJ9", ".", "Zm9vYmFyYmF6cXV4cXV1eGNvcmdl"]),
        "url-with-password": j(["postgres://pos:", "Kq8#vR2m", "@db.local:5432/pos"]),
        "generic-secret-assignment": j(["SMSPRO_", "PASSWORD=", "Zx9vQ2", "pL7wE4"]),
    }
    negatives = [
        "SMSPRO_PASSWORD_FILE=/run/secrets/smspro_password",
        "JWT_SECRET=${JWT_SECRET}",
        "password: <пароль из секрет-хранилища>",
        "DATABASE_URL=postgres://pos:changeme@localhost:5432/pos",
        "final token = response.data.accessToken;",
        "apiKey: process.env.API_KEY",
        "token: string",
        "CHECK (reason <> 'used' OR token_kind = 'registration')",
    ]
    # Строчные слова через дефис — находка везде, в том числе в файлах тестов (R2-N-01, RC-7); тестовую метку
    # освобождает только пометка `check-secrets: allow — причина` в той же строке.
    hyphen_labels = [
        j(["return json(200, {'enabled': true, 'biometricRefreshToken': '", "bio", "-secret'});"]),
        j(["expect(port.starts.single, (mode: SyncMode.full, key: 'idem-1', token: '", "step", "-token'));"]),
    ]
    test_rels = ["pos-app/test/features/x_test.dart", "pos-api/test/x.spec.ts", "pos-app/integration_test/x_test.dart"]
    test_negatives = [
        (rel, s + " // check-secrets: allow — метка тестовых данных, не секрет") for rel in test_rels for s in hyphen_labels
    ]
    # Дефис + цифры/заглавные и строчные слова через дефис — находка и вне тестов, и в тестах (без пометки).
    positives_extra = [
        ("sample.ts", j(["token: '", "k8s-Zq7", "-wX2p'"])),
        ("sample.ts", j(["password = '", "Correct-Horse", "-Battery'"])),
        ("sample.ts", j(["password = '", "correct-horse", "-battery-staple'"])),
        ("pos-api/src/auth/x.ts", hyphen_labels[0]),
        ("pos-app/lib/x.dart", hyphen_labels[1]),
        ("pos-app/test/x_test.dart", j(["password = '", "Correct-Horse", "-Battery'"])),
        ("pos-app/test/x_test.dart", j(["password = '", "correct-horse", "-battery-staple'"])),
        ("pos-api/test/x.spec.ts", j(["const passphrase = { password: '", "correct-horse", "-battery-staple' };"])),
    ] + [(rel, s) for rel in test_rels for s in hyphen_labels]
    failed = 0
    for rule, sample in positives.items():
        got = {f.rule for f in scan_text("sample.env", sample, is_doc=False)}
        ok = rule in got
        failed += not ok
        print(f"  {'ok ' if ok else 'FAIL'} positive  {rule}: найдено {sorted(got) or '—'}")
    for rel, sample in positives_extra:
        got = {f.rule for f in scan_text(rel, sample, is_doc=False)}
        ok = "generic-secret-assignment" in got
        failed += not ok
        print(f"  {'ok ' if ok else 'FAIL'} positive  generic-secret-assignment (дефис, {rel}): "
              f"найдено {sorted(got) or '—'}")
    for rel, sample in test_negatives:
        got = scan_text(rel, sample, is_doc=False)
        ok = not got
        failed += not ok
        print(f"  {'ok ' if ok else 'FAIL'} negative  метка теста через дефис с пометкой allow ({rel}): "
              f"{'нет находок' if ok else [str(g) for g in got]}")
    for sample in negatives:
        got = scan_text("sample.ts", sample, is_doc=False)
        ok = not got
        failed += not ok
        print(f"  {'ok ' if ok else 'FAIL'} negative  {sample!r}: {'нет находок' if ok else [str(g) for g in got]}")
    # Документация: общий шаблон не применяется, строгий — применяется.
    doc_generic = scan_text("docs/x.md", positives["generic-secret-assignment"], is_doc=True)
    doc_strict = scan_text("docs/x.md", positives["aws-access-key-id"], is_doc=True)
    ok = not doc_generic and bool(doc_strict)
    failed += not ok
    print(f"  {'ok ' if ok else 'FAIL'} doc-allowlist: generic пропущен, strict найден")
    names_bad = [".env", ".env.production", "release.jks", "server.pem", "a/secrets/db.txt", "android/key.properties"]
    names_ok = [".env.example", "lib/main.dart", "docs/keys.md"]
    for n in names_bad:
        ok = check_file_name(n) is not None
        failed += not ok
        print(f"  {'ok ' if ok else 'FAIL'} forbidden-name {n}")
    for n in names_ok:
        ok = check_file_name(n) is None
        failed += not ok
        print(f"  {'ok ' if ok else 'FAIL'} allowed-name   {n}")
    print(f"self-test: {'OK' if not failed else f'{failed} ошибок'}")
    return 0 if not failed else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--all", action="store_true", help="обойти всё дерево, а не только файлы git")
    ap.add_argument("--self-test", action="store_true", help="проверить сами шаблоны на образцах")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    root: Path = args.root.resolve()
    if not root.is_dir():
        print(f"ошибка: нет каталога {root}", file=sys.stderr)
        return 2
    try:
        files = walk_files(root) if args.all else git_files(root)
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"ошибка: не удалось получить список файлов: {e}", file=sys.stderr)
        return 2

    findings: list[Finding] = []
    scanned = 0
    for rel in files:
        if not (root / rel).exists():
            continue
        scanned += 1
        res = scan_path(root, rel)
        if args.verbose and res:
            print(f"-- {rel}: {len(res)}")
        findings.extend(res)

    for f in findings:
        print(f)
    mode = "дерево (--all)" if args.all else "git ls-files + новые неигнорируемые"
    print(f"check_secrets: режим {mode}; файлов проверено: {scanned}; находок: {len(findings)}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

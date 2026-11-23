#!/bin/sh
# archive_command PostgreSQL рабочего контура (непрерывная копия WAL, PITR; RUNBOOK §4.8; 15 ADR-035; 16 §8.1
# «RPO при PITR ≤ 15 мин»). Вызов (compose.prod.yml, сервис postgres; каталог смонтирован только для чтения):
#   archive_command = 'sh /opt/optomstroy/pg/wal-archive.sh %p %f'   (%p — путь относительно PGDATA, без пробелов)
# Что делает: копирует готовый сегмент WAL (или файл .history / .backup / .partial) в спул /walspool — каталог на
# диске базы (/srv/optomstroy/<контур>/walspool, владелец 999, группа 10002 — сервис backup, права 2770). Дальше
# сервис backup в течение ~20 с сжимает файл, шифрует age в backups/pitr/<system_identifier>/wal/ и удаляет его из
# спула (infra/docker/backup/backup.sh, wal_ship). Незашифрованный WAL на диск копий и вне сервера не попадает.
# Правила (документация PostgreSQL «Continuous Archiving», раздел о archive_command):
#   - ноль — только когда файл целиком и надёжно записан: копия во временный файл, fsync файла, атомарная публикация
#     жёсткой ссылкой (ln не перезаписывает существующий файл), fsync каталога;
#   - файл с тем же именем уже в спуле: то же содержимое — успех (повтор после сбоя), другое — отказ (код 1),
#     ничего не перезаписывается;
#   - любой сбой — ненулевой код: PostgreSQL сегмент не удаляет и повторяет архивацию; счётчик failed_count в
#     pg_stat_archiver делает сервис backup unhealthy (backup.sh health).
# Права: postgres работает с umask 077, а файл должен читать сервис backup (группа каталога, бит setgid) — 640.
# Переменная WAL_SPOOL_DIR (по умолчанию /walspool) — только для проверочного прогона вне Docker.
set -eu
umask 027

src="${1:-}"
name="${2:-}"
dir="${WAL_SPOOL_DIR:-/walspool}"

case "$name" in
  ''|*/*|.*) echo "wal-archive: неверное имя файла WAL" >&2; exit 2 ;;
esac
[ -n "$src" ] && [ -f "$src" ] || { echo "wal-archive: нет исходного файла $name" >&2; exit 1; }
[ -d "$dir" ] && [ -w "$dir" ] || { echo "wal-archive: спул $dir недоступен для записи" >&2; exit 1; }

dst="$dir/$name"
if [ -e "$dst" ]; then
  if cmp -s "$src" "$dst"; then
    exit 0
  fi
  echo "wal-archive: $name уже есть в спуле с другим содержимым — не перезаписывается" >&2
  exit 1
fi

tmp="$dir/.$name.tmp"
rm -f "$tmp"
if ! cp "$src" "$tmp"; then
  rm -f "$tmp"
  echo "wal-archive: копирование $name не удалось" >&2
  exit 1
fi
chmod 640 "$tmp"
sync "$tmp"
if ! ln "$tmp" "$dst" 2>/dev/null; then
  rm -f "$tmp"
  if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
    exit 0
  fi
  echo "wal-archive: $name не опубликован в спуле (ln)" >&2
  exit 1
fi
rm -f "$tmp"
sync "$dir"
exit 0

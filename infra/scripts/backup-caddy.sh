#!/usr/bin/env bash
# Копия сертификатов общего caddy — том optomstroy-edge_caddy_data (16 §8.2 «Сертификаты (caddy_data) — включить в
# суточную копию»; RUNBOOK §4.1). Запускает таймер systemd optomstroy-caddy-backup.timer (ставит install.sh, ежедневно
# в 06:00 по Бишкеку: пояс Asia/Bishkek указан в самом таймере и не зависит от пояса сервера) или администратор вручную:
#   sudo /opt/optomstroy/prod/bin/backup-caddy.sh
# Как: одноразовый контейнер образа backup под root без сети и без возможностей читает том только для чтения (файлы
# caddy принадлежат root, права 600) и отдаёт tar в stdin `backup.sh store-caddy` сервиса backup (uid 10002) → age →
# /srv/optomstroy/prod/backups/caddy_data/caddy_data_<UTC>.tar.age. Незашифрованный архив на диск не пишется; по коду
# всего конвейера архив принимается (commit-caddy) или удаляется (discard-caddy). Хранение — 30 суток, выгрузка вне
# сервера — ежедневным прогоном backup (<BACKUP_REMOTE>/caddy_data). Сертификаты перевыпускаемы: сбой здесь не
# останавливает остальные копии, но даёт код 1 (таймер — failed, журнал — journalctl -u optomstroy-caddy-backup).
# Коды выхода: 0 — копия сделана; 1 — ошибка.
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

need_root
check_docker
resolve_dirs "$HERE"
[ "$CONTOUR" = prod ] || die "копию сертификатов общего caddy делает рабочий контур (/opt/optomstroy/prod/bin)"
[ -f "$ENV_FILE" ] || die "в $PROD_DIR нет установленного контура"
check_secrets
compose_init
img="optomstroy/backup:$(env_get "$ENV_FILE" BACKUP_TAG)"
image_exists "$img" || die "образа $img нет (install.sh / update.sh)"
vol="${EDGE_PROJECT}_caddy_data"
docker volume inspect "$vol" >/dev/null 2>&1 || die "нет тома $vol — общий caddy ещё не запускался (bin/dc-edge up -d)"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
rc=0
docker run --rm --network none --user 0:0 --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    -v "$vol:/caddy_data:ro" --entrypoint /bin/tar "$img" -C /caddy_data -cf - . \
  | dc run --rm -T --no-deps backup store-caddy "$stamp" || rc=$?
if [ "$rc" -eq 0 ]; then
  dc run --rm -T --no-deps backup commit-caddy "$stamp" || die "архив сертификатов не принят — bin/dc logs backup"
  log "копия сертификатов caddy: backups/caddy_data/caddy_data_$stamp.tar.age"
else
  dc run --rm -T --no-deps backup discard-caddy "$stamp" >/dev/null 2>&1 || true
  die "копия сертификатов caddy не сделана (код $rc) — повторится по таймеру; сертификаты перевыпускаемы (16 §8.3)"
fi

#!/usr/bin/env sh
# Запуск pos-app с профилем (по умолчанию dev, RM-C-009): tool/run_dev.sh [профиль] [устройство]
set -eu
cd "$(dirname "$0")/.."
# env/local.json (вне git) — значения машины разработки, например APP_DATA_DIR (env/README.md).
if [ -f env/local.json ]; then
  exec flutter run -d "${2:-windows}" "--dart-define-from-file=env/${1:-dev}.json" "--dart-define-from-file=env/local.json"
fi
exec flutter run -d "${2:-windows}" "--dart-define-from-file=env/${1:-dev}.json"

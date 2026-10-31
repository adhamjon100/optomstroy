# pos-app/env — конфигурация сборки Flutter (RM-C-009, 06 §6.9)

Только несекретные значения: `--dart-define-from-file=env/<профиль>.json`. Ключи разбирает
`lib/core/config/environment.dart` (`API_BASE_URL`, `ENV`, `LOG_LEVEL`, `FEATURE_FLAGS`, `FEATURE_*`, `APP_DATA_DIR`);
`DEMO_BACKEND` читает только точка входа веб-демо `lib/app/demo/main_web_demo.dart` (15 ADR-113).

`APP_DATA_DIR` (только `dev`/`staging`; в `prod` игнорируется) — абсолютный каталог данных приложения: БД drift
`pos_<user_id>.db`, файл secure storage и кэш пишутся в его подкаталоги (`support/`, `documents/`, `cache/`, `tmp/`)
вместо каталога ОС (`%APPDATA%\com.example\optomstroy` на C:) — `lib/core/config/app_data_directory.dart`. Путь зависит от
машины, поэтому в общих профилях (`dev.json`, `dev_proxy.json`) его нет: он задаётся в `env/local.json` (вне git,
`pos-app/.gitignore`; образец — `local.json.example`) и передаётся вторым файлом:
`--dart-define-from-file=env/dev.json --dart-define-from-file=env/local.json`. `tool/run_dev.*` добавляют
`env/local.json`, если он есть; команды integration_test в заголовках тестов — тоже. Без `env/local.json` данные — в
каталоге ОС. Значение — только константа сборки, не пользовательский ввод.

| Файл | ENV | API_BASE_URL | Где |
|---|---|---|---|
| `dev.json` | `dev` | `http://127.0.0.1:3000/api/v1` | локальный pos-api (`pos-api/scripts/local-stack.mjs serve`) |
| `dev_proxy.json` | `dev` | `http://127.0.0.1:8080/api/v1` | тот же локальный стек через мини-прокси «как Caddy» (`/images/{sha}/{size}` — фото каталога; этап E); integration_test |
| `staging.json` | `staging` | `https://localhost/api/v1` | тестовый контур `infra/compose.test.yml` через pos-proxy (RM-C-012) |
| `web_demo.json` | `dev` | `https://demo.invalid/api/v1` — заглушка: во время работы точка входа заменяет его на `<origin сайта>/api/v1` | веб-демо на Netlify (15 ADR-113): только `flutter build web -t lib/app/demo/main_web_demo.dart`; `DEMO_BACKEND=browser` — запросы идут в сервер внутри браузера, а не в сеть; без `APP_DATA_DIR` |
| `local.json` | — | — | вне git: значения машины разработки (`APP_DATA_DIR`), второй `--dart-define-from-file`; образец `local.json.example` |
| `prod.json` | `prod` | — | **не создан**: адрес сервера заказчика не определён (Q-032); в prod допустим только https |

Запуск: `tool/run_dev.ps1` (Windows) или `tool/run_dev.sh`.

# infra/env — переменные окружения и секреты (RM-C-009)

Источник истины — **16_DEPLOYMENT_PLAN §4.3** (канонический словарь переменных, владелец — ядро R0 §18.1).
Этот файл описывает правила работы с конфигурацией. Если он расходится с 16, прав 16. Новых имён здесь нет.

| Что | Где |
|---|---|
| Перечень несекретных переменных (без значений секретов) | `/.env.example` (в git) |
| Сверка `.env.example` с 16 §4.3 и ключей схемы pos-api с 16 §4.3 | `python -I -X utf8 scripts/check_env_example.py` (код 0 — 0 лишних, 0 недостающих) |
| Схема и значения по умолчанию в коде | `pos-api/src/common/config/env.schema.ts` (zod), загрузчик `*_FILE` — `env-file.loader.ts` |
| Секреты | только файлы `secrets/*` на хосте, права `600`, вне git (`.gitignore`: `**/secrets/`, `.env`, `.env.*`) |

## 1. Профили окружения

Значения `APP_ENV` — ровно `dev | staging | prod` (16 §4.3). Отдельных профилей для CI и тестового контура нет:

| Профиль | Где | Особенности |
|---|---|---|
| `dev` | машина разработчика, CI (`APP_ENV=dev` + тестовые флаги) | допустимы `ONEC_MODE=fixtures`, `SMS_PROVIDER=fake`, `AUTH_OTP_TEST_MODE=true`; `PUBLIC_BASE_URL` можно не задавать |
| `staging` | тестовый контур (OPS-027) | как prod, но допустимы тестовые режимы и `SMS_STAGING_ALLOWED_PHONES`; `OPENAPI_PUBLIC=true` |
| `prod` | сервер заказчика | API **не стартует** (код 1, понятное сообщение без значений) при: `ONEC_MODE=fixtures`, `SMS_PROVIDER=fake`, `AUTH_OTP_TEST_MODE=true`, непустых `AUTH_OTP_TEST_PHONES`/`AUTH_OTP_TEST_CODE`, `SMSPRO_TEST_FLAG=true`, `LOG_LEVEL=debug|trace`, `CORS_ALLOWED_ORIGINS=*`, отсутствии `PUBLIC_BASE_URL` |

Межпеременные правила отказа в старте (все профили): `QR_WEBHOOK_ENABLED=true` только при `QR_PROVIDER=bakai` и с `QR_WEBHOOK_ALLOWED_IPS`; `QR_PROVIDER=onec` несовместим с `ONEC_MODE=odata_only` и `ONEC_INBOUND_ENABLED=true`; `ONEC_INBOUND_ENABLED=true` требует `ONEC_MODE=extension` и `ONEC_INBOUND_ALLOWED_IPS`; `SMSPRO_DLR_MODE=push` требует `SMSPRO_DLR_ALLOWED_IPS`.

Flutter (`pos-app`) получает конфигурацию только через `--dart-define-from-file=env/<профиль>.json` (`API_BASE_URL`, `ENV`, `FEATURE_FLAGS`; RM-C-009, 06 §6.9) — секретов в приложении нет.

## 2. Конвенция `*_FILE`

1. Секрет никогда не передаётся значением переменной окружения (оно видно в `docker inspect`). В `environment:` сервиса задаётся **указатель** `<ИМЯ>_FILE=/run/secrets/<файл>`, сам файл подключается через Compose `secrets:` (16 §4.4).
2. Загрузчик pos-api для каждой переменной `X` схемы: если задана непустая `X_FILE` — значение читается из файла (завершающий перевод строки отбрасывается); иначе берётся `X`. **`X_FILE` имеет приоритет над `X`** (тест `pos-api/src/common/config/app-config.spec.ts`).
3. Пустая строка (`X=` в `.env`) означает «не задано»: срабатывает значение по умолчанию или ошибка обязательной переменной.
4. Ошибки конфигурации печатаются в stderr **только именами** переменных и причинами (например, `DATABASE_URL (или DATABASE_URL_FILE): обязательная переменная не задана`, `DATABASE_URL_FILE: не удалось прочитать файл секрета (ENOENT)`); значения и пути к секретам в сообщения и логи не попадают.
5. Для локальной разработки допустимо задать несекретное значение напрямую (`DATABASE_URL=postgres://…` к локальной БД) — в `.env.example` такой строки нет, `.env` в git не попадает.

Секреты 16 §4.3 (указатели — в compose, не в `.env.example`):

| Указатель | Файл `secrets/` | Кто читает |
|---|---|---|
| `DATABASE_URL_FILE` | `database_url` | api, worker |
| `DB_MIGRATOR_PASSWORD_FILE` | `db_migrator_password` | только migrate |
| `POSTGRES_PASSWORD_FILE`, `PGPASSWORD_FILE` | `pg_password` | postgres, backup |
| `JWT_PRIVATE_KEY_FILE` / `JWT_PUBLIC_KEY_FILE` | `jwt_private.pem` / `jwt_public.json` | api |
| `OTP_HMAC_SECRET_FILE` | `otp_pepper` | api, worker (одно значение: текст задания `sms.send` и возврат квоты номера — 16 §4.4, EQ-AUTH-08) |
| `PIN_PEPPER_FILE` | `pin_pepper` | api |
| `SMSPRO_LOGIN_FILE`, `SMSPRO_PASSWORD_FILE` | `smspro_login`, `smspro_password` | api, worker |
| `ONEC_USER_FILE`, `ONEC_PASSWORD_FILE`, `ONEC_HS_USER_FILE`, `ONEC_HS_PASSWORD_FILE`, `ONEC_HS_TOKEN_FILE`, `ONEC_CA_CERT_FILE` | `onec_*` | api, worker |
| `HEALTHCHECKS_PING_URL_FILE` | `healthchecks_url` | api, worker |
| `RCLONE_CONFIG_FILE` | `rclone.conf` | backup |
| R2/условные: `SMSPRO_OTP_API_KEY_FILE`, `ONEC_ODATA_WRITE_*_FILE`, `QR_WEBHOOK_SECRET_FILE`, `QR_WEBHOOK_PUBLIC_KEY_FILE` | — | монтируются только при включённом флаге-родителе |

`BACKUP_AGE_IDENTITY_FILE` на сервере **не хранится** (машина восстановления, офлайн у заказчика; OPS-004).

## 3. Хранение секретов

- Каталог `secrets/` рядом с compose-файлом, владелец — пользователь `optomstroy`, права каталога `700`, файлов — `600`.
- Секреты не попадают в образы, логи, `environment:`, git и приложение Flutter (16 §4.3 «Запрещено»). Проверка git — `python scripts/check_secrets.py` и `gitleaks detect` (CI, RM-C-011).
- Файл создаётся без вывода значения в историю shell: `umask 077; openssl rand -base64 48 > secrets/otp_pepper`.

## 4. Ротация секретов

Общий порядок (16, runbook «Утечка/компрометация секрета»): при подозрении на компрометацию — сначала сдерживание
(`APP_READ_ONLY=true` в `.env` + `docker compose up -d api worker`: мутации → `503 APP_READ_ONLY` кроме перечня ADR-083,
чтение работает; при необходимости — `ONEC_INBOUND_ENABLED=false`, `QR_WEBHOOK_ENABLED=false`, `SMSPRO_DLR_MODE=poll`), затем ротация,
запись в журнал инцидентов, снятие `APP_READ_ONLY` после проверки.

| Секрет | Процедура ротации | Влияние на пользователей |
|---|---|---|
| Ключ подписи JWT (`JWT_PRIVATE_KEY_FILE`, `JWT_PUBLIC_KEY_FILE`, `JWT_KEY_ID`) | сгенерировать новую пару; добавить публичный ключ в набор `jwt_public.json`; новый `JWT_KEY_ID` → `.env`; перезапуск api. Старый `kid` удаляется из набора после истечения выданных им access-токенов (15 мин); при компрометации — сразу (все его токены отклоняются, D-12) | плановая — нет; при компрометации — повторный `/auth/refresh` |
| Pepper OTP (`OTP_HMAC_SECRET_FILE`, `OTP_HMAC_SECRET_VERSION`) | новый файл + увеличить `OTP_HMAC_SECRET_VERSION` (ротация без отказа активных кодов — 16 §4.3; механизм версий — RM-D) | нет |
| Pepper PIN (`PIN_PEPPER_FILE`, `PIN_PEPPER_VERSION`) | новый файл + увеличить `PIN_PEPPER_VERSION` (ротация без сброса всех PIN — 16 §4.3; механизм версий — RM-D) | нет (сброса PIN не требуется) |
| Пароли БД (`database_url`, `db_migrator_password`, `pg_password`) | `ALTER ROLE … PASSWORD …` под суперпользователем; заменить файлы; `docker compose up -d api worker` (и `migrate`/`backup` при следующем запуске) | кратковременный перезапуск |
| SMSPro (`smspro_login`, `smspro_password`) | сменить пароль в кабинете SMSPro; заменить файлы; перезапуск api/worker | отправка OTP недоступна на время перезапуска |
| 1С (`onec_*`) | сменить пароль пользователя ИБ / выпустить новый токен HTTP-сервиса; заменить файлы; перезапуск api/worker | синхронизация приостанавливается на время перезапуска |
| Токены роли `integration` (вариант C-2) | `bin/issue_integration_token` — выпуск нового и отзыв старого (переменных и секрет-файлов нет, R0 §18.2 п. 4) | нет |
| `healthchecks_url`, `rclone.conf` | заменить файл; перезапуск соответствующего сервиса | нет |

Плановая ротация (предложение, срок — решение заказчика): ключ JWT и pepper — раз в 12 месяцев; пароли БД, SMSPro, 1С — при смене персонала с доступом и не реже раза в 12 месяцев.

## 5. Добавление переменной

1. Сначала — строка в 16 §4.3 (процедура 13 §5.3; при влиянии на ТЗ — ADR в 15_DECISION_LOG).
2. Затем — ключ в `pos-api/src/common/config/env.schema.ts` и (для места `.env`, кроме «R2 и условных») строка в `/.env.example`.
3. `python -I -X utf8 scripts/check_env_example.py` — 0 ошибок (проверяет и `.env.example`, и ключи схемы pos-api).

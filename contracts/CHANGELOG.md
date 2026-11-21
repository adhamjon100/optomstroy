# CHANGELOG — общие enum-ы и коды ошибок (`contracts/enums.json`)

Формат — по [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/); версия — поле `version` в `enums.json`
(SemVer: мажор — удаление или переименование значения, минор — новые значения и перечни, патч — уточнение
`source`/`usage` без изменения значений; удалять значения enum БД в R1 запрещено — 07 §6.1). Шаг 16 CI
(`contracts-lint`, 13 §5.3 п. 2) требует запись с новой версией при каждом изменении `enums.json`.
Порядок правки — `NOTES_enums.md` «Как менять»: сначала документ-владелец (07 §6.1/§6.1.1, 08 §2.4), затем
`enums.json`, `python -I -X utf8 scripts/check_enums.py` (0 расхождений) и генерация: `cd pos-api && npm run gen:enums`
(`pos-api/src/common/enums.ts`), `pos-app/lib/core/enums.dart` — тем же `scripts/gen_enums.py` (руками не правятся).

## [1.4.0] — 2026-11-08 — вход по лицу на всех платформах (ADR-116)

Минорное изменение: `version` 1.3.0 → 1.4.0, только новое значение (в конец перечня) и новые перечни. Основание — ответы
владельца 2026-11-07 (выбраны все три варианта вопроса «Где должен работать вход по лицу?») и 2026-11-08 (Q-353 — «Всем
(Рекоменд.)», Q-355 — «Лицо без PIN (Рекоменд.)»); решение — ADR-116 (15, приложение Р). Значения — по 07 v1.18 §5.9,
§5.66, §6.1.1; DDL — миграция `pos-api/migrations/0024_face_login.sql` (вносит пакет сервера; до неё
`scripts/check_enum_triangle.py` [3] ожидаемо показывает расхождение CHECK `sessions.revoke_reason`, перечни
`hello_keys.*` — информационно: таблицы в DDL ещё нет). Число типов БД не изменилось (45); удалённых и переименованных
значений нет; `problemCodes` не менялись (нового кода ошибки нет — причины `UNLOCK_REQUIRED` в OpenAPI).

### Добавлено

- `checkLists`: `session_revoke_reason` + `biometric_weak_disabled` (уровень W Android запрещён `AUTH_BIO_ALLOW_WEAK`, 07 §5.9).
- `checkLists`, новые перечни (имя — по имени поля, `NOTES_enums.md` «Решения при неоднозначностях» п. 2) после
  `store_tablet_status`, в порядке строк 07 §6.1.1: `hello_key_algorithm` (`hello_keys.algorithm`: `RS256`),
  `hello_key_source` (`hello_keys.source`: `windows_hello`, `webauthn_prf`), `hello_key_revoke_reason`
  (`hello_keys.revoke_reason`: `disabled`, `replaced`, `invalidated`, `policy_off`, `shared_device`, `logout_all`,
  `phone_changed`, `kiosk_connect`, `blocked`, `pin_reset`; 07 §5.66). В OpenAPI 1.4.0 первые два выставлены схемами
  `HelloKeyAlgorithm`, `HelloKeySource`; причину отзыва API не отдаёт.
- Доработка 2026-11-18 (пакет сервера W2 LF-2-06, до выпуска 1.4.0 — версия не меняется): `hello_key_revoke_reason`
  + `blocked` (блокировка пользователя администратором) и `pin_reset` (сброс PIN администратором) в конец перечня —
  08 §4.18.3, §4.18.9, 09 BIO-040 `[ВЫВОД исполнителя]`; CHECK `hello_keys_revoke_reason_chk` в той же миграции 0024
  (ещё не выпущена).

### Изменено

- `source` строки `session_revoke_reason` — ссылка на ADR-116 (миграция 0024).
- Сгенерированы заново `pos-api/src/common/enums.ts` и `pos-app/lib/core/enums.dart` (`scripts/gen_enums.py`).

## [1.3.0] — 2026-11-04 — режим «Планшет магазина» (P-002, ADR-115)

Минорное изменение: `version` 1.2.0 → 1.3.0, только новые значения (в конец перечней) и новые перечни. Основание —
P-002 «Планшет магазина» редакции 5, утверждено владельцем 2026-11-04 («P-002 утверждаю, делай»); решение — ADR-115
(15). Значения — по 07 v1.17 §6.1, §6.1.1 и 08 v1.20 §2.4; DDL — миграции `pos-api/migrations/0021_kiosk_enum_values.sql`
(`ALTER TYPE … ADD VALUE`) и `0022_kiosk_schema.sql` (CHECK). Число типов БД не изменилось (45); удалённых и
переименованных значений нет.

### Добавлено

- `dbEnums`: `user_kind` + `kiosk`, `role_code` + `kiosk` (технический пользователь и роль планшета магазина),
  `otp_purpose` + `kiosk_order` (код заявки с планшета; телом `POST /auth/otp/request` не принимается — только
  `POST /kiosk/order-otp`), `notification_kind` + `kiosk_order` (07 §6.1; отступление от перечней ядра §6 — 07 §19 п. 31).
- `checkLists`: `session_revoke_reason` + `kiosk_revoked`; `rate_limit_scope` + `otp_kiosk_tablet_1h`,
  `otp_kiosk_tablet_24h`; `order_created_via` + `kiosk`; `sms_template_key` + `otp_kiosk_order` (CHECK
  `dev_outbox.template_key` не меняется — 07 §5.63).
- `checkLists`, новые перечни (имя — по имени поля, как `NOTES_enums.md` «Решения при неоднозначностях» п. 2):
  `store_tablet_status` (`store_tablets.status`: `active`, `revoked`; 07 §5.65) — после
  `integration_token_revoke_reason`; `kiosk_customer_match` (`orders.kiosk_customer_match`: `single`, `ambiguous`,
  `none`; 07 §5.37) — после `order_created_via`. Порядок перечней — как строки 07 §6.1.1.
- `problemCodes` (после `APP_READ_ONLY`, порядок 08 §2.4; всего 56): `KIOSK_REVOKED` 401, `KIOSK_DISABLED` 403,
  `KIOSK_NETWORK_DENIED` 403, `KIOSK_RATE_LIMITED` 429, `KIOSK_EXIT_CODE_INVALID` 422, `KIOSK_EXIT_LOCKED` 423;
  `tag` — «НОВОЕ ИМЯ — ADR-115» (пометка строки 08).

### Изменено

- `source` строк `user_kind`, `role_code`, `notification_kind`, `otp_purpose`, `session_revoke_reason`,
  `rate_limit_scope`, `order_created_via`, `sms_template_key` — ссылка на ADR-115; `usage` у `otp_purpose` —
  оговорка о `POST /kiosk/order-otp`.

### Производные артефакты

- `pos-api/src/common/enums.ts` перегенерирован (`npm run gen:enums`); заголовки problem+json шести кодов —
  `pos-api/src/common/problem-details/problem-titles.ru.ts`.
- `pos-app/lib/core/enums.dart` и исчерпывающие `switch` приложения — пакет WP-A01 (до него
  `pos-app/test/core/enums_contract_test.dart` ожидаемо красный).
- Сторона OpenAPI (`UserKind`, `RoleCode`, `OtpPurpose`, `NotificationKind`, `OrderCreatedVia`, `ProblemCode`) — пакет
  WP-F2 (`contracts/openapi/CHANGELOG.md` 1.3.0); до него пункты [2] и [4] `scripts/check_enum_triangle.py` красные.

## [1.2.0] — 2026-10-23 — код журнала синхронизации `QR_PAID_AFTER_VOID` (ADR-103)

Запись восстановлена при создании файла (2026-11-04) по `docs/specification/08_API_SPECIFICATION.md` §2.4 и
`contracts/openapi/CHANGELOG.md` [1.2.0]. `sync_error_code` + `QR_PAID_AFTER_VOID` (15 значений; 05 §6.7.3, SYNC-078,
FIX-F-06) — одним изменением с OpenAPI 1.2.0 и expand CHECK `pos-api/migrations/0013`.

## [1.1.0] — 2026-10-22 — уточнения этапа E (EQ-AUTH-01, EQ-AUTH-03)

Запись восстановлена при создании файла (2026-11-04) по `docs/stages/E_spec_sync.md` §1. `rate_limit_scope` +7 значений
(`otp_ip_10m`, `otp_ip_24h`, `otp_device_10m`, `otp_global_1m`, `otp_verify_ip_10m`, `pin_user_device_10m`,
`admin_user_1m`), `session_revoke_reason` + `refresh_replay` — как CHECK миграции 0003 (ADR-088).

## [1.0.0] — этап B (RM-B-009)

Первая версия контракта: типы БД (07 §6.1), CHECK-перечни (07 §6.1.1), API-перечни (08 §2.4, §3.8) и коды
`Problem.code` (08 §2.4). Решения при неоднозначностях — `NOTES_enums.md`.

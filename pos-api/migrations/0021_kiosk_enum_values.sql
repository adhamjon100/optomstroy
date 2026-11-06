-- 0021_kiosk_enum_values.sql — новые значения enum-типов режима «Планшет магазина» (P-002 ред. 5, ADR-115;
-- задача TAB-1-01, часть «БД»).
--
-- Основание: 07 §6.1 (значения `kiosk` в `user_kind` и `role_code`, `kiosk_order` в `otp_purpose` и
-- `notification_kind`; по-прежнему 45 типов), §14.2 (блок 0021), §12.2 и DATA-305 (правило разделения миграций).
--
-- Почему отдельный файл. Мигратор применяет каждый файл в своей транзакции (src/db/migrator.ts:190-194), а PostgreSQL
-- не позволяет использовать значение, добавленное `ALTER TYPE … ADD VALUE`, до фиксации добавившей его транзакции.
-- Поэтому здесь ТОЛЬКО операторы `ALTER TYPE … ADD VALUE IF NOT EXISTS` (DATA-305; проверка —
-- test/db/kiosk-schema.db-spec.ts), без обёртки `BEGIN … COMMIT`: транзакцией управляет мигратор, psql и
-- tools/pg/run-sql.mjs выполняют операторы по одному. Каждое использование новых значений (CHECK, частичные индексы,
-- `'kiosk'::role_code` в seed RBAC) — в следующих файлах: 0022_kiosk_schema.sql, 0023 (seed роли `kiosk`).
-- Это первый `ALTER TYPE` в проекте (типы созданы в 0001_init.sql, раздел 3).
--
-- Порядок значений — как в 07 §6.1: новые значения добавляются в конец перечня.
-- Expand-only (forward-only, 07 §13): старый код новых значений не встречает и продолжает работать.
-- Идемпотентно: IF NOT EXISTS — повторное применение даёт 0 изменений (двойной прогон CI, run-sql.mjs --repeat-strict).

ALTER TYPE user_kind ADD VALUE IF NOT EXISTS 'kiosk';
ALTER TYPE role_code ADD VALUE IF NOT EXISTS 'kiosk';
ALTER TYPE otp_purpose ADD VALUE IF NOT EXISTS 'kiosk_order';
ALTER TYPE notification_kind ADD VALUE IF NOT EXISTS 'kiosk_order';

# Общие enum-ы и коды ошибок (RM-B-009): заметки и решения

Задача: RM-B-009 (13_IMPLEMENTATION_ROADMAP §3.2). Ядро R0 v1.9 имеет приоритет. Владельцы словарей (ядро §18.1):

| Словарь | Владелец | Раздел `enums.json` |
|---|---|---|
| типы PostgreSQL `CREATE TYPE … AS ENUM` | 07 §6.1 | `dbEnums` (45) |
| CHECK-перечни текстовых полей | 07 §6.1.1 | `checkLists` (29) и `checkListExclusions` (4) |
| коды ошибок `Problem.code` с HTTP-статусом | 08 §2.4, таблица | `problemCodes` (50) |
| коды журнала синхронизации | 08 §2.4, абзац «Коды журнала синхронизации»; 07 §6.1.1 повторяет их в CHECK | `checkLists[sync_error_code]` (14) |
| коды предупреждений `warnings[].code` | 08 §2.4, абзац «Предупреждения (не ошибки)» | `apiEnums[warning_code]` (3) |
| `creditReason` | 08 §3.8 и §5.5; ядро §22.4 в редакции §23 п.5 (владелец правила — 10 PAY-031) | `apiEnums[credit_reason]` (5) |
| `ORDER_STATE_INVALID.resource` | 08 §2.4 и скелет 08 §8 | `apiEnums[problem_resource]` (4) |

## Файлы

| Файл | Назначение |
|---|---|
| `contracts/enums.json` | контракт: значения перечней и кодов |
| `contracts/enums.schema.json` | JSON Schema 2020-12 для `enums.json` |
| `scripts/gen_enums.py` | генератор `enums.ts` и `enums.dart` в каталог из аргумента |
| `scripts/check_enums.py` | сверка `enums.json` с markdown 07 §6.1, §6.1.1, 08 §2.4, §3.8, §8 и ядром §23 п.5, проверка схемы и детерминизма генератора |

Команды запуска (из корня репозитория):

```
python -I -X utf8 scripts/check_enums.py -v          # 0 — расхождений нет, 1 — есть, 2 — ошибка запуска
python -I -X utf8 scripts/gen_enums.py <out_dir>     # пишет <out_dir>/enums.ts и <out_dir>/enums.dart
python -I -X utf8 scripts/check_enums.py --enums <другой.json> --no-gen   # отрицательные тесты
```

Сгенерированные файлы в репозиторий на этапе B не записываются. Целевые места: `pos-api/src/common/enums.ts` (RM-C-005) и `pos-app/lib/core/enums.dart` (RM-C-004). Импорт значений unit-тестами обеих сторон проверяется в этих же задачах.

## Как работает сверка

- **07 §6.1.** Сверяются имена типов и их порядок, значения и их порядок (порядок значений типа PostgreSQL важен). Число строк таблицы должно совпадать с фразой «Итого **N типов**».
- **07 §6.1.1.** Каждая строка таблицы должна быть либо в `checkLists` (сверяются поля и значения по порядку), либо в `checkListExclusions`. Перечень значений — это начальный список вида `` `a`, `b` (пояснение), `c` `` в ячейке. Пояснения в скобках и хвост после `;` в перечень не входят. Например, у `payments.qr_provider` хвост «те же значения у env `QR_PROVIDER`» не входит.
- **notUsed.** Значения, которые владелец прямо назвал неиспользуемыми, хранятся в `notUsed`. Это фразы «значение `X` не используется» в 07 и «Значения прежней редакции … не используются» в 08 §3.8. Сверка требует, чтобы `notUsed` совпадал с документом и не пересекался с `values`. Генератор такие значения не выпускает.
- **08 §2.4.** Сверяются код, его порядок и HTTP-статусы: из ячейки «HTTP» берутся все трёхзначные числа. Дополнительно состав кодов сверяется с enum `Problem.code` скелета 08 §8; порядок там другой.
- **Детерминизм.** Генератор запускается два раза в разные временные каталоги, после чего выполняется побайтное сравнение `enums.ts` и `enums.dart`.

## Решения при неоднозначностях

1. **Число типов БД — 45, а не 44.** Таблица 07 §6.1 содержит 45 строк и прямо говорит «Итого **45 типов**» (17 типов ядра §6, 27 канонизированных §17.3, 1 по §20.2 п.10). Дорожная карта говорит о «26 новых enum»: это счёт ядра, а расхождение описано в 07 §19 п.4. Решение принято по владельцу (07).
2. **CHECK-перечни включены в контракт** (`checkLists`). Задача прямо называет `review_reason` с `late_payment`, `revoke_reason` и `qr_provider`. Все они в 07 §6.1.1, а не в §6.1. Имена перечней в 07 не заданы, поэтому выбраны по имени поля, а где имя уже есть в `contracts/openapi/parts/00_root.yaml` — по нему. Соответствие полей и имён:

   | Поле (07 §6.1.1) | Имя перечня | Поле (07 §6.1.1) | Имя перечня |
   |---|---|---|---|
   | `user_profiles.locale` | `locale` | `orders.created_via` | `order_created_via` |
   | `user_invitations.role` | `invitation_role` | `payments.qr_provider` | `qr_provider_mode` |
   | `sessions.revoke_reason` | `session_revoke_reason` | `return_requests.onec_result` | `return_onec_result` |
   | `token_denylist.token_kind` | `token_kind` | `return_requests.approval_reason` | `return_approval_reason` |
   | `token_denylist.reason` | `token_deny_reason` | `notifications.severity` | `notification_severity` |
   | `rate_limit_counters.scope` | `rate_limit_scope` | `sync_errors.error_code` (+2 поля) | `sync_error_code` |
   | `integration_tokens.scope` | `integration_token_scope` | `sync_errors.severity` | `sync_error_severity` |
   | `integration_tokens.source` | `integration_token_source` | `onec_outbox.operation` | `outbox_operation` |
   | `integration_tokens.revoke_reason` | `integration_token_revoke_reason` | `audit_logs.result` | `audit_result` |
   | `receivable_documents.kind` | `receivable_document_kind` | `audit_logs.severity` | `audit_severity` |
   | `receivable_documents.status` | `receivable_document_status` | `app_settings.value_type` | `setting_value_type` |
   | `payments.review_reason` | `review_reason` | `app_settings.customer_stock_display` | `customer_stock_display` |
   | `orders.cancel_reason_code` | `cancel_reason_code` | `print_jobs.paper` | `print_paper` |
   | `orders.refund_intent` | `refund_intent` | `sms_outbox.template_key` | `sms_template_key` |
   |  |  | `sms_outbox.provider` | `sms_provider` |

3. **`payments.qr_provider` → `qr_provider_mode`.** В OpenAPI имя `QrProvider` уже занято DTO `QrInfo.provider`. Его значения — `onec | bakai | elqr_static | none` (08 §3.10), и 08 прямо говорит, что это не значение переменной. Значения поля БД и env `QR_PROVIDER` (`none | onec | bakai`, ядро §24.4) в OpenAPI названы `QrProviderMode`. Чтобы в TS не появилось двух разных типов `QrProvider`, перечень назван `qr_provider_mode`. Порядок значений взят по 07 §6.1.1: `none, onec, bakai`.
4. **Исключены из `checkLists` 4 строки 07 §6.1.1 без перечня значений:** `devices.device_key` (регэксп), `integration_tokens.expires_at` (срок), `orders.onec_sync_state` × `onec_ref`/`status` (CHECK согласованности; значения enum — `dbEnums.onec_sync_state`), `sms_outbox.provider_message_id`/`dev_outbox.transaction_id` (регэксп). Каждое исключение записано с причиной в `checkListExclusions`, и сверка требует, чтобы строка документа была либо покрыта, либо исключена явно.
5. **Порядок кодов журнала синхронизации — по 08.** Владелец словаря — абзац 08 §2.4 («Владелец словаря — настоящий абзац», ядро §18.1). Поэтому порядок взят оттуда: сначала 6 кодов ядра и 05, затем 8 значений 07. В 07 §6.1.1 те же 14 значений идут в другом порядке, и там сверяется только состав. Порядок совпадает с `SyncErrorCode` в OpenAPI. Дорожная карта называет поле `onec_outbox.last_error`, а по 07 это `onec_outbox.last_error_code`; принято имя 07.
6. **`app_settings.customer_stock_display`** — это значение ключа настройки (jsonb-строка), а не столбец. В `columns` записан путь из 07 `app_settings.customer_stock_display`, как он указан в первой ячейке строки.
7. **Неиспользуемые значения (`notUsed`):** `otp_purpose` — `login` (ядро §18.2 п.7); `return_reason` — `excess`; `outbox_operation` — `update_status`; `credit_reason` — `not_identified`, `onec_inbound_mode`, `not_allowed`, `no_data`, `receivables_stale`, `onec_unavailable` (08 §3.8).
8. **HTTP-статусы.** `http` — это массив, потому что у `VALIDATION_FAILED` два статуса: 400 (синтаксис или схема) и 422 (семантика). Пометка строки 08 (`[РЕШЕНИЕ: …]`, `[НОВОЕ ИМЯ]`) сохраняется в `tag`, только если она есть в документе. Источник кодов без пометки не домысливается.
9. **`QR_UNAVAILABLE`** одновременно и `Problem.code`, и код предупреждения (08 §2.4). Сверка допускает это единственное пересечение `warning_code` ∩ `problem_code`.
10. **Вне RM-B-009** (другие владельцы или DTO 08 §3, а не §2.4/§6): `PermissionCode` (11 §4.3), `StepUpOperation` (08 §2.12), действия аудита (11 §7.2), `TransactionStatusGroup`, `StockLevel`, `CartConflictKind`, `CartItemWarning`, `QrInfo.provider`, `orders.status` × `onec_sync_state`, переменные окружения (16 §4.3), методы 1С (05 §6). Эти перечни остаются в OpenAPI (RM-B-003) и у своих владельцев.
11. **Сверка с OpenAPI.** Сравнение с `contracts/openapi/parts/00_root.yaml` (RM-B-003) выполнено вручную один раз, в `check_enums.py` оно не входит, потому что этот файл ещё в работе у другой задачи. Все перечни, которые есть в обоих файлах, совпадают по значениям и порядку. Таких перечней 54, в том числе `ProblemCode` (50 кодов), `SyncErrorCode`, `WarningCode`, `CreditReason`, `ProblemResource`, `QrProviderMode`. Расхождений нет. Имя `QrProvider` в `enums.json` не используется (см. п. 3).

## Генерация

- **TypeScript.** Для каждого перечня генерируются `<NAME>_VALUES` (`as const`), тип-объединение `PascalName` и защитник `isPascalName(value)`. Кроме того: `PROBLEM_CODE_HTTP_STATUS` (тип `{[K in ProblemCode]: readonly number[]}`), реестры `DB_ENUMS` (имя типа → значения; для теста `pg_enum`, DATA-200) и `CHECK_LISTS` (поле → значения).
- **Dart.** Для каждого перечня генерируется enhanced enum с полем `value` (строка ровно как в документе) и `static tryParse(String?)`: неизвестное значение даёт `null`, это совместимость вперёд. У `ProblemCode` есть ещё поле `httpStatuses`. Реестры: `dbEnumValues`, `checkListValues`.
- **Имена членов Dart** — lowerCamelCase из значения: `pending_activation` → `pendingActivation`, `EAN13` → `ean13`, `n_a` → `nA`, `VALIDATION_FAILED` → `validationFailed`. Если имя совпадает с ключевым словом Dart или с членом enum (`values`, `index`, `name`, `value`, …), добавляется суффикс `Value`. Сейчас это один случай: `receivable_document_kind.return` → `returnValue`. Совпадение идентификаторов внутри одного перечня — ошибка генератора (код 1).
- **Детерминизм.** Порядок вывода — как в `enums.json`. Нет отметок времени, перевод строки LF, UTF-8 без BOM. В заголовке — sha256 канонической формы JSON (`sort_keys`, без пробелов), поэтому окончания строк в файле-источнике на результат не влияют.
- **Проверка компилируемости** (вручную, во временном каталоге): `dart analyze` — «No issues found!»; `npx -p typescript@5.6.3 tsc --noEmit --strict` — код 0.

## Как менять

Сначала меняется документ-владелец (07 §6.1/§6.1.1 или 08 §2.4), затем `enums.json`. После этого нужно запустить `check_enums.py`, он должен показать 0 расхождений, и увеличить `version`: новое значение — minor, удаление или переименование — major. Удалять значения из enum БД в R1 запрещено (07 §6.1).

Производные артефакты сверяются между собой скриптом `scripts/check_enum_triangle.py` (B-AR-10 (г), 2026-10-21):
45 типов `dbEnums` = `CREATE TYPE` в `pos-api/migrations/0001_init.sql` = enum-схемы OpenAPI (7 внутренних типов — без
схемы API, список с причинами в скрипте); `checkLists` = `CHECK (… IN (…))` DDL; `problemCodes` = `ProblemCode`.

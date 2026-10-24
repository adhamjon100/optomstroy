# Отчёт по этапу D — Authentication (регистрация, OTP, SMSPro, привязка клиента, биометрия/PIN) «Оптомстрой POS»

**Этап:** D — Authentication · **Задача фиксации этапа:** RM-D-012 · **Ворота:** G-D
**Дата отчёта:** 2026-10-22 · **Автор (владелец отчёта):** QA + ARCH (13 §2.2; отчёт собран агентом-исполнителем RM-D-012) · **Независимый проверяющий:** агент QA + SEC, `docs/reviews/D_review.md` (проверка выполнена до исправлений; статусы замечаний после исправлений записаны в §6 обзора агентом исправлений, повторной независимой проверки не было — см. D-KI-08)
**Основание:** 13_IMPLEMENTATION_ROADMAP §3.4 (RM-D-001…RM-D-017), §6.1–§6.3; ядро R0 v1.9 (приоритет §24 … §16; D-07 в редакции §24.2, D-10, D-12, D-13, D-47, D-48)

**Итог.**
- Свежий прогон 2026-10-22 07:01–07:17 (UTC+4, Windows 11 Pro, Node 24.11.1, Flutter 3.38.7) дал код 0 у всех запущенных команд (§2):
  - pos-api: lint, build, `npm test` — 127; ещё 11 наборов vitest на embedded PostgreSQL 17 — 367 тестов; e2e — 77 (+4 пропущены: только через pos-proxy);
  - покрытие `test:cov:d` по `src/auth/**` и `src/registration/**`: строки 97,92 %, ветви 88,51 % (порог 80 % строк);
  - local-stack `smoke` — 10/10, `auth-smoke` (настоящие процессы API и PostgreSQL) — 15/15;
  - pos-app: `flutter analyze` — 0 замечаний, `flutter test` — 700, golden — 90, `check_layers` — 0 нарушений;
  - `integration_test` на Windows против локального стека: `auth_flow_test` 3/3, `boot_test` 1/1.
- Что не сделано:
  - ничего не проверено на Android и iOS: эмулятор не стартует из-за нехватки места на C:, устройства и macOS нет. Kotlin-код канала биометрии ни разу успешно не компилировался;
  - реальная доставка SMS не проверялась: нет аккаунта SMSPro (Q-029, RM-A-004);
  - нет видео и скриншотов пути входа;
  - в Flutter нет SCR-42 («Устройства/сессии», «Защита входа») и `public_settings_provider.dart` (RM-D-015);
  - нет инструкции `docs/integration/smspro_connect.md`;
  - RM-D-013 не выполнялась: вариант C-2 не выбран.
- **Статус ворот G-D — красный** (§4). Задачи RM-D-002, RM-D-008, RM-D-009, RM-D-010, RM-D-015 закрыты не полностью. Проверку на устройстве (RM-D-008 п. 1, 4; RM-D-012) блокирует окружение. Дефектов безопасности уровня «блокер/критично» не найдено (D_review §5, §6).
- Статусы остатков после этапа E и пересмотр G-D — в разделе «Дополнение 2026-10-22: остатки D, закрытые на этапе E» в конце файла (G-D по-прежнему красный).

---

## 1. Готовые файлы

Все пути этапа в git не отслеживаются (`??`), коммитов нет. Этап D не менял `contracts/openapi/pos-api.v1.yaml` (1.0.0), `contracts/enums.json` и ARB `contracts/l10n/*`: время изменения у всех — 2026-10-21, этап B. Расхождения с ними записаны как вопросы (§5.3). Изменён `contracts/legal/consents_ru.md` (2026-10-22 01:59, RM-D-004) — у него нет номера версии контракта. Новых миграций нет: `pos-api/migrations/` — по-прежнему `0001_init.sql`, `0002_rbac_seed.sql`. Поэтому часть решений временно живёт в коде (§5.3, DQ-01…DQ-03).

### 1.1. Статус задач этапа

- «Закрыта (локально)» — все пункты критерия выполнены запуском на машине разработки (CI нет — Q-131).
- «Частично» — часть пунктов не выполнена, причина указана.
- Номера строк §2 — в скобках.

| Задача | Статус | Что подтверждено запуском | Что не выполнено (причина) |
|---|---|---|---|
| RM-D-001 Backend OTP | закрыта (локально) | п. 1: `otp.service.ts`, `otp.provider.ts`, `step-up.service.ts` — 100 % строк и ветвей (`coverage-summary.json`, стр. 16); п. 2–6: `test/e2e/auth/otp.e2e-spec.ts` в составе e2e 77 (стр. 15) | Отступление от 07: лимиты IP 10 мин / 24 ч, устройства 10 мин и `OTP_GLOBAL_PER_MIN` считаются по `otp_challenges`, а не в `rate_limit_counters` — в CHECK нет областей (DQ-01) |
| RM-D-002 SMS-адаптер | частично | п. 1: фикстуры XML кодов 0–11 — `smspro-xml.spec.ts`, `smspro-gateway.spec.ts`; п. 3: баланс ниже порога → алерт и in-app уведомление (`sms-outbox.spec.ts`, T-SMS-010); п. 4–5: poll → 404, push с allow-list, идемпотентный повтор DLR (`sms-dlr-push.spec.ts`); всего `test:sms` 65 (стр. 13) | п. 2: контрактный тест `test=1` на тестовом аккаунте — **не выполнен, только фикстуры и локальный mock** (нет аккаунта SMSPro, Q-029/RM-A-004). Выход `docs/integration/smspro_connect.md` **не создан** (D_spec_questions SMS-Q-13; файла нет) |
| RM-D-003 Backend сессии | закрыта (локально) | п. 1–6: `sessions.e2e-spec.ts`, `tokens-audit.e2e-spec.ts` (e2e, стр. 15); JWT `alg=none`, неизвестный `kid`, ротация — `test:foundation` 55 (стр. 6); `alg=none` → 401 на реальном процессе (стр. 18) | Отзыв step-up `jti` после logout/смены ролей реализован через привязку к `sid`, `deviceId`, `pv`, а не через реестр `jti` — его нет в 07 (DQ-03) |
| RM-D-004 Backend регистрация | закрыта (локально) | п. 1–9: `test:registration` 19, `test:profile` 25 (стр. 11–12); путь клиента и приглашённого на реальном процессе (стр. 18) | — (расхождения 08/09 по DTO и кодам — DQ-11, DQ-12) |
| RM-D-005 Привязка к клиенту 1С | закрыта (локально) с оговоркой | п. 1–2, 4: `customer-links.e2e.spec.ts` на `FakeOnecGateway` (`test:customers` 28, стр. 10); `customerMatch=proposed` на реальном процессе (стр. 18) | п. 3 проверен только на DTO `customer-match`/`/me`. Маршрутов с долгом и историей клиента ещё нет — перепроверка на E/F (D_review D-MN-07) |
| RM-D-006 RBAC в действии | закрыта (локально) | п. 1: `rbac-matrix.e2e-spec.ts` — политика у каждого маршрута, `x-roles` ⇔ `permissions.yaml`, 36 операций × 6 ролей, owner/admin без кассовых операций (e2e, стр. 15); п. 2–4: `test:admin` 36 (стр. 9); `check:permissions` — актуально, 77 кодов, 7 ролей (стр. 14) | Лимит RL-ADMIN не реализован (DQ-01) |
| RM-D-007 Flutter: вход | закрыта (локально) с отступлениями | п. 1: widget-тесты маски +996, ошибок OTP — в составе `flutter test` 700 (стр. 20); п. 2: golden SCR-00/01/02/08 на compact/medium/expanded — 16 эталонов Windows, `--tags golden` 90 (стр. 21); п. 3: reduce-motion — `auth_golden_test.dart`, `mascot_controller_test.dart` | `assets/rive/mascot.riv` нет: работает плоская заглушка `PlaceholderMascotRenderer` (допускается риском этапа, Q-035). Не реализованы: сигнал переполнения `PhoneField` (AU-04), подсказка `devCode` (AU-03), SMS User Consent/`FLAG_SECURE` (AU-16). Golden-эталоны сняты только на Windows |
| RM-D-008 Flutter: регистрация и биометрия | частично | п. 2, 3: widget-тесты `registration_security_screen_test.dart` и `step_up_dialog_test.dart` (стр. 20); статическая проверка Android-конфигурации `test/build/android_build_config_test.dart` (в составе 700) | п. 1 — integration на Android, п. 4 — смена биометрии: **не выполнены**. Эмулятор не стартует: «not enough disk space», на C: свободно ~0,8 ГБ (стр. 25). `BiometricCryptoChannel.kt` и `AppDelegate.swift` ни разу не собирались. В `pos-app/android/.kotlin/errors/` есть журналы неудачной попытки компиляции Kotlin в 02:48 («Daemon compilation failed»). п. 5 (лицо не сохраняется): D_review §2 проверил код канала на соответствие D-13; отдельной отметки ревьюера SEC по п. 5 нет. ADR-087 — «Предложено» |
| RM-D-009 Flutter: сессия и защита | частично | п. 1: «5 параллельных 401 → один `/auth/refresh`» — `session_flow_test.dart`; п. 2: idle 30 мин и фон 5 мин — `idle_lock_test.dart` (fake async и `FixedClock`); п. 4: access только в памяти, `allowBackup=false`, `PIN_INVALID` без refresh — `session_flow_test.dart`, `android_build_config_test.dart` (все — в составе 700, стр. 20) | п. 3 проверен на фейковом HTTP-слое: отзыв приводит к выходу на SCR-90 C. Сквозного e2e против pos-api нет. **SCR-42, разделы «Устройства/сессии» и «Защита входа», не реализованы**: в `lib/features/settings/` только `.gitkeep` и README |
| RM-D-010 Flutter: админ пользователей (SCR-45) | частично | п. 1: step-up у действий — `admin_users_screen_test.dart`, `admin_users_dialogs_test.dart` (в составе 700); путь «admin создаёт приглашение (API) → OTP → cashier, `nextStep=set_pin`» — на реальном процессе (стр. 18) | п. 2: golden-эталонов SCR-45 нет, есть только widget-тесты compact/expanded. п. 3: `integration_test` «создать приглашение **в UI** → войти» нет: `auth_flow_test` берёт приглашение из фикстур стека |
| RM-D-011 Тесты и безопасность | частично | п. 2: покрытие ≥ 80 % (стр. 16); `trace_test_ids.py`: ID в охвате 178, с тестом 153, not_done с причиной 25, без теста и причины 0 (стр. 19); security-тесты (rate-limit, reuse, `alg=none`, брутфорс PIN) — в наборах стр. 6–15 | п. 1: запущены не все T-AUTH/REG/SESS/SMS — 25 ID в статусе not_done (§2.2). п. 3: доставка на реальный номер **не проверена — нет аккаунта SMSPro** (критерий допускает такую пометку). Матрица сопоставляет ID и файлы тестов; содержание каждого теста с текстом 12 построчно не сверялось |
| RM-D-012 Интеграционная сборка и отчёт | частично | Windows: `auth_flow_test` 3/3 — клиент Splash → … → каталог-заглушка SCR-50, приглашённый сотрудник OTP → PIN → SCR-10, клиент с карточкой 1С → SCR-06 (стр. 22); `boot_test` 1/1 (стр. 23); `docs/reviews/D_review.md`; этот отчёт | Android: путь не пройден (стр. 25). Видео и скриншотов нет. Прогон шёл против локального стека (`local-stack.mjs serve --auth-fixtures`), а не против тестового контура compose + Caddy: Docker нет (наследие G-C) |
| RM-D-013 Токены `integration` | не выполнялась (условная) | — | Вариант связи C-2 не выбран: действует допущение Q-031 «LAN», ADR-082. Скрипта `bin/issue_integration_token` и модуля нет. Задача не входит в условия G-D |
| RM-D-014 Дополнения ядра v1.4 | закрыта (локально), по данным матрицы и ревью | п. 1, 2, 6, 7 (backend): `otp.e2e-spec.ts`, `registration.registration-spec.ts`, `customer-links.e2e.spec.ts`, `admin-users.admin-spec.ts`; п. 3–5, 7 (Flutter) — widget- и unit-тесты в составе 700 | Пункты мной построчно не перепроверялись, опора — D_review §2, §6 и `trace_test_ids.py`. Офлайн-сигнал экранов входа в композиционном корне не подключён (порт `authOfflineSignalProvider` по умолчанию `false`, AU-14): офлайн определяется по исходу запроса |
| RM-D-015 `GET /settings/public` | частично | п. 1: роли → 200, без Bearer → 401, схема контракта, ETag; п. 2 (часть): `features.customerSelfService` = env, ключа `customer_self_service` в `app_settings` нет; п. 3: сверка с таблицей 08 — 0 расхождений (`test:settings` 17, стр. 12) | п. 2: запись через `/admin/settings` → `VALIDATION_FAILED` не проверена: маршрута ещё нет (LNK-14). **Flutter-часть не выполнена**: `pos-app/lib/core/config/public_settings_provider.dart` нет; видимость по `features` в SCR-45 берётся из флага сборки (FA-08). п. 4 (widget SCR-39/SCR-46) — экранов ещё нет |
| RM-D-016 Аварийный код входа | закрыта (локально) с отступлением | п. 1–5: `emergency-login.e2e-spec.ts` (6 сценариев, e2e стр. 15), `emergency-code.admin-spec.ts` (`test:admin`, стр. 9); widget SCR-45 — в составе 700 | `sessions.amr` не хранит `admin_code`: CHECK `sessions_amr_chk` не расширен. Признак аварийной сессии — `created_from_challenge_id` и аудит (FX-01, DQ-02) |
| RM-D-017 Клиент и приглашённый сотрудник | закрыта (локально) | п. 1–3: e2e и `test:registration` (стр. 11, 15), реальный процесс — `registration_required` → `customer active`, приглашённый → `staff/seller`, `pin_not_set`, первый `POST /me/pin` без step-up (стр. 18); п. 4: widget-тесты SCR-04 без «Пропустить»; сквозной путь на Windows (стр. 22) | — |

### 1.2. Пути

| Путь | Новый / изменён | Задача `RM-*` | Владелец | Версия контракта (было → стало) | Примечание |
|---|---|---|---|---|---|
| `pos-api/src/auth/**` (`otp`, `sessions`, `step-up`, `login`, `pin`, `common`) | новые | RM-D-001, 003, 014, 016, 017 | SEC + BE | — | `AuthModule` подключён в `DOMAIN_MODULES` |
| `pos-api/src/common/auth/**`, `common/crypto/**`, `common/audit/**`, `common/rate-limit/**`, `common/rbac/**` (изм.), `src/users/**` | новые / изменён | RM-D-003, 004, 006 | SEC | — | фундамент: AuthGuard, Argon2id/HMAC, аудит с хэш-цепочкой |
| `pos-api/src/registration/**`, `pos-api/src/profile/**`, `contracts/legal/consents_ru.md` | новые | RM-D-004, 014, 017 | SEC + BE | — | тексты согласий — черновики (Q-027) |
| `pos-api/src/customers/links/**`, `customers/matching/**` | новые | RM-D-005, 014 | BE + ONEC | — | `/registration/customer-match` реализован здесь (LNK-10) |
| `pos-api/src/admin/users/**` (в т. ч. `emergency-code/**`, `shared/**`), `pos-api/src/admin/invitations/**` | новые | RM-D-006, 016, 017 | SEC + BE | — | |
| `pos-api/src/settings/**` | новые | RM-D-015 | BE | — | 13 называет путь `src/admin/settings/**` (LNK-11) |
| `pos-api/src/integrations/sms/**`, `pos-api/src/notifications/sms/**` | новые / изменены | RM-D-002 | SEC | — | |
| `pos-api/src/app.module.ts`, `src/common/config/**`, `src/jobs/**` | изменены | RM-D-011, 012 | BE (интегратор) | — | |
| `pos-api/test/{auth,admin,customers,profile,registration,settings,sms}/**`, `test/e2e/auth/**`, `test/e2e/rbac-matrix.e2e-spec.ts`, `test/foundation/**`, `vitest.config.cov-d.ts` | новые | RM-D-011 | QA + SEC | — | `test:cov:d` — INT-06 |
| `pos-api/scripts/local-stack.mjs` | изменён | RM-D-011, 012 | QA | — | `auth-smoke`, `serve --auth-fixtures` |
| `pos-app/lib/features/auth/**`, `features/splash/**`, `assets/brand/**` | новые | RM-D-007, 014 | FE + DS | — | Mascot — заглушка |
| `pos-app/lib/features/registration/**`, `lib/core/biometrics/**`, `android/app/src/main/kotlin/com/example/optomstroy/{MainActivity,BiometricCryptoChannel}.kt`, `android/app/src/main/res/xml/data_extraction_rules.xml`, `ios/Runner/AppDelegate.swift` | новые / изменены | RM-D-008 | FE + SEC | — | нативный код не собирался |
| `pos-app/lib/core/session/**`, `lib/core/network/interceptors/**`, `lib/features/session_ui/**` | новые / изменены | RM-D-009 | FE + SEC | — | SCR-42 нет |
| `pos-app/lib/features/admin/{domain,data,presentation}/users/**`, `features/admin/admin_providers.dart` | новые | RM-D-010, 016 | FE | — | путь изменён под слои (FA-01) |
| `pos-app/lib/app/router/**`, `lib/app/di/**`, `lib/core/l10n/**`, `lib/core/network/models/public_settings*.dart` | изменены / новые | RM-D-012, 015 | FE | — | |
| `pos-app/integration_test/auth_flow_test.dart`, `pos-app/test/**` (features auth, registration, admin, session_ui; core/session; build) | новые | RM-D-011, 012 | QA | — | |
| `scripts/trace_test_ids.py` | новый | RM-D-011 (D-MJ-02) | QA | — | матрица «ID 12 → тест / not_done» |
| `docs/stages/D_test_run.log`, `docs/stages/D_spec_questions.md`, `docs/reviews/D_review.md`, `docs/stages/D_authentication_report.md` | новые | RM-D-011, 012 | QA + ARCH | — | |

## 2. Выполненные проверки

### 2.1. Свежий прогон для этого отчёта (2026-10-22 07:01–07:17)

Команды запускались последовательно, на одной машине, без изменений кода. Полные выводы сохранены во временном каталоге сессии. В репозиторий они не копировались, потому что задача разрешает запись только в этот файл. Ключевые строки вывода — в Приложении А. Предыдущие прогоны интегратора и агента исправлений (04:37–06:58) — в `docs/stages/D_test_run.log`, их числа совпадают с этим прогоном.

| № | Задача / критерий | Команда | Результат | Где выполнено | Лог |
|---|---|---|---|---|---|
| 1 | DoD (13 §6.1) | `(cd pos-api) npm run lint` | код 0; tsc, eslint, «All matched files use Prettier code style!» | локально, 07:01 | Прил. А |
| 2 | DoD | `npm run build` | код 0 | локально | Прил. А |
| 3 | RM-D-011 (unit) | `npm test` | код 0; 12 файлов, **127 passed** | локально | Прил. А |
| 4 | RM-C-008 / RM-D-002 | `npm run test:integrations` | код 0; 5 файлов, 38 passed | локально | Прил. А |
| 5 | регресс C (RM-C-007) | `npm run test:worker` | код 0; 3 файла, 19 passed | локально | Прил. А |
| 6 | RM-D-003 п. 4 (JWT), фундамент | `npm run test:foundation` | код 0; 6 файлов, 55 passed | локально | Прил. А |
| 7 | RM-D-001 п. 1 | `npm run test:auth` | код 0; 3 файла, 52 passed | локально | Прил. А |
| 8 | регресс C (RM-C-006): схема без новых миграций | `npm run test:db` | код 0; 2 файла, 13 passed | локально | Прил. А |
| 9 | RM-D-006 п. 2–4, RM-D-016 | `npm run test:admin` | код 0; 3 файла, 36 passed | локально | Прил. А |
| 10 | RM-D-005, RM-D-014 п. 6 | `npm run test:customers` | код 0; 2 файла, 28 passed | локально | Прил. А |
| 11 | RM-D-004, RM-D-014 п. 2, RM-D-017 | `npm run test:registration` | код 0; 1 файл, 19 passed | локально | Прил. А |
| 12 | RM-D-004 (PIN, согласия), RM-D-015 п. 1–3 | `npm run test:profile`; `npm run test:settings` | код 0; 25 passed; 17 passed | локально | Прил. А |
| 13 | RM-D-002 п. 1, 3–5 | `npm run test:sms` | код 0; 4 файла, 65 passed | локально | Прил. А |
| 14 | DoD | `npm run madge`; `npm run check:permissions` | код 0; «No circular dependency found!»; «актуально (77 кодов, 7 ролей)» | локально | Прил. А |
| 15 | RM-D-001 п. 2–6, RM-D-003, RM-D-006 п. 1, RM-D-016, RM-D-017 | `npm run test:e2e` | код 0; 8 файлов, **77 passed, 4 skipped** (блок `runIf(VIA_PROXY)` в smoke — только через pos-proxy) | локально | Прил. А |
| 16 | RM-D-011 п. 2, RM-D-001 п. 1 | `npm run test:cov:d` | код 0; 29 файлов, 336 passed, 4 skipped; All files: строки **97,92 %**, ветви **88,51 %**, операторы 95,39 %, функции 96,22 %; по каталогам (строки): auth/common 96,9; auth/login 97,94; auth/otp 99,69; auth/pin 97,61; auth/sessions 98,34; auth/step-up 96,72; registration 96,13; registration/ports 75 (порог задан по глобу и выполнен в целом); `otp.service.ts`, `otp.provider.ts`, `step-up.service.ts` — 100 % строк и ветвей; `queued-sms-otp.provider.ts` — 94,44 % строк, 66,66 % ветвей | локально | Прил. А |
| 17 | регресс C (RM-C-015) | `node scripts/local-stack.mjs smoke` | код 0; 10/10 PASS | локально | Прил. А |
| 18 | RM-D-004, 005, 006, 017; RM-D-012 (API-часть) | `node scripts/local-stack.mjs auth-smoke` | код 0; **15/15 PASS** (реальные процессы pos-api и PostgreSQL 17; телефоны в выводе маскированы) | локально | Прил. А |
| 19 | RM-D-011 п. 1; 13 §6.1 | `python -I -X utf8 scripts/trace_test_ids.py`; `check_secrets.py`; `check_api_paths.py`; `check_api_permissions.py`; `check_env_example.py`; `sync_contracts.py --check` | код 0 у всех; матрица: 178 / 153 / 25 not_done / 0 без причины; секреты — 0 находок в 1224 файлах; пути — «OK»; права — 0 ошибок, 9 предупреждений; env — 97/97 | локально | Прил. А |
| 20 | RM-D-007…010, 014, 016, 017 (Flutter) | `(cd pos-app) flutter analyze`; `flutter test --concurrency=2 --reporter compact`; `python -I -X utf8 scripts/check_layers.py` | код 0; «No issues found!»; **+700 All tests passed!**; 213 файлов, 1243 импорта, 0 нарушений | локально | Прил. А |
| 21 | RM-D-007 п. 2 | `flutter test --tags golden --reporter compact` | код 0; +90 All tests passed (эталоны Windows) | локально | Прил. А |
| 22 | RM-D-012, RM-D-017 п. 4 | `LOCAL_STACK_MIN_APP_VERSION=android=0.1.0,windows=0.1.0 node scripts/local-stack.mjs serve --auth-fixtures …` (фон) + `flutter test integration_test/auth_flow_test.dart -d windows --dart-define-from-file=env/dev.json` | код 0; **+3 All tests passed** (3 сценария, см. §1.1 RM-D-012); API на порту 3000 — процесс этого прогона (проверено `Get-NetTCPConnection`) | локально, Windows | Прил. А |
| 23 | RM-C-014 (регресс) | `flutter test integration_test/boot_test.dart -d windows --dart-define-from-file=env/dev.json` | код 0; +1 All tests passed; `/health` 200 | локально, Windows | Прил. А |
| 24 | RM-C-013 (регресс) | `flutter build windows --release` | **не повторялась** в этом прогоне; последний результат — код 0 в 06:58 (`D_test_run.log`) | — | `D_test_run.log` |
| 25 | RM-D-008 п. 1, 4; RM-D-012 (Android) | `emulator.exe -avd Pixel_9_Pro …` | **не повторялась**: в 06:58 `FATAL … not enough disk space` (`D_test_run.log`). Сейчас на C: свободно 787 МБ (`df -h /c`), условия не изменились | — | `D_test_run.log` |

### 2.2. Не выполненные проверки

Такие проверки не считаются пройденными.

| Задача / критерий | Команда | Причина | Когда и кем будет выполнена |
|---|---|---|---|
| RM-D-002 п. 2; RM-D-011 п. 3; T-SMS-018, T-SMS-019 | контрактный тест `test=1` на тестовом аккаунте; доставка на реальный номер | нет аккаунта SMSPro и письменного разрешения на реальные SMS (Q-029, RM-A-004) | QA + SEC после выдачи аккаунта; ворота G-D допускают отметку «не проверено», реальная проверка обязательна до H (RM-H-001) |
| RM-D-008 п. 1, п. 4; T-BIO-003, T-BIO-006 | integration на Android: токен без BiometricPrompt недоступен; смена отпечатка инвалидирует ключ | эмулятор не стартует (C: ~0,8 ГБ свободно, AVD/SDK/`~/.gradle` на C:); устройства нет (RM-A-008) | QA после освобождения ≥ 8–10 ГБ на C: или переноса `ANDROID_AVD_HOME` владельцем машины, либо на устройстве Android Class 3 |
| RM-D-008 (сборка) | `gradlew :app:compileDebugKotlin` / `flutter build apk --debug` | не запускалась: та же нехватка места; прошлая попытка (02:48) оставила журналы ошибок Kotlin-демона в `pos-app/android/.kotlin/errors/` | FE вместе с проверкой выше |
| T-BIO-007 | канал iOS (`AppDelegate.swift`) | нет macOS/Xcode (Q-008) | FE при появлении macOS |
| RM-D-012 | путь на Android; видео/скриншоты пути «Splash → … → каталог-заглушка» | Android — см. выше; скриншоты/видео не снимались (автоматического снятия в `integration_test` нет) | QA при закрытии D-KI-01 |
| RM-D-012 / RM-C-012 | прогон против тестового контура compose + Caddy | нет Docker (G-C) | OPS после установки Docker (разрешение заказчика) |
| RM-D-010 п. 2–3 | golden SCR-45; `integration_test` «приглашение в UI → вход» | не написаны | FE/QA, до закрытия RM-D-010 |
| RM-D-009 (SCR-42), RM-D-015 п. 4 и Flutter-часть | widget «Устройства/сессии», «Защита входа»; `public_settings_provider.dart` | не реализованы | FE, до закрытия RM-D-009/RM-D-015 |
| RM-D-015 п. 2 (часть) | `PUT /admin/settings` с `customer_self_service` → `VALIDATION_FAILED` | маршрута `/admin/settings` нет | BE вместе с маршрутом |
| RM-D-011 п. 1 (остаток) | T-AUTH-025, T-AUTH-033, T-REG-008, T-REG-014, T-SESS-012, T-BIO-017 и T-SEC вне этапа D (022, 023, 027, 036, 037, 039–042, 046, 047, 054, 067), T-SMS-015, T-SEC-040 | P2/P3 без отдельного теста, функция последующих этапов, ручная/инфраструктурная проверка (причины по ID — Приложение А, вывод `trace_test_ids.py`) | по этапам E/F/H и CI |
| CI | любой job `.github/workflows/ci.yml` | нет хранилища кода и раннеров (Q-131) | OPS |

## 3. Известные проблемы

| ID | Описание | Серьёзность | Обход | План (задача, срок) |
|---|---|---|---|---|
| D-KI-01 | Ничего не проверено на Android и iOS: криптопривязка биометрии (D-13), инвалидация ключа, путь входа, сборка APK. Нативный код канала не компилировался | **блокер** (внешний: место на диске / устройство / macOS) | нет. На Windows путь проверен, биометрия там — только UX-гейт | RM-D-008, RM-D-012; до G-D |
| D-KI-02 | SCR-42 «Устройства/сессии» и «Защита входа» (смена PIN, `logout-all` из UI) не реализованы. Логика в `core/session` есть и покрыта тестами | существенно | нет UI | RM-D-009 |
| D-KI-03 | RM-D-015: нет `public_settings_provider.dart`. Флаги `features` во Flutter берутся из `--dart-define` (FA-08), а не с сервера | существенно | флаг сборки `FEATURE_CUSTOMER_SELF_SERVICE` (по умолчанию `true`) | RM-D-015 |
| D-KI-04 | Нет `docs/integration/smspro_connect.md` (выход RM-D-002) | существенно | — | RM-D-002, до H |
| D-KI-05 | SCR-45: нет golden-эталонов и `integration_test` «приглашение в UI → вход» | незначительно | API-путь проверен `auth-smoke`; UI — widget-тестами | RM-D-010 |
| D-KI-06 | Отступления от схемы 07 без миграций: `admin_code` не пишется в `sessions.amr` (FX-01); лимиты IP/устройства 10 мин, IP 24 ч и глобальный лимит не используют `rate_limit_counters` (F-01, auth A-02); `refresh_replay` записывается как `reuse_detected` (auth A-08) | существенно | обходы в коде (§5.3, DQ-01…DQ-03) | владелец 07; миграция `0003_*` после решения |
| D-KI-07 | Часть состояния — только в памяти процесса: memo `jti` при повторе verify, кэш denylist, кэш «PIN установлен», лимиты RL-*, circuit-breaker OTP (FX-11) | незначительно для R1 (одна реплика, D-45) | — | ARCH, до масштабирования (DQ-26) |
| D-KI-08 | Исправления по D_review (D-MJ-01, D-MJ-02, D-MN-01…08) проверены прогоном, но повторной независимой проверки не было | существенно (процесс, 13 §6.1 п. 11) | — | QA + SEC: повторная проверка RM-D-016 и `trace_test_ids.py` |
| D-KI-09 | ADR-087 (собственный platform channel биометрии) — в статусе «Предложено». AC-ADR-087 требует протокол на устройстве | существенно | — | после D-KI-01 |
| D-KI-10 | `applicationId`/пакет Android — шаблонный `com.example.optomstroy` (FX-08) | незначительно на D; блокер для публикации | — | заказчик / владелец 16 |
| D-KI-11 | Golden-эталоны сняты только на Windows; Linux-эталоны CI не проверялись | незначительно | — | CI (Q-131) |
| D-KI-12 | На машине после прогона остался процесс `local-stack.mjs serve` от **предыдущего** прогона другого агента (PID 53156, запущен 04:53, порт 3000 не держит). Мой процесс `serve` (PID 26524) остановится сам по `--ttl 1200` около 07:35. Чужой процесс не трогался | незначительно | — | владелец машины |

**Действующие допущения** (вопросы без ответа заказчика):

| Q-NNN | Принятое допущение | Какие задачи от него зависят | Последствие при другом ответе |
|---|---|---|---|
| Q-029 / RM-A-004 | Адаптер SMSPro проверен только на фикстурах и локальном mock; в dev — `FakeSmsGateway`/тестовый режим OTP | RM-D-002, RM-D-011 | формат ответов реального аккаунта может отличаться (SMS-Q-01…12) |
| Q-031 | Связь с 1С по LAN, `/integrations/onec/*` выключен (ADR-082) | RM-D-013 не выполняется | при C-2 — RM-D-013 (+2 у.е.) |
| Q-035 | Плоская заглушка персонажа с входами state machine `MascotAuth` | RM-D-007 | замена `.riv` без изменения экранов; имя ассета не согласовано (AU-09) |
| Q-165, Q-203 | Коды сферы деятельности = ключи ARB (`plumber`, `foreman`, `reseller`, `installer`, `private`, `other`); свободный текст «Другое» не передаётся | RM-D-004, RM-D-008 | правка справочника и DTO |
| Q-161 | `birthYear` 1920…(текущий − 14) | RM-D-014 | правка валидации |
| Q-154 | Лимит устройств: staff 3, customer 5 | RM-D-003 | константа |
| Q-168 | Аварийный код: TTL 10 мин, лимиты 3/20 в сутки по аудиту | RM-D-016 | правка лимитов |
| Q-027 | Тексты согласий — черновики `contracts/legal/consents_ru.md`, в ARB — заглушки «Шаблон N» | RM-D-004, RM-D-008 | замена текстов и версий согласий |
| Q-037, Q-181 | Root/jailbreak-эвристика, SMS User Consent и `FLAG_SECURE` не реализованы | RM-D-007, RM-D-008 | доработка Android-части |
| Q-008 | iOS не собирается (нет macOS) | RM-D-008 | проверка канала iOS |

## 4. Условия перехода дальше

- **Статус ворот G-D: красный** (13 §6.2).
  - Открыт блокер окружения D-KI-01.
  - Не закрыты RM-D-002, RM-D-008, RM-D-009, RM-D-010, RM-D-015, а условие ворот требует закрыть RM-D-001…009, 014, 015, 016, 017.
  - По безопасности блокеров и критичных дефектов нет.
  - По 13 §2.3 BE/ONEC-задачи RM-E-001…RM-E-005 могут стартовать после G-C. FE-дорожка этапа E ждёт G-D.

| Условие ворот (13 §3.4) | Выполнено? | Доказательство (раздел 2, № строки) |
|---|---|---|
| RM-D-001, 003, 004, 005, 006, 007, 014, 016, 017 закрыты | да (локально; RM-D-005, 007, 016 — с оговорками §1.1) | стр. 3–18, 20–22 |
| RM-D-002 закрыта | нет (п. 2 и `smspro_connect.md`) | стр. 13; §2.2 |
| RM-D-008 закрыта | нет (п. 1, 4 — Android) | стр. 25; §2.2 |
| RM-D-009 закрыта | нет (SCR-42) | §1.1 |
| RM-D-015 закрыта | нет (Flutter-часть, п. 4) | стр. 12; §2.2 |
| RM-D-010 (входит в зависимости RM-D-011/016/017; формально в списке условий нет) | нет (п. 2–3) | §2.2 |
| RM-D-013 — только при C-2 | не требуется (C-2 не выбран) | §3, Q-031 |
| RM-D-011: все тесты зелёные, покрытие ≥ 80 % | да для запущенных: все команды — код 0; строки 97,92 % | стр. 3–23, 16 |
| RM-D-011: все T-AUTH/REG/SESS/SMS из 12 запущены | нет: 25 ID not_done с причиной | стр. 19 |
| RM-D-012 отчёт | да (этот файл + `docs/reviews/D_review.md`); путь на Android и видео — нет | стр. 22–23, 25 |
| 0 открытых блокеров/критичных по безопасности | да (D_review §5–§6; повторной независимой проверки исправлений нет — D-KI-08) | `docs/reviews/D_review.md` |

- **Что требуется от заказчика и владельца машины**:

| Действие / вопрос | Для какой задачи | Срок (ворота) |
|---|---|---|
| Освободить ≥ 8–10 ГБ на C: или разрешить перенос AVD/SDK/`~/.gradle` на D:; либо предоставить устройство Android с биометрией Class 3 (RM-A-008) | RM-D-008, RM-D-012 | G-D |
| Тестовый аккаунт SMSPro, тестовый номер, письменное разрешение на реальные SMS (Q-029, RM-A-004) | RM-D-002, RM-D-011 | до H (RM-H-001) |
| Идентификатор приложения (`applicationId`, bundle id) | RM-D-008, публикация | до H |
| Ответы Q-165/Q-203 (справочник сфер), Q-027 (тексты согласий), Q-035 (персонаж), Q-161, Q-154, Q-168 | §3, допущения | до пилота |
| Решения владельцев ТЗ по вопросам §5.3: в первую очередь DQ-01…DQ-03 (миграция схемы) и DQ-04…DQ-06 (противоречия 08 ↔ 09 ↔ 11) | RM-D-001, 003, 006, 016 | до закрытия G-D |
| macOS для сборки iOS (Q-008) | RM-D-008 (iOS) | по решению Q-008 |

- **Решения, принятые на этапе**: ADR-087 «Криптопривязка биометрии — собственный platform channel `kg.optomstroy/biometric_crypto`; Windows Hello — UX-гейт» — статус **«Предложено»** (`docs/specification/15_DECISION_LOG.md`, файл изменён 2026-10-22 03:13). Подтверждение — после протокола на устройстве. Других ADR этап D не добавлял. Временные решения в коде перечислены в §5.3.

## 5. Приложения

### 5.1. Независимая проверка

`docs/reviews/D_review.md` — агент QA + SEC, 2026-10-22.
- Вывод до исправлений: по безопасности ворота «жёлтые» (0 блокеров), по полноте — «красные» (D-MJ-01…03).
- Статусы после исправлений (§6 обзора, их записал агент исправлений):
  - исправлены D-MJ-01, D-MJ-02, D-MN-01…06;
  - частично исправлено D-MN-08;
  - перенесено на E/F D-MN-07;
  - задокументировано как ограничение D-MN-09;
  - не исправлено D-MJ-03 (Android).
- Мой прогон подтверждает числа агента исправлений: 127 / 52 / 36 / 28 / 25 / 19 / 17 / 65 / e2e 77 + 4 / cov 336 + 4 / 700 / golden 90 / матрица 178–153–25–0.

### 5.2. Логи

- `docs/stages/D_test_run.log`:
  - прогон интегратора 04:37–05:06;
  - повторный прогон после исправлений 06:13–06:58, включая журнал эмулятора и `flutter build windows --release`.
- Свежий прогон этого отчёта — Приложение А ниже. Полные выводы остались во временном каталоге сессии и в репозиторий не записывались.

### 5.3. Вопросы к ТЗ этапа D (сводка `docs/stages/D_spec_questions.md`)

**Как читать таблицу:**
- В исходном файле 169 пунктов, их записали 11 агентов. Здесь они сведены в 30 тем `DQ-NN`.
- В исходном файле два раздела используют одинаковые номера `A-01…A-15`. Ниже они различаются префиксами: «adm A-NN» — агент admin, «auth A-NN» — агент auth.
- Значение графы «Статус»:
  - «открыт» — в коде действует временное решение, ответ владельца ТЗ нужен;
  - «закрыт в коде» — дефект кода исправлен, и это подтверждено в коде или тестом; правка ТЗ при этом может всё ещё требоваться.
- `docs/specification` этапом D не правился.

| № | Тема | Суть пробела / противоречия | Исходные пункты | Временное решение в коде | Кому решить | Статус |
|---|---|---|---|---|---|---|
| DQ-01 | 07: области `rate_limit_counters` | CHECK `rate_limit_counters_scope_chk` не содержит окон из 16 §4.3 / 09 §5.4 / 08 §2.9 (IP 10 мин и 24 ч, устройство 10 мин, глобальный 1 мин, RL-ADMIN, лимиты выдачи аварийного кода, группы `/registration`, `/me*`) | F-01, auth A-02, adm A-10, adm A-11, PR-11, A-22 | подсчёт по `otp_challenges` и `audit_logs`; часть групп — in-memory `AuthHttpRateLimiter`; RL-ADMIN нет | владелец 07 §5.12, 08 §2.9 | открыт |
| DQ-02 | 07 + контракт: `amr = admin_code` | `sessions_amr_chk` и enum `AuthTokenPair.amr`/`Me.session.amr` не допускают `admin_code` (09 §6.13) | adm A-09, FX-01 | `admin_code` — только в access-JWT и аудите; признак сессии — `created_from_challenge_id` | владелец 07 §5.9, 08 | открыт |
| DQ-03 | 07: недостающие столбцы и значения | `otp_challenges`: `salt` избыточен (соль = `challenge_id`), нет `issued_by_user_id`, `locked_at`, статуса «в очереди», `issued_jti`; частичный UNIQUE активного кода против 09 §4.4; `sessions_revoke_reason_chk` без `refresh_replay`; `app_pins` без счётчика по устройству; нет реестра step-up `jti`; `sms_outbox` без `request_id`, смысл `outcome`; нет хранилища снимка баланса SMS | F-03, adm A-08, auth A-05…A-09, auth A-14, auth A-15, SMS-Q-04, SMS-Q-06, SMS-Q-09 | обходы описаны в исходных пунктах (аудит как признак, `superseded`, `created_at` вместо `locked_at`, `reuse_detected`, счётчик на пользователя, привязка step-up к `sid`/`pv`, `jti` в памяти 2 мин) | владелец 07 | открыт |
| DQ-04 | Приглашения: 08 ↔ 09 ↔ 11 | номер действующего `customer` в приглашении (08/09 «применяется» ↔ 11 SEC-136 п. 4); можно ли приглашать `admin`; ответ `POST /admin/users` для номера без учётной записи; `roles` > 1 и `fullName` nullable в схеме против БД | adm A-01…A-04, FA-02, FA-07 | по 11 SEC-136: клиент → 409 `customer_account`; `admin` → 403 `role_not_invitable`; ответ — `Invitation`; одна роль, ФИО обязательно | владельцы 08 §4.18, 09 REG-022, 11 SEC-136, ARB | открыт |
| DQ-05 | Роли: самоизменение, `admin → admin`, причина | код ответа на смену своей роли (08 — 422, 11 — 403); может ли `admin` назначить `admin` (08 ↔ ядро §21 п. 3); обязательность `reason` (11 SEC-076, §7.2 ↔ схемы); разблокировка `pending_activation` | adm A-05…A-07, adm A-12, LNK-07 | 403 `self_target`; `admin` может назначать `admin`; причина ≥ 5 символов обязательна при изменении; разблокировка → `active` | владельцы 08 §4.18.2–3, 11 SEC-040/043/076, ядро | открыт |
| DQ-06 | Формат `stepUpToken` | claims и `scope` не зафиксированы (08 §2.12 / 09 §8.8); OpenAPI `scope: PermissionCode[]` ↔ узкие операции `profile.*`/`session.*` | adm A-15, LNK-06, auth A-11 | единый `StepUpTokenVerifier` (sub, sid, deviceId, pv, scope-массив, method, denylist) — D-MN-01 исправлено | владелец 08 §2.12 / OpenAPI | открыт (код унифицирован) |
| DQ-07 | OTP: контракт 08 ↔ 09 | повтор verify ≤ 60 с есть в 09/12/13, нет в 08; `devCode` в dev; поля `until` у `PIN_LOCKED` и `reason` у `UNLOCK_REQUIRED` нет в `Problem`; чужой `challengeId` в confirm; `/auth/otp/request` с другого устройства после выдачи аварийного кода; лимит RL-OTP-STATUS | auth A-01, auth A-19, AU-03, auth A-21, AU-15, PR-07, FX-03, auth A-22 | по 09 §5.6; `devCode` не возвращается; расширения `until`/`reason`; `OTP_EXPIRED`; 409 `DEVICE_MISMATCH` | владелец 08 §4.1, §2.4 | открыт |
| DQ-08 | Семантика сессий и статусов | отзыв сессии при `X-Device-Id` ≠ claim; отсутствие `X-Device-Id`; код для `blocked`/`deleted`/`pending`; грация refresh (09 §8.3 ↔ 12 T-SESS-006); лимит устройств; ограниченная сессия до PIN; `UNLOCK_REQUIRED` на любом маршруте для аварийной сессии | F-05…F-07, auth A-10, auth A-17, auth A-20, auth A-23, FX-02 | 401 `SESSION_REVOKED` без отзыва в БД; 400 `rule=uuid`; грация однократна; staff 3 / customer 5; `pin_not_set` 403; `UNLOCK_REQUIRED reason=emergency_code` | владельцы 08 §2.4, 09 §8, Q-154 | открыт |
| DQ-09 | Секреты и криптография | формат файла секрета с несколькими версиями (ротация pepper/HMAC); прочтение `Argon2id(pepper‖pin‖user_id)`; ключ шифрования текста SMS в очереди (`SMS_OUTBOX_KEY_FILE` нет в 16) | F-02, F-08, SMS-Q-02 | строка или JSON `{"v":"…"}`; конкатенация в пароль; AES-256-GCM с ключом HKDF от `OTP_HMAC_SECRET` | владельцы 16 §4.3, 09 §9.6, 11 §5.1 | открыт |
| DQ-10 | Дефекты фундамента (common/crypto, common/auth, тесты C) | эфемерный pepper не UTF-8 → любой PIN `PIN_INVALID` в dev; AuthGuard отвечал `UNAUTHENTICATED` вместо `SESSION_REVOKED` после `denyJti`; `prod-guard.spec` делал бы реальный HTTPS к SMSPro | auth A-12, RG-07, auth A-13, SMS-Q-14 | эфемерный секрет — base64url-строка (`secret-ring.ts`); `jtiDenied` проверяется первым (`auth.guard.ts`); кейс переведён на локальный транспорт | — | закрыт в коде (проверено чтением кода и прогоном стр. 4, 6) |
| DQ-11 | DTO регистрации | `consents(kind=sms)` при регистрации (08 ↔ 09); длина ФИО (09 2–120, 08 1–150, 07 2–150); справочник `activitySphere`; код «не та версия согласия»; 400 или 422 для `login_protection_required`; идемпотентность с другого устройства; повтор `/registration/complete`; форма `customer-match` (09 ↔ 08) | RG-01…RG-06, FX-04, LNK-12, RB-03 | `sms` не создаётся; 2…150; коды по ARB; `CONSENT_REQUIRED`/`consent_version`; staff 422, customer 400; 401 `REGISTRATION_TOKEN_INVALID`; один повтор неиспользованной сессии; DTO по OpenAPI | владельцы 08 §4.2, 09 §7; заказчик (Q-165, Q-203) | открыт |
| DQ-12 | Профиль `/me*` | круг исключения «первый PIN без step-up»; включение биометрии без step-up 15 мин после OTP; имена полей `Me` (09 ↔ OpenAPI); `idleLockMinutes` для customer; уведомление при отзыве `personal_data`; общий `rowVersion` профиля и настроек; склад по умолчанию; код отказа `DELETE /me/pin`; нет `createdAt` и `pinLength` в `Me`; `biometricClass` для iOS | PR-01…PR-10, RB-04, RB-07, RB-08, SS-04 | см. исходные пункты (исключение — любая OTP-сессия без PIN ≤ 15 мин; по OpenAPI; customer 5…60; уведомление не создаётся; один `rowVersion`; `settings.defaultWarehouseId`; `login_protection_required`; длина PIN по `kind`) | владельцы 07, 08 §4.3, 09 §7, §9 | открыт |
| DQ-13 | Привязка клиента | правило `phones[].verified`; нет `kind` в `CustomerCandidate`; смысл `CUSTOMER_LINK_CONFLICT` и `force`; кто отклонил; ответы для «чужого» статуса; нет события аудита создания/конфликта привязки; `features.qrWebhook` и ключ `qr.enabled` | LNK-01…LNK-05, LNK-08, LNK-13 | verified — только основной телефон карточки 1С; `customer_type='legal'`; 409 в обоих случаях; `confirmed_by_user_id` — автор решения; 200/409/404; in-app уведомление без аудита; буквально по 08 | владельцы 05/18, 07 §5.28–5.30, 08 §4.11.7, 09 §7.9, 11 §7.2 | открыт |
| DQ-14 | Владение маршрутами | `/registration/customer-match` (RM-D-004 ↔ RM-D-005); `GET /customers` (RM-D-005 ↔ RM-G-001); путь `src/admin/settings` ↔ `src/settings`; `features/admin/users/**` ↔ правило слоёв; `core/hardware/biometric_service.dart` ↔ `core/biometrics` | LNK-09…LNK-11, RG-08, FA-01, RB-05 | маршрут у `customers/links`, порт `CUSTOMER_MATCHING_PORT` подключён (`auth-smoke`: `customerMatch=proposed`); `GET /customers` только с `linkStatus`; `src/settings`; `features/admin/{domain,data,presentation}/users`; `core/biometrics` | владелец 13, 06 | открыт (интеграция выполнена) |
| DQ-15 | SMS: эксплуатация | очередь `sms.dlr_poll` не в перечне 06; объём push-DLR в R1 (09 ↔ 13); порог circuit-breaker без минимальной выборки; паузы повторов; дубль `id`; канал метрик и алертов; DR-опрос для `ACCEPTED_TEST`; значения `SMSPRO_BALANCE_POLL_MINUTES`, не делящие 60 | SMS-Q-01, SMS-Q-03, SMS-Q-05, SMS-Q-07, SMS-Q-08, SMS-Q-10…SMS-Q-12 | реализовано по исходным пунктам (push за флагом, ≥ 4 вызовов/мин, 5/10/10 с, алерт в лог, `*/N`) | владельцы 06 §7.5, 09 §6, 16 | открыт |
| DQ-16 | Вариант доставки OTP | `OtpProvider`: отправка процессом pos-api после COMMIT (код только в памяти) или воркером через `sms.send` с шифрованным текстом (09 §6.8 «отправляет pos-worker») | auth A-04, INT-01 | в `AppModule` — `AuthModule` (pos-api); переключение на `withQueuedSms()` одной строкой | владелец 09 §6.8, ARCH | открыт |
| DQ-17 | Проверка телефона | 09 §3.4 требует libphonenumber-совместимую проверку `mobile`; метаданные считают мобильными и диапазоны 600/880 | auth A-03, INT-08 | `libphonenumber-js/max`, тип `MOBILE` | владелец 09 §3.4 (подтвердить диапазоны) | открыт (зависимость подключена) |
| DQ-18 | Аудит | какой ID писать в `audit_logs.device_id`; события `audit.chain.*`/`audit.anchor.written` вне словаря; время якоря 00:30 ↔ 03:30; `rows_count` — за сутки или накопленный | F-04, F-09…F-11 | `X-Device-Id`; события лога; якорь не зависит от времени запуска; строки за сутки | владельцы 07 §9.3, 11 §7 | открыт |
| DQ-19 | RBAC и каркас | источник прав в рантайме (`permissions.yaml` или таблицы БД); шаблон eslint `../auth/*` ловит `common/auth`; нет отключения идемпотентности для маршрута | F-12, F-13, adm A-14 | `permissions.yaml`; обходной импорт; `IgnoreIdempotencyKeyGuard` | владельцы 11 §4, RM-C-005 | открыт |
| DQ-20 | Уведомления | нет API модуля notifications: уведомление о входе с нового устройства (T-SESS-012), администратору при отзыве `personal_data` | auth A-18, FX-09, PR-06 | не реализовано; событие `auth.login` в аудите есть | владелец notifications / 13 (этап) | открыт |
| DQ-21 | Клиент: жизненный цикл сессии | офлайн-выход и outbox `auth.logout` без Bearer; «Сменить аккаунт» с экрана блокировки; причина `SESSION_REVOKED` при отказе `/auth/refresh`; длительности блокировок не приходят в `PublicSettings`; закрытие файла БД пользователя; таймаут secure storage; кэш `stepUpToken` через блокировку; каким refresh пользоваться после биометрической разблокировки; второй системный диалог при сохранении нового `biometric_refresh` | SS-03, SS-06…SS-12, AU-07 | локальный выход; 30/5 мин зашиты в `SessionPolicy`; таймаут 5 с; кэш step-up очищается при блокировке; стандартный refresh сохраняется | владельцы 08 §4.1/§4.23, 09 §8–§9, FE core | открыт |
| DQ-22 | Черновик регистрации и кэш профиля на устройстве | до регистрации нет БД пользователя для `registration_draft`; срок, метод и `Idempotency-Key` не проходят белый список DAO; ключей кэша профиля (`kind`, роль, ФИО) нет | RB-01, RB-02, AU-06 | ФИО и год — secure storage; шаги — память; SCR-08 `cold` без кэша | владельцы 07 §11, 02 §0.4 | открыт |
| DQ-23 | Навигация и экраны 02 | два экрана первой установки PIN (SCR-08 UI-08-014 ↔ SCR-04); SCR-04 сотрудника под `/register/*`; холодный старт — слой или маршрут; формулировка RM-D-008 п. 3; переход «Аудит пользователя» без параметров маршрута; API «step-up до запроса»; предложение биометрии после входа | AU-10, INT-05, SS-05, AU-05, RB-06, FA-10, FA-09, AU-11 | один экран SCR-04; `_RegisterFormEntry`; слой `SessionGate`; Splash решает сам (роутер `/splash` → `null`, проверено чтением `auth_guard.dart`); строковый `push`; `StepUpCoordinator.obtain` | владельцы 02, 06 §6.4, 13 | открыт (AU-05 закрыт в коде) |
| DQ-24 | Дизайн-система и ARB | `Mascot`, `SplashLogo`, `SuccessCheck`, `StepUpDialog`, `RoleBadge`, `AppAvatar` живут в фичах, а не в design_system (registration не может использовать персонажа); `ConfirmDialog.show` без `reasonMaxLength`; нет ключей ARB: статусы привязки, вкладки step-up, wordmark, состояния персонажа, `role_<code>_summary`, «Изменить»; в ARB заглушки текстов согласий и Шаблона 2; нет колбэка переполнения `PhoneField` | AU-01, AU-02, AU-04, AU-08, AU-12, AU-13, FA-03…FA-06, SS-01, SS-02, RB-11, RB-12 | временные ключи и константы; компоненты в фичах | владельцы 03 (DS), RM-B-007 (ARB), юрист (Q-027) | открыт |
| DQ-25 | Платформенные части | тема AppCompat для `local_auth` (T-BIO-018); root/jailbreak (Q-037); SMS User Consent и `FLAG_SECURE` (Q-181); где хранить локальный выбор Windows Hello; офлайн-баннер экранов входа | RB-09, RB-10, RB-13, FX-06, AU-14, AU-16 | тема не менялась; эвристики нет; `SecureKey.biometricsEnabled = windows_hello`; порт офлайна по умолчанию `false` | FE, SEC, заказчик (Q-037, Q-181) | открыт |
| DQ-26 | Масштабирование (несколько реплик) | memo `jti`, кэш denylist, кэш «PIN установлен», лимиты RL-*, breaker OTP — в памяти процесса | FX-11, D-MN-09, auth A-15 | допустимо для одной реплики R1 (D-45) | ARCH, владелец 06/07 | открыт |
| DQ-27 | Эксплуатация и тестовый контур | первичный `admin` на пустой БД; `MIN_APP_VERSION` 1.0.0 против версии сборки 0.1.0; лимиты устройства мешают сквозным прогонам; адаптер 1С при `ONEC_MODE=extension` до RM-E-001; команда покрытия (`test:cov` против `test:cov:d`) | INT-02…INT-04, INT-06, INT-07 | только local-stack: фикстуры администратора, `LOCAL_STACK_MIN_APP_VERSION`, поднятые лимиты; `onec: 'auto'`; новая команда `test:cov:d` | владельцы 16, 11, 09 §5.4, RM-E-001, 13 | открыт |
| DQ-28 | Выходы 13, не созданные агентами | `docs/integration/smspro_connect.md` вне путей агента SMS; `assets/rive/mascot.riv` ↔ `mascot_auth.riv`; проверки RM-D-015 п. 2 и п. 4 вне путей агента | SMS-Q-13, AU-09, LNK-14, FA-08 | не созданы (D-KI-03, D-KI-04) | оркестратор этапа D / владелец 13 | открыт |
| DQ-29 | Окружение проверки на устройстве и идентификатор приложения | эмулятор не стартует (место на C:); `applicationId` не задан в ТЗ | FX-07, FX-08, INT-09 | — | владелец машины, заказчик / 16 | открыт (D-KI-01, D-KI-10) |
| DQ-30 | Найдено и исправлено ревью без вопроса к ТЗ | единый ключ RL-PIN; staff на `DELETE /me/pin` получал `STEP_UP_REQUIRED` вместо 403 `pin_required_for_staff`; глобальные guard'ы этапа D не были подключены в `app.module.ts` | FX-05, FX-10, auth A-16 | исправлено; guard'ы подключены (`auth-smoke` 15/15: `pin_not_set`, `STEP_UP_REQUIRED`) | — | закрыт в коде |

### Приложение А. Выдержки из вывода свежего прогона (2026-10-22)

Строки скопированы из выводов команд без изменений. ANSI-коды удалены. Телефоны маскированы самим скриптом. Полные выводы — во временном каталоге сессии (`…/scratchpad/runs/*.log`), в репозиторий не сохранялись.

```
$ (cd pos-api) npm run lint            → All matched files use Prettier code style!   # exit 0 (07:01:27)
$ (cd pos-api) npm run build                                                          # exit 0 (07:01:33)
$ (cd pos-api) npm run test            →  Test Files  12 passed (12) / Tests  127 passed (127)   # exit 0
$ npm run test:integrations            →  Test Files  5 passed (5)  / Tests  38 passed (38)      # exit 0
$ npm run test:worker                  →  Test Files  3 passed (3)  / Tests  19 passed (19)      # exit 0
$ npm run test:db                      →  Test Files  2 passed (2)  / Tests  13 passed (13)      # exit 0
$ npm run test:foundation              →  Test Files  6 passed (6)  / Tests  55 passed (55)      # exit 0
$ npm run test:auth                    →  Test Files  3 passed (3)  / Tests  52 passed (52)      # exit 0
$ npm run test:admin                   →  Test Files  3 passed (3)  / Tests  36 passed (36)      # exit 0
$ npm run test:customers               →  Test Files  2 passed (2)  / Tests  28 passed (28)      # exit 0
$ npm run test:profile                 →  Test Files  2 passed (2)  / Tests  25 passed (25)      # exit 0
$ npm run test:registration            →  Test Files  1 passed (1)  / Tests  19 passed (19)      # exit 0
$ npm run test:settings                →  Test Files  2 passed (2)  / Tests  17 passed (17)      # exit 0
$ npm run test:sms                     →  Test Files  4 passed (4)  / Tests  65 passed (65)      # exit 0
$ npm run test:e2e                     →  Test Files  8 passed (8)  / Tests  77 passed | 4 skipped (81)   # exit 0 (07:08:31)
$ npm run madge                        →  ✔ No circular dependency found!                         # exit 0
$ npm run check:permissions            →  gen-permissions: актуально (77 кодов, 7 ролей)          # exit 0
$ npm run test:cov:d                   →  Test Files  29 passed (29) / Tests  336 passed | 4 skipped (340)
                                          Statements 95.39% (1367/1433)  Branches 88.51% (994/1123)
                                          Functions 96.22% (255/265)     Lines 97.92% (1273/1300)     # exit 0 (07:11:24)
$ node scripts/local-stack.mjs smoke   →  [local-stack] итог: 10/10 PASS                          # exit 0 (07:11:37)
$ node scripts/local-stack.mjs auth-smoke
  PASS клиент +9967*****03: POST /auth/otp/request → 202
  PASS клиент: POST /auth/otp/verify → 200 registration_required
  PASS клиент: POST /registration/complete → 201, customer active
  PASS клиент: GET /me → 200, pinSet=true
  PASS клиент +9967*****56 с карточкой 1С: 201, customerMatch=proposed (SCR-06)
  PASS приглашённый +9967*****02: verify → authenticated staff/seller, roleSource=invitation, nextStep=set_pin
  PASS приглашённый до PIN: прочие маршруты → 403 FORBIDDEN reason=pin_not_set
  PASS приглашённый: первый POST /me/pin без step-up → 204
  PASS приглашённый: GET /me → pinSet=true, ФИО приглашения
  PASS admin: OTP → POST /me/pin → POST /auth/step-up (pin) → stepUpToken
  PASS admin: POST /admin/invitations без X-Step-Up-Token → 403 STEP_UP_REQUIRED
  PASS admin: POST /admin/invitations (cashier) → 201
  PASS приглашённый администратором: OTP → staff/cashier, nextStep=set_pin
  PASS неверный код → 422 OTP_INVALID с attemptsLeft
  PASS JWT alg=none → 401 UNAUTHENTICATED
  [local-stack] auth-smoke итог: 15/15 PASS                                                  # exit 0 (07:11:48)
$ python -I -X utf8 scripts/check_secrets.py        → файлов проверено: 1224; находок: 0            # exit 0
$ python -I -X utf8 scripts/check_api_paths.py      → OK: все обязательные пути и методы есть; запрещённых и лишних операций нет
$ python -I -X utf8 scripts/check_api_permissions.py→ ИТОГ: ошибок 0, предупреждений 9            # exit 0
$ python -I -X utf8 scripts/check_env_example.py    → ожидается 97, в .env.example 97; недостающих 0, лишних 0; ошибок 0
$ python -I -X utf8 scripts/trace_test_ids.py       → ИТОГ: ID в охвате 178; с тестом 153; not_done с причиной 25; без теста и причины 0
   not_done: T-AUTH-025, T-AUTH-033, T-SMS-015, T-SMS-018, T-SMS-019, T-SESS-012, T-BIO-003, T-BIO-006,
             T-BIO-007, T-BIO-017, T-REG-008, T-REG-014, T-SEC-022, T-SEC-023, T-SEC-027, T-SEC-036,
             T-SEC-037, T-SEC-039, T-SEC-040, T-SEC-041, T-SEC-042, T-SEC-046, T-SEC-047, T-SEC-054, T-SEC-067
$ python -I -X utf8 scripts/check_layers.py         → check_layers: файлов 213, импортов 1243, нарушений 0
$ python -I -X utf8 scripts/sync_contracts.py --check → OK l10n: 3 файл(ов) идентичны            # exit 0
$ (cd pos-app) flutter analyze                       → No issues found! (ran in 100.2s)            # exit 0 (07:13:47)
$ flutter test --concurrency=2 --reporter compact    → 01:00 +700: All tests passed!                # exit 0 (07:14:53)
$ flutter test --tags golden --reporter compact      → 00:46 +90: All tests passed!                 # exit 0 (07:15:43)
$ (cd pos-api) LOCAL_STACK_MIN_APP_VERSION=android=0.1.0,windows=0.1.0 node scripts/local-stack.mjs serve --auth-fixtures --ready-file <tmp> --ttl 1200   # фон
  [local-stack] pos-api pid=48864 готов: http://127.0.0.1:3000 (обычный режим)
$ flutter test integration_test/auth_flow_test.dart -d windows --dart-define-from-file=env/dev.json
  √ Built build\windows\x64\runner\Debug\optomstroy.exe
  00:00 +0: T-AUTH-031, T-AUTH-043, T-REG-025 (в): клиент: Splash → телефон → OTP → регистрация → PIN → каталог-заглушка (SCR-50)
  00:12 +1: приглашённый сотрудник: OTP → установка PIN без регистрации → каталог-заглушка (SCR-10)
  00:21 +2: клиент с карточкой 1С: OTP → регистрация → PIN → SCR-06 «Привязка к клиенту»
  00:32 +3: All tests passed!                                                                  # exit 0 (07:17:06)
$ flutter test integration_test/boot_test.dart -d windows --dart-define-from-file=env/dev.json
  boot_test: API_BASE_URL=http://127.0.0.1:3000/api/v1 → BackendHealthReport(ok: true, httpStatus: 200, …)
  00:01 +1: All tests passed!                                                                  # exit 0 (07:17:41)
$ df -h /c                                           → C:  460G  459G  787M 100% /c
```

---

## Дополнение 2026-10-22: остатки D, закрытые на этапе E

Раздел добавлен после этапа E (замечание E-trace-9 / E-KI-10). Разделы выше — исторические, не менялись.

**Источники:**
- `docs/stages/E_catalog_report.md` §1.3;
- `docs/stages/D_spec_questions.md`, раздел «Статусы DQ-01…DQ-03 и INT-01/INT-02 после миграции 0003»;
- `docs/stages/E_test_run.log`. Ссылки «журнал NNNN» ниже — номера строк этого файла.

**Опорные строки журнала:**
- 1307–1311 — `npm run test:all` после ревью E, раунд 2: EXIT=0, 824 passed, 6 skipped. Наборы этапа D: foundation 56, auth 53, admin 44, settings 17, sms 65, e2e 93 (+5 skipped);
- 1315–1316 — `test:cov:d`: 361 passed, 5 skipped, строки 97,92 %;
- 1318 — `auth-smoke` 15/15;
- 1324–1329 — миграции 0001…0007 (с 0003), повторное применение: 0 изменений;
- 1355–1357 — `flutter test` +1237, golden +162, `flutter build windows --release`, всё EXIT=0;
- 1367–1369 — регрессия D на Windows, три серии: `auth_flow_test` +3, `admin_invite_flow_test` +1, `boot_test` +1;
- 1425 и 1433 — свежий прогон автора отчёта E: `trace_test_ids.py` 178 / 155 / 23 / 0; `flutter test` +1237;
- 1375 и 1443 — «Не выполнялось: Android/iOS …, CI на GitHub».

Все прогоны локальные, на Windows, на `FakeOnecGateway`/`FakeSmsGateway` и фикстурах. Отдельно для этого дополнения
2026-10-22 запущен только `python -I -X utf8 scripts/trace_test_ids.py`: EXIT=0, «ID в охвате 178; с тестом 155;
not_done с причиной 23; без теста и причины 0».

### Д.1. Пункты «Что не сделано» (Итог)

| Пункт отчёта D | Статус сейчас | Чем подтверждено |
|---|---|---|
| Android и iOS не проверялись; Kotlin-канал не компилировался | **открыто** | На этапе E Android/iOS не запускались (журнал 1027–1028: «на диске C: ~4,8 ГБ, лицензии Android SDK не приняты»; 1375, 1443). На C: сейчас свободно 3,3 ГБ (`df -h`, 2026-10-22). `BiometricCryptoChannel.kt` есть, сборок `gradlew`/APK в журнале E нет |
| Реальная доставка SMS (SMSPro) | **открыто** | Аккаунта нет (Q-029, RM-A-004). Сквозной путь «API → очередь → pos-worker» проверен только на `FakeSmsGateway`: `pos-api/test/e2e/auth/auth-refinements.e2e-spec.ts` (журнал 1307–1311). T-SMS-018, T-SMS-019 — not_done |
| Видео и скриншоты пути входа | **открыто** | На этапе E не снимались |
| SCR-42 «Устройства/сессии», «Защита входа» | **закрыто (локально, Windows)** с бэклогом | `pos-app/lib/features/settings/{data,domain,presentation}`; `pos-app/test/features/settings/presentation/settings_screen_test.dart` в составе +1237 (журнал 1355, 1433). Бэклог: EQ-DREST-07, EQ-DREST-17, секция принтера скрыта (D-27), языки показаны кодами (E_catalog_report §1.3) |
| `public_settings_provider.dart` (RM-D-015) | **частично** | Файл `pos-app/lib/core/config/public_settings_provider.dart` есть. Тесты `pos-app/test/core/config/public_settings_provider_test.dart` и `pos-app/test/features/admin/presentation/admin_public_settings_test.dart` — в составе +1237 (журнал 1433). Остаток: `customerSelfServiceProvider` (`pos-app/lib/features/registration/registration_providers.dart:52`) по-прежнему читает флаг сборки |
| `docs/integration/smspro_connect.md` | **закрыто документально** | Файл есть. В нём указано, что реальный аккаунт не подключался, а шаги с реальным аккаунтом не выполнялись |
| RM-D-013: вариант C-2 не выбран | **без изменений** (условная задача, в G-D не входит) | Q-031 / ADR-082 действуют |

### Д.2. Отступления и пункты «Что не выполнено» из §1.1

| Задача (пункт) | Было на D | Статус сейчас | Чем подтверждено / что осталось |
|---|---|---|---|
| RM-D-001 (DQ-01: лимиты OTP не в `rate_limit_counters`) | отступление | **закрыто (локально)** | `pos-api/migrations/0003_auth_refinements.sql`: области `otp_ip_10m`, `otp_ip_24h`, `otp_device_10m`, `otp_global_1m`, `otp_verify_ip_10m`, `pin_user_device_10m`. Тесты `pos-api/test/foundation/rate-limit.foundation-spec.ts`, `pos-api/test/e2e/auth/auth-refinements.e2e-spec.ts` (журнал 1307–1311). Оставлено осознанно: adm A-10 (лимиты аварийного кода по аудиту), PR-11 (группы `memory`) |
| RM-D-002 п. 2 (контрактный тест `test=1`) | не выполнен | **открыто** | Нет аккаунта SMSPro |
| RM-D-002 (выход `smspro_connect.md`) | не создан | **закрыто документально** | см. Д.1 |
| RM-D-002 / INT-01 (доставка OTP через pos-worker) | открыт (DQ-16) | **закрыто (локально)** | `AuthModule.withQueuedSms()`; e2e «доставка OTP через очередь pos-worker» в `auth-refinements.e2e-spec.ts`. Остаток EQ-AUTH-08: секрет `otp_pepper` воркеру в `infra/compose.test.yml` (бэклог infra) |
| RM-D-003 (DQ-03: нет реестра step-up `jti`) | отступление | **оставлено осознанно** | Решение «оставлено» в D_spec_questions: привязки к `sid`/`deviceId`/`pv` достаточно. Закрыто миграцией 0003: `refresh_replay`, `locked_at`, `issued_jti`, `sms_outbox.request_id` — `pos-api/test/e2e/auth/sessions.e2e-spec.ts`, `auth-refinements.e2e-spec.ts` (журнал 1307–1311) |
| RM-D-005 п. 3 (маршруты долга и истории клиента) | проверен только на DTO | **открыто** | Маршрутов долга/истории на этапе E не появилось; T-SEC-067 — not_done («этап E/F») |
| RM-D-006 (RL-ADMIN) | не реализован | **закрыто (локально)** | Область `admin_user_1m` (0003); `pos-api/test/admin/admin-rate-limit.admin-spec.ts` (`test:admin` 44, журнал 1307–1311) |
| RM-D-007: `mascot.riv` | заглушка | **открыто** | `pos-app/assets/rive/` отсутствует, `*.riv` в `pos-app` нет; действует Q-035 |
| RM-D-007: AU-04 (сигнал переполнения `PhoneField`) | не реализован | **закрыто (локально)** | `pos-app/test/features/auth/presentation/auth_d_remainders_test.dart` (журнал 1433) |
| RM-D-007: AU-03 (подсказка `devCode`) | не реализован | **частично** | Клиент показывает поле, только если оно пришло. pos-api `devCode` не возвращает, в OpenAPI его нет — на стенде подсказка не появится |
| RM-D-007: AU-16 (`FLAG_SECURE`, SMS User Consent) | не реализован | **частично** | `SecureContent` в `core/session` на всех полях PIN/OTP: `auth_d_remainders_test.dart`, `pos-app/test/features/session_ui/session_gate_test.dart`. На Android не проверено; SMS User Consent не реализован (Q-181) |
| RM-D-007: golden только на Windows | ограничение | **без изменений** | Эталоны по-прежнему Windows (golden +162, журнал 1356); CI не запускался |
| RM-D-008 п. 1, 4 (Android, смена биометрии), сборка Kotlin | не выполнены | **открыто** | см. Д.1; T-BIO-003, T-BIO-006, T-BIO-007 — not_done. ADR-087 — «РЕШЕНИЕ (предложено)» (`15_DECISION_LOG.md`) |
| RM-D-009: SCR-42 | не реализован | **закрыто (локально)** | см. Д.1 |
| RM-D-009 п. 3 (сквозной e2e отзыва против pos-api) | только фейковый HTTP | **открыто** | Отдельного integration-теста «отзыв сессии → SCR-90 C» против pos-api в журнале E нет |
| RM-D-010 п. 2 (golden SCR-45) | нет | **закрыто (локально, Windows)** | `pos-app/test/features/admin/golden/admin_users_golden_test.dart` — 3 брейкпоинта; golden +162 (журнал 1356) |
| RM-D-010 п. 3 (`integration_test` «приглашение в UI → вход») | нет | **закрыто (локально, Windows), нестабилен** | `pos-app/integration_test/admin_invite_flow_test.dart`. Раунд 1: один запуск из двух упал в `tearDownAll` (журнал 1202–1209). Раунд 2: 3/3 зелёные (журнал 1367–1369). Причина (`ScannerConfigController._load` после закрытия БД, E-KI-02) не устранена |
| RM-D-011 п. 1 (25 ID not_done) | 25 | **частично: 23** | Тесты этапа E закрыли два ID: T-SEC-027 (поиск, частично; sqlmap — этап H) и T-SEC-046 (`pos-api/test/images/caddyfile.spec.ts`, `image-security.spec.ts`). Остальные 23 not_done с причиной: этапы F/H, CI, устройство, SMSPro, P2/P3. Запуск 2026-10-22, журнал 1425 |
| RM-D-011 п. 3 (доставка на реальный номер) | не проверена | **открыто** | Нет аккаунта SMSPro |
| RM-D-012: Android, видео, compose + Caddy | не выполнены | **открыто** | Android — см. Д.1. Docker на машине нет (`command -v docker` — пусто). Регрессия Windows-пути зелёная (журнал 1367–1369) |
| RM-D-014: офлайн-сигнал экранов входа (AU-14) | порт по умолчанию `false` | **открыто** | `pos-app/lib/features/auth/auth_providers.dart:38`: `authOfflineSignalProvider` по-прежнему `(ref) => false` |
| RM-D-015 п. 2 (часть: `PUT /admin/settings` → `VALIDATION_FAILED`) | маршрута нет | **открыто** | Контроллера `/admin/settings` в `pos-api/src` нет (`grep` находит только тест read-only guard и комментарии в `public-settings.map.ts`) |
| RM-D-015: Flutter-часть | не выполнена | **частично** | см. Д.1 |
| RM-D-015 п. 4 (widget SCR-39/SCR-46) | экранов нет | **открыто** | SCR-39/SCR-46 — задачи последующих этапов |
| RM-D-016 (`admin_code` не в `sessions.amr`) | отступление | **закрыто (локально)** | 0003: `sessions_amr_chk` + `admin_code`; `pos-api/test/e2e/auth/emergency-login.e2e-spec.ts`. В ответах API `admin_code` отфильтрован: enum OpenAPI не менялся (EQ-AUTH-02) |
| INT-02 (первый `admin` на пустой БД) | только фикстуры | **закрыто (локально)** | `pos-api/scripts/bootstrap-admin.ts`, `docs/ops/first_admin.md`, `pos-api/test/admin/bootstrap-admin.admin-spec.ts`. На staging/prod не выполнялся |

**Известные проблемы §3, не перечисленные выше:**
- D-KI-08 (нет повторной независимой проверки исправлений D_review): **открыто**. Ревью E (`docs/reviews/E_review.md`) проверяло код этапа E, в том числе SCR-42, SCR-45 и защиту экрана. Повторной проверки исправлений D-MJ-01, D-MJ-02, D-MN-01…08 в нём нет.
- D-KI-10 (`applicationId` = `com.example.optomstroy`): **открыто**, см. `pos-app/android/app/build.gradle.kts`, строки 9 и 24.
- D-KI-11: Linux-эталоны и CI не проверялись — **открыто**. По E-trace-5 CI не запускает наборы этапа E и миграции 0003+.
- D-KI-07: **частично**. Лимиты OTP, RL-PIN, RL-ADMIN и `jti` повтора verify перенесены в PostgreSQL (0003). Кэши denylist и «PIN установлен», breaker OTP и группы `memory` остаются в памяти процесса.

### Д.3. Пересмотр ворот G-D

**Статус G-D: красный (без изменений).** Условие ворот (13 §3.4) требует закрыть RM-D-001…009, 014, 015, 016, 017.

| Условие | Было | Сейчас | Что держит |
|---|---|---|---|
| RM-D-001, 003, 004, 005, 006, 007, 014, 016, 017 | да (локально), с оговорками | да (локально). Отступления RM-D-001, 006, 016 сняты миграцией 0003 | Оговорки остаются: RM-D-005 п. 3 (маршрутов долга нет), RM-D-007 (`mascot.riv`, AU-03, AU-16 на Android), RM-D-014 (AU-14) |
| RM-D-002 | нет | **нет** | п. 2: контрактный тест SMSPro `test=1` — нет аккаунта (Q-029, RM-A-004). Инструкция и доставка через worker закрыты |
| RM-D-008 | нет | **нет** | п. 1, 4 на Android и сборка Kotlin-канала: эмулятор не запускается (место на C:, лицензии SDK), устройства нет (RM-A-008). ADR-087 «предложено» |
| RM-D-009 | нет (SCR-42) | **нет** | SCR-42 закрыт локально. Нет сквозного e2e отзыва против pos-api (п. 3) |
| RM-D-015 | нет | **нет** | `PUT /admin/settings` отсутствует (п. 2, часть); `customerSelfServiceProvider` берёт флаг сборки; п. 4 — экранов SCR-39/46 нет |
| RM-D-010 (вне формального списка) | нет | **да (локально, Windows)** с оговоркой | `admin_invite_flow_test` нестабилен (E-KI-02) |
| RM-D-011: все T-AUTH/REG/SESS/SMS запущены | нет (25 not_done) | **нет** (23 not_done с причиной) | SMSPro, устройство, P3 без теста (T-AUTH-025, T-REG-008, T-SESS-012 и др.) |
| RM-D-012: Android, видео | нет | **нет** | Android и видео — нет; compose + Caddy — Docker нет |
| 0 блокеров/критичных по безопасности | да | да | D-KI-08 (повторная проверка исправлений D) открыт |

**Что ещё держит G-D красным:**
1. **RM-D-008 (Android)** — внешний блокер окружения. Нужно освободить место на C: и принять лицензии Android SDK либо дать устройство Android Class 3 (RM-A-008).
2. **RM-D-002 п. 2 (SMSPro)** — нужен тестовый аккаунт SMSPro (Q-029, RM-A-004).
3. **RM-D-015** — нужен маршрут `/admin/settings` и чтение `features.customerSelfService` с сервера в registration.
4. **RM-D-009 п. 3** — нужен сквозной тест отзыва сессии против pos-api.
5. **RM-D-012** — путь на Android и видео/скриншоты.

Пункты 3–4 зависят только от разработки. Пункты 1, 2 и 5 упираются в окружение и заказчика.

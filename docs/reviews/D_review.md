# Независимая проверка этапа D «Authentication»: безопасность и соответствие ТЗ (QA + SEC)

Дата: 2026-10-22. Проверяющий: независимый агент QA + SEC (13 RM-D-012).
Машина: Windows 11 Pro 10.0.26200, Node 24.11.1, Flutter 3.38.7. Android-устройства и macOS нет.

Код при проверке не менялся. Записан только этот отчёт.

Основание проверки:
- 09_AUTH_SMS_BIOMETRICS;
- 11_SECURITY_PRIVACY: §4.3–§4.4, §7.2;
- 12_TEST_PLAN: T-AUTH, T-REG, T-SESS, T-SMS, T-BIO и T-SEC класса A;
- 13 §3.4: RM-D-001…017;
- ядро R0 v1.9: §24.2, D-07, D-10, D-12, D-13, D-47, D-48;
- контракт `contracts/openapi/pos-api.v1.yaml`.

**Вердикт.**
- Ворота G-D по безопасности: **жёлтые**. Блокеров и критичных дефектов безопасности нет. Основные механизмы реализованы по ТЗ и подтверждены тестами, которые я сам перезапустил: OTP, JWT, refresh, step-up, PIN, RBAC, аудит, логи.
- Ворота G-D по полноте: **красные**. Не работает вход по аварийному коду (RM-D-016, D-MJ-01). Не выполнены проверки на устройствах (D-MJ-03). Не хватает трассировки тестов к 12 (D-MJ-02).

## 1. Повторный запуск и сверка с `docs/stages/D_test_run.log`

| Команда (мой запуск 2026-10-22 ≈05:00–05:17) | Мой результат | D_test_run.log | Совпадает |
|---|---|---|---|
| `pos-api: npm test` | 12 файлов, 126 passed, exit 0 | 126 | да |
| `npm run test:auth` | 2 / 35 passed, exit 0 | 35 | да |
| `npm run test:registration` | 1 / 18 passed | 18 | да |
| `npm run test:customers` | 2 / 28 passed | 28 | да |
| `npm run test:profile` | 2 / 24 passed | 24 | да |
| `npm run test:admin` | 3 / 36 passed | 36 | да |
| `npm run test:sms` | 4 / 65 passed | 65 | да |
| `npm run test:settings` | 2 / 17 passed | 17 | да |
| `npm run test:foundation` | 6 / 55 passed | 55 | да |
| `npm run test:integrations` | 5 / 38 passed | 38 | да |
| `npm run test:e2e` | 5 файлов, 62 passed, 4 skipped (`runIf(VIA_PROXY)` в smoke) | 62 + 4 skipped | да |
| `npm run test:cov:d` | 25 файлов, 301 passed, 4 skipped; All files: строки 96.12 %, ветви 81.49 %; `otp.service.ts`: строки 97.88 %, ветви 87.17 % | 301; строки по модулям ≥ 90 % | да |
| `pos-app: flutter test` | +696 All tests passed, exit 0 | 696 | да |
| `scripts/check_layers.py` | 213 файлов, 1241 импорт, 0 нарушений | 0 | да |

Сам я не запускал:
- `test:worker`, `test:db`, lint, build;
- golden-тесты, `integration_test` на Windows, `flutter build windows`;
- local-stack smoke и auth-smoke.

Для них результат взят из журнала и мной не подтверждён.

## 2. Что проверено и соответствует ТЗ

| Требование | Где | Итог |
|---|---|---|
| Нейтральный ответ `/auth/otp/request`, нет оракула существования номера | `otp.controller.ts`: `findByPhone` выполняется для любого номера, результат пишется только в `otp_challenges.user_id`. Лимиты и cooldown одинаковы для всех номеров. Ветвление `branch()` — только после верного кода. Заблокированный аккаунт отвечает 403 тоже только после верного кода. Тесты T-AUTH-011/045/027 | соответствует |
| OTP: CSPRNG, HMAC-SHA-256 + pepper с версией, константное сравнение | `random.ts`: `randomInt`. `otp-hmac.service.ts`: HMAC от `challenge_id:code`, `timingSafeEqual`. В БД только HMAC (T-AUTH-013) | соответствует |
| Попытки, блокировки, одноразовость | Попытка учитывается до сравнения, строка блокируется `FOR UPDATE`. Переход `sent → verified` атомарный. 6-я попытка → 423. DEVICE_MISMATCH расходует попытку. Повтор ≤ 60 с — только тот же device и неиспользованная сессия (T-AUTH-003/005/006/020) | соответствует |
| Лимиты D-10 | Cooldown 60 с; 3 за 15 мин и 10 в сутки на номер (номер хранится HMAC-псевдонимом); лимиты IP и устройства; глобальный лимит с circuit-breaker. Счётчики в PostgreSQL (T-AUTH-014…018) | соответствует |
| JWT EdDSA/ES256, `kid` | `jwt.service.ts`. Allowlist алгоритмов, `alg` привязан к ключу `kid`. Отказ при `alg=none`, HS256-confusion, неизвестном или отсутствующем `kid`, чужой подписи, `iss`/`aud`. Ротация `kid`. Токены назначения нельзя подменить друг другом (`jwt.foundation-spec.ts`, 11 кейсов) | соответствует |
| Refresh | 256 бит, хранится SHA-256. CAS-ротация. Грация 30 с. При reuse отзывается вся семья с аудитом `session.reuse_detected` (critical). Привязка к `device_key`: чужое устройство → отзыв (T-SESS-004…009, 023) | соответствует |
| Step-up | JWT `purpose=step_up` на 15 мин. Claims: `sid`, `deviceId`, `pv`, `scope=[operation]`. Многоразовый в своей области. Проверяется denylist. `logout-all` гасит `jti` (T-SESS-016, admin-spec) | соответствует (см. D-MN-01) |
| Unlock и PIN на сервере | `/auth/unlock` публичный, нужны refresh и PIN. Argon2id: m = 19 MiB, t = 2, p = 1, pepper с версией, материал `pepper‖pin‖user_id`. Попытки 1–4 → 401 `PIN_INVALID {attemptsLeft}`, сессия жива. 5-я → 423 `PIN_LOCKED` (канон BIO-020). Блокировку снимает OTP-вход. Windows staff без разблокировки получает `UNLOCK_REQUIRED` | соответствует |
| Приглашения | Роль берётся только из `user_invitations` (`FOR UPDATE`, `accepted`). Приглашать можно только seller, cashier, senior_seller. `ValidationPipe` настроен с `whitelist` и `forbidNonWhitelisted`: лишние поля (`role` и др.) → 400 | соответствует |
| Регистрация | Без приглашения создаётся только `customer`. При `CUSTOMER_SELF_SERVICE=false` — staff в статусе `pending_activation` без ролей. Телефон берётся из челленджа, не из запроса. `registration_token` гасится через `token_denylist` в транзакции и привязан к устройству и хэшу | соответствует (см. D-MN-02) |
| Привязка клиента | До `confirmed` клиент видит только маскированное имя карточки. Самоподтверждение разрешено только при verified-основном телефоне, не для юрлица и без конфликтов (SEC-130). Админ подтверждает со step-up. IDOR → 404 | соответствует для реализованных маршрутов (см. D-MN-07) |
| RBAC | Deny by default: маршрут без политики → 403. Object-level правила (`target-policy.ts`, сессии через `findOwn` → 404) | соответствует (см. D-MN-05) |
| Аудит | Хэш-цепочку считает триггер. `UPDATE audit_logs` под ролью приложения отклоняется (тест). Санитайзер вырезает OTP, PIN, токены, HMAC; телефон маскируется до `+996 *** ** NN`, ФИО — до инициалов | соответствует |
| Логи | Redaction в pino до записи. Заголовки Authorization и X-Step-Up-Token скрыты. Коды и телефоны в тексте маскируются. SMS-пароль берётся из `*_FILE`. В Fake/SMSPro-логах нет кода. В prod запрещены test-mode, fake-SMS, `debug`. Тест T-AUTH-040 | соответствует |
| Flutter: токены | Access-токен только в памяти (`TokenStore`). Refresh-токен и `deviceId` — в `flutter_secure_storage`, iOS `first_unlock_this_device`, Android `allowBackup=false`. На `PIN_INVALID`/`PIN_LOCKED` refresh не вызывается. Single-flight refresh | соответствует (см. D-MN-04) |
| Flutter: platform channel биометрии | Android: AES-GCM в Keystore, `setUserAuthenticationRequired(true)` + `setUserAuthenticationParameters(0, BIOMETRIC_STRONG)` (без окна валидности), `setInvalidatedByBiometricEnrollment(true)`. Шифрование и расшифровка только через `CryptoObject` в `onAuthenticationSucceeded`. iOS: `.biometryCurrentSet` + `WhenPasscodeSetThisDeviceOnly` | код соответствует D-13; на устройствах не проверено (D-MJ-03) |
| Экраны и тексты | В presentation-слоях auth, registration, admin, session нет захардкоженных строк, кроме имени бренда в `auth_logo.dart`. SCR-08 не показывает и не хранит телефон | соответствует |

## 3. Замечания

### Существенные (major)

**D-MJ-01. Вход по аварийному коду не встроен в поток входа (RM-D-016 п. 2–4, 09 SMS-035, AC-AUTH-086).**

Что есть:
- `EmergencyLoginCodeService` создаёт челлендж `login_or_register` со статусом `sent` и `device_key = NULL`.
- Он экспортирует порт `findLiveForPhone`, `bindDevice`, `recordUsed`.

Чего нет:
- Модуль `auth` этот порт не использует: в `src/auth` нет ни одного упоминания emergency и `admin_code`.

Что из этого следует:
- `POST /auth/otp/request` сотрудника идёт в `OtpService.issue`. В первые 60 с он получает 429 `OTP_RATE_LIMITED`: аварийный челлендж засчитывается в cooldown. Позже `retireActive` переводит аварийный челлендж в `superseded` и отправляет SMS, хотя SMS как раз недоступны.
- Клиент не получает `challengeId` аварийного кода.
- Прямой `verify` по `challengeId` даёт `DEVICE_MISMATCH`, потому что `NULL ≠ X-Device-Id`.
- Не реализованы: `amr=["admin_code"]`, `unlocked_until = now()`, аудит `auth.emergency_code.used`.
- Тест `emergency-code.admin-spec.ts` проверяет порт отдельно, а не вход.

Ворота G-D требуют закрытой RM-D-016.

Исправление:
- В `OtpController.request`/`OtpService.issue`: если по номеру есть живой аварийный челлендж — `bindDevice` и ответ 202 с его `challengeId`, без SMS, без `retireActive` и без cooldown.
- В `LoginService` — `recordUsed`, `amr admin_code`, `unlocked_until = now()` при установленном PIN, снятие `PIN_LOCKED`.
- e2e: выдача → request → verify → повтор отклоняется → через 10 мин отклоняется.
- CHECK `sessions_amr_chk` расширить по A-09.

**D-MJ-02. Трассировка тестов к 12 неполная (RM-D-011 п. 1: «все T-AUTH/REG/SESS/SMS из 12 запущены»).**

Из 132 ID T-AUTH/REG/SESS/SMS/BIO в 12 на 60 нет ни одной ссылки в тестах backend и Flutter:
- T-AUTH-008/009/010/019/023–025/029–035/037–039/041–043;
- T-REG-004/008/013/014/019/020/023/025/026;
- T-SESS-001/002/012/017/018/021/022;
- T-SMS-002/005/008/010–013/015–020;
- T-BIO-001/003–007/010/013/014/017/018.

Среди них есть P1 e2e и integration:
- T-AUTH-019 — счётчики переживают рестарт;
- T-AUTH-029 — смена номера;
- T-SESS-017 — полнота аудита `auth.*`;
- T-BIO-013 — сброс PIN.

Из T-SEC класса A по ID прослеживаются только T-SEC-043 и T-SEC-044. T-SEC-002…005, 009, 010, 013, 020, 021, 045 по сути покрыты тестами без ID (jwt.foundation, sessions/otp e2e, admin-spec). Не найдено тестов на:
- T-SEC-008 в полном объёме: grep HMAC и текста SMS по логам и трассам; есть только T-AUTH-040;
- T-SEC-018: декларация прав всех маршрутов;
- T-SEC-038: полнота аудита.

Исправление: матрица «ID 12 → тест/файл или `not_done` с причиной» в `D_test_run.log` или в отчёте этапа; недостающие P1-тесты дописать.

**D-MJ-03. Не выполнены проверки на устройствах (RM-D-008 п. 1, 4; RM-D-012; RM-D-011 п. 3).**

Не проверено:
- Android: токен недоступен без BiometricPrompt; инвалидация ключа при смене биометрии;
- iOS: канал в `AppDelegate.swift` не собирался и не запускался (нет macOS);
- путь «Splash → … → каталог» на Android;
- доставка SMS на реальный номер (RM-A-004).

В журнале это честно помечено как «не проверено». Для закрытия ворот нужен протокол на устройстве или эмуляторе (13 §3.4, риски).

### Незначительные (minor)

**D-MN-01. Проверка `X-Step-Up-Token` реализована трижды и по-разному.**

Три реализации:
- `auth/step-up/step-up.service.ts` — полная проверка: `sub`, `sid`, `deviceId`, `pv`, `scope`, `method`, denylist;
- `admin/users/shared/step-up.guard.ts` — не проверяет `pv`; принимает токен без claim `deviceId`; `scope` допускает строкой;
- `customers/links/step-up.verifier.ts` — не проверяет `pv` и `method` (неизвестный метод считается `pin`); `scope` допускает строкой через пробел.

Сейчас это не эксплуатируется: смена ролей и блокировка отзывают все сессии (`revokeAllForUser`), а `sid` проверяется. Но любое будущее `permissions_version++` без отзыва сессий (например, лимиты скидок — комментарий в `users.repository.ts`) оставит старый step-up действующим в admin и customers. Это расходится с RM-D-003 п. 3.

Исправление: один `StepUpService.verify` (или общий guard) во всех модулях.

**D-MN-02. Идемпотентный повтор `POST /registration/complete` выпускает новую пару токенов без проверки, что сессия не использовалась.**

Где: `registration.service.ts`, `replay` и `respond`.

`inspect` не смотрит `token_denylist`. Поэтому в течение 15 мин TTL `registration_token` повтор с тем же `Idempotency-Key` и `X-Device-Id` каждый раз ротирует refresh сессии, даже после её использования. Для сравнения, повтор `verify` по 09 §5.6 разрешён только для неиспользованной сессии (`rotated_at`/`last_used_at`) и только один раз.

Последствия:
- «одноразовость» `registration_token` фактически ослаблена до 15 мин;
- легитимный refresh вытесняется (возможен ложный reuse и отзыв семьи).

Исправление: при повторе требовать `rotated_at IS NULL AND last_used_at IS NULL` и не более одного повтора; иначе 409/`SESSION_REVOKED`.

**D-MN-03. In-memory лимиты `AuthHttpRateLimiter` сбрасываются.**

`prune(now, windowMs)` при 50 000 ключей удаляет корзины по окну **текущей** группы. 1-минутный `publicIp`/`authDevice` стирает 10-минутные RL-PIN, RL-OTP-VERIFY, RL-OTP-STATUS. Ключи — это `X-Device-Id`, который выбирает атакующий, так что переполнение достижимо. Основная защита (`app_pins.failed_attempts`, `otp_challenges.attempts`) в PostgreSQL не страдает.

Ещё: ключи RL-PIN разные — `userId:deviceKey` в step-up и `deviceKey` в unlock.

Исправление: хранить окно в самой корзине; единый ключ RL-PIN.

**D-MN-04. Flutter: при выходе и `SESSION_REVOKED` не удаляется `biometric_refresh`.**

Ни шифртекст в SharedPreferences/Keychain, ни ключ Keystore не удаляются. `sessionCleanupHooksProvider` пуст, очищает только `switchAccount`. На сервере биометрическая семья при logout отзывается, так что секрет «мёртвый», но остаётся на устройстве (ср. BIO-012/014 — удаление ключа при выключении).

Исправление: хук очистки `BiometricCryptoChannel.clear` в `_clearLocal` и `_endSession`.

**D-MN-05. RBAC-матрица (RM-D-006 п. 1) неполная.**

Тест строит матрицу из `x-roles` контракта только для `/admin/users*` и `/admin/invitations*`. Нет полной матрицы «эндпоинт × роль» из `permissions.yaml` для auth, profile, registration и customers. Нет проверки «`owner`/`admin` без кассовых операций» (в тесте явно сказано, что это не проверяется).

**D-MN-06. RM-D-001 п. 1 («100 % веток политики») формально не выполнен.**

Ветви: `otp.service.ts` — 87.17 %, `step-up.service.ts` — 62.9 %, `otp.provider.ts` — 61.81 %. Порог RM-D-011 (≥ 80 % строк) выполнен.

**D-MN-07. T-REG-019 и T-SEC-055 нельзя выполнить: маршрутов с финансами клиента ещё нет.**

RM-D-005 п. 3 проверен только на DTO `customer-match`. Финансовые маршруты — `GET /customers/{id}`, `/receivables`. Нужно перепроверить на этапах E/F.

**D-MN-08. Android: нет `android:dataExtractionRules`.**

Для Android 12+ `allowBackup=false` не отключает перенос device-to-device. Ключи Keystore не переносятся, так что риск низкий.

Также `applicationId`/пакет `com.example.optomstroy` — заготовка.

**D-MN-09. Многопроцессные ограничения (известны, A-15, D-45).**

Всё перечисленное ниже — только в памяти процесса:
- memo `jti` для отзыва при повторе `verify`;
- `AuthStateCache.denyJti`;
- кэш PIN в `SessionActivityGuard`.

При второй реплике отзыв срабатывает с задержкой до 60 с или 15 мин. Допустимо для R1 с одной репликой; нужен вопрос к владельцу 07.

## 4. Не проверено мной (not_done)

- Android и iOS на устройствах (D-MJ-03).
- `integration_test` на Windows, golden-тесты, local-stack и auth-smoke: не перезапускались, результат взят из журнала.
- Визуальное соответствие экранов SCR-00…08, SCR-45, SCR-90 разделу 02: не сверялось построчно по состояниям. Проверены только отсутствие захардкоженных строк и правило «SCR-08 без телефона».
- Неизменность `pubspec.yaml` и `package.json`: файлы не отслеживаются git (`??`), поэтому diff невозможен.

## 5. Итог для ворот G-D

| Ворота G-D | Статус |
|---|---|
| 0 блокеров/критичных по безопасности | выполнено |
| RM-D-011: все тесты зелёные, покрытие ≥ 80 % | выполнено (перезапуск совпал с журналом) |
| RM-D-011: все T-AUTH/REG/SESS/SMS из 12 | не выполнено (D-MJ-02) |
| RM-D-016 закрыта | не выполнено (D-MJ-01) |
| RM-D-008/012: устройство Android, видео/скриншоты | не выполнено (D-MJ-03) |

## 6. Статусы замечаний после исправления (2026-10-22, агент исправлений)

Исправления — в `pos-api/**`, `pos-app/**`, `scripts/trace_test_ids.py`. Повторный прогон всех проверок — раздел
«ПОВТОРНЫЙ ПРОГОН ПОСЛЕ ИСПРАВЛЕНИЙ ЗАМЕЧАНИЙ D_review.md» в конце `docs/stages/D_test_run.log`. Новые пробелы ТЗ —
`docs/stages/D_spec_questions.md`, раздел «Исправление замечаний проверки этапа D» (FX-01…FX-11). Ничего не коммитилось.

| Замечание | Важность | Статус | Что сделано | Подтверждение |
|---|---|---|---|---|
| D-MJ-01 вход по аварийному коду | major | **исправлено** (с отступлением FX-01) | `src/auth/login/emergency-login.service.ts`, `src/auth/otp/emergency-challenges.repository.ts`: `/auth/otp/request` при живом коде администратора → 202 с его `challengeId` без SMS, без cooldown и `retireActive` (в т. ч. при открытом breaker), привязка к `X-Device-Id`; другое устройство → 409 `DEVICE_MISMATCH`. `LoginService`: только активный staff-владелец кода; access-JWT `amr=["admin_code"]`; при установленном и не заблокированном PIN `unlocked_until=now()` и любой запрос кроме `/auth/*` → 401 `UNLOCK_REQUIRED` (`SessionActivityGuard`, FX-02) → `/auth/unlock` → `["admin_code","pin"]`; `PIN_LOCKED` снимается; аудит `auth.emergency_code.used` (sid, deviceId, amr) и `auth.login amr=[admin_code]`; ротация сохраняет `admin_code`. Порт-дубль из admin удалён. CHECK `sessions_amr_chk` **не расширен**: миграция меняет `docs/erd/schema_v1.sql` и CI вне путей исправления — `admin_code` хранится в JWT/аудите, признак — `created_from_challenge_id` + аудит выдачи (FX-01) | `test/e2e/auth/emergency-login.e2e-spec.ts` (6 сценариев: выдача → request → verify → UNLOCK_REQUIRED → unlock → refresh; повтор → OTP_EXPIRED; D2 → 409; через 10 мин → OTP_EXPIRED и обычная SMS; PIN заблокирован; заблокированный → 403); `test/admin/emergency-code.admin-spec.ts` (T-ADMIN-010 а, б, д, е, ж) |
| D-MJ-02 трассировка к 12 | major | **исправлено** (кроме ручных/приборных/последующих этапов) | `scripts/trace_test_ids.py` — матрица «ID 12 → тест или not_done с причиной» (T-AUTH/REG/SESS/SMS/BIO + T-SEC класса A + T-ADMIN-010), код 1 при ID без теста и причины. Новые тесты: T-SESS-001, T-SESS-002, T-AUTH-019 (перезапуск pos-api на той же БД), T-AUTH-042, T-SESS-017/T-SEC-038 (`test/e2e/auth/tokens-audit.e2e-spec.ts`), T-SEC-008 полностью (HMAC и текст SMS — `otp.e2e-spec.ts`), T-SEC-018/019 и HTTP-матрица (`test/e2e/rbac-matrix.e2e-spec.ts`), T-BIO-013 (`profile.profile-spec.ts`), T-SMS-017 (шаблон без `{code}` → ошибка конфигурации, `env.schema.ts`), T-BIO-018/T-SESS-022 (`pos-app/test/build/android_build_config_test.dart`). Существующие тесты помечены ID (T-SEC-001…007, 009, 010, 012, 013, 015, 016, 020, 021, 024, 025, 028, 029, 030, 044, 045, 050; T-SMS-002, 005, 008, 010–013, 016, 020; Flutter T-AUTH-008/010/023/024/031/032/034/035/037/039/041, T-REG-004/013/023/025, T-BIO-004/010/014 и др.) | `trace_test_ids.py`: 178 ID в охвате — 153 с тестом, 25 not_done с причиной, 0 без теста и причины (код 0); матрица целиком — в D_test_run.log |
| D-MJ-03 проверки на устройствах | major | **не исправлено** (блокер окружения) | Эмулятор `Pixel_9_Pro` (android-36) есть, но не стартует: `FATAL | Your device does not have enough disk space to run avd` — на C: свободно 1,02 ГБ (AVD, SDK и `~/.gradle` 3,2 ГБ на C:). Сборка APK по той же причине не запускалась. macOS нет. Реальные SMS — нет аккаунта SMSPro (RM-A-004). Освобождать или переносить данные пользователя агент не вправе (FX-07) | журнал эмулятора в D_test_run.log |
| D-MN-01 три проверки step-up | minor | **исправлено** | Единая `StepUpTokenVerifier` (`src/auth/step-up/step-up-token.verifier.ts`): sub, sid, deviceId (обязателен), `pv`, `scope` только массив, `method` ∈ разрешённых, denylist. `StepUpService.verify`, `AdminStepUpGuard`, customers `StepUpVerifier` — тонкие обёртки | `admin-users.admin-spec.ts` T-SEC-045 (+ устаревший `pv`, без `pv`, без `deviceId`, `scope` строкой, без `method`); admin/customers/profile/e2e зелёные |
| D-MN-02 повтор `/registration/complete` | minor | **исправлено** | Повтор — один раз и только при `rotated_at`/`last_used_at`/`grace_used_at` = NULL (строка сессии `FOR UPDATE`), ротация «в сторону» (`superseded_refresh_hash`), прежний access `jti` (хранится в `idempotency_keys`, без токена) → `token_denylist`; иначе 409 `PHONE_ALREADY_REGISTERED` `reason=registration_replay_used` (FX-04). Тестовый стенд регистрации получил `SessionActivityGuard`, как в AppModule | `registration.registration-spec.ts` «T-REG-012 / ревью D-MN-02» |
| D-MN-03 in-memory лимиты | minor | **исправлено** | Корзина хранит своё окно, очистка — по нему; RL-PIN — единый ключ `userId:deviceKey` (unlock считает попытку в RefreshService после нахождения сессии) | `test/auth/otp-policy.spec.ts` «ревью D-MN-03» (50 000 ключей RL-PUBLIC-IP не сбрасывают RL-PIN) |
| D-MN-04 biometric_refresh после выхода | minor | **исправлено** | `sessionCleanupHooksProvider` по умолчанию вызывает `BiometricAuthenticator.clear` (ключ Keystore/Keychain и шифртекст) при logout, logout-all и серверном завершении (`_clearLocal`) | `pos-app/test/core/session/session_flow_test.dart` «ревью D-MN-04 (T-BIO-012)» |
| D-MN-05 RBAC-матрица | minor | **исправлено** | `test/e2e/rbac-matrix.e2e-spec.ts` на полном AppModule: (1) у каждого маршрута политика, коды ⊆ `x-permissions`; (2) весь контракт: `x-roles` ⇔ права permissions.yaml (явный список объектных сужений), owner/admin без кассовых операций; (3) HTTP 36 операций этапа D × 6 ролей = 216 ячеек. Найдено и исправлено: staff на `DELETE /me/pin` получал STEP_UP_REQUIRED вместо 403 `pin_required_for_staff` (FX-10) | rbac-matrix 3/3 |
| D-MN-06 100 % веток политики | minor | **исправлено** | `test/auth/otp-branches.spec.ts` (16 unit-тестов): ветви OtpService.issue/check, SmsOtpProvider, StepUpService.request | `test:cov:d`: `otp.service.ts`, `otp.provider.ts`, `step-up.service.ts` — 100 % строк и ветвей |
| D-MN-07 T-REG-019 / T-SEC-055 | minor | **перенесено** на этапы E/F | Финансовых маршрутов клиента ещё нет; часть D помечена в `customer-links.e2e.spec.ts`, остаток — not_done в матрице | — |
| D-MN-08 Android backup / applicationId | minor | **частично** | `android:dataExtractionRules` + `res/xml/data_extraction_rules.xml` (облачная копия и device-to-device исключены по всем доменам). `applicationId` не менялся — идентификатор заказчика в ТЗ не задан (FX-08). Сборка на устройстве не проверена (D-MJ-03) | `android_build_config_test.dart` |
| D-MN-09 многопроцессность | minor | **задокументировано** как ограничение R1 | FX-11 в D_spec_questions; для регистрации `jti` повтора теперь в БД (D-MN-02) | — |

**Итог для ворот G-D после исправлений:** 0 blocker/critical; RM-D-016 закрыта (с отступлением FX-01 до решения владельца 07); RM-D-011 п. 1 — матрица без пропусков (ручные/приборные/последующие этапы — not_done с причиной); RM-D-008/012 на устройстве — **не выполнено** (D-MJ-03, нехватка места на диске C:).

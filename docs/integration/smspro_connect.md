# Подключение SMSPro Nikita KG (smspro.nikita.kg)

**Назначение.** Инструкция для эксплуатации и заказчика: как подключить SMS-шлюз для кодов входа (OTP), проверить
его без трат и без реальных SMS, выполнить первый реальный тест и наблюдать за работой.
Выход RM-D-002; закрывает D-KI-04 и DQ-28 / SMS-Q-13.

**Основание:**

- 09_AUTH_SMS_BIOMETRICS §5.8 (тестовый режим), §6 (протокол, коды, DLR, баланс, §6.11 конфигурация, §6.12 что
  предоставляет заказчик, §6.13 недоступность SMS);
- 16_DEPLOYMENT_PLAN §4.3–§4.4 (переменные и секреты `*_FILE`);
- исследование `docs/research/R2_SMSPRO_RESEARCH.md` (§3–§5, §8–§10).

**Статус проверки:**

- адаптер проверен на XML-фикстурах и локальном mock-сервере: `pos-api/test/sms/*`, `test:sms`;
- сквозной путь «API → очередь → pos-worker» проверен на `FakeSmsGateway`:
  `pos-api/test/e2e/auth/auth-refinements.e2e-spec.ts`.

**Реальный аккаунт SMSPro не подключался:** учётных данных нет (Q-029, RM-A-004). Шаги §4–§5 ниже ещё не
выполнялись.

> В этом документе нет и не должно быть реальных логинов, паролей, номеров и API-ключей. Номера в примерах —
> синтетические `+996700000001…09` (09 §5.8).

---

## 1. Как устроена отправка

```text
приложение ──POST /auth/otp/request──▶ pos-api ──(одна транзакция)──▶ otp_challenges + sms_outbox(queued)
                                                              └──▶ задание pg-boss `sms.send` (текст зашифрован)
pos-worker ──`sms.send`──▶ SMSPro POST /api/message ──▶ sms_outbox(sent|failed), повторы по 09 §6.4
pos-worker ──`sms.dlr_poll`──▶ POST /api/dr (отчёт о доставке, 30 с / 2 мин / 10 мин)
pos-worker ──`sms.balance_poll` (каждые SMSPRO_BALANCE_POLL_MINUTES)──▶ POST /api/info (баланс, состояние)
```

Как это работает:

- **pos-api не ходит в SMSPro.** Ответ `202` на `/auth/otp/request` нейтрален и не ждёт шлюза: SMS отправляет
  pos-worker (09 §6.8; 06 §7.5; INT-01 — с этапа E вариант по умолчанию, `AuthModule.withQueuedSms()`).
- **Канал заведомо недоступен** — открыт circuit-breaker после `CONFIG_ERROR` или `INSUFFICIENT_FUNDS` либо больше
  50 % `RETRYABLE` за минуту. Тогда запрос кода получает синхронный `503 SMS_PROVIDER_ERROR`.
- **Неудачная доставка** (`failed`) переводит код в `failed_delivery` и возвращает квоту лимита номера (09 §6.8).
- **Текст SMS** с кодом хранится только в задании, в зашифрованном виде: AES-256-GCM, ключ выводится из
  `OTP_HMAC_SECRET`. В БД, логах и аудите кода нет (SEC-062, SEC-078).

**Следствие:** секрет `OTP_HMAC_SECRET_FILE` должен быть подключён и к `api`, и к `worker`, и у обоих совпадать.
По 16 §4.3 сейчас указано «только api» — вопрос EQ-AUTH-08 в `docs/stages/E_spec_questions.md`.

## 2. Что нужно от заказчика (09 §6.12)

| Что | Куда | Как передать |
|---|---|---|
| Логин аккаунта SMSPro | секрет `smspro_login` → `SMSPRO_LOGIN_FILE=/run/secrets/smspro_login` | заказчик сам вносит файл на сервере (права 600); не в чат и не в e-mail |
| Пароль (это пароль от личного кабинета с деньгами) | секрет `smspro_password` → `SMSPRO_PASSWORD_FILE=/run/secrets/smspro_password` | только секрет-хранилище; разработчики пароль не запрашивают (SRC-B-122) |
| Согласованное имя отправителя (латиница, до 11 символов) | `SMSPRO_SENDER` в `.env` | обычный канал; согласование с операторами — 7–10 рабочих дней (`names@nikita.kg`) |
| Публичный IP сервера | вносится в ЛК SMSPro, если включён IP-whitelist (код `3`) | заказчик (Q-030) |
| Номера команды для реальной проверки | `SMS_STAGING_ALLOWED_PHONES` (только staging) | с письменного согласия владельцев номеров |
| Разрешение на реальные SMS (траты со счёта) | письменно (e-mail или протокол) | до шага §5 |

Организационные шаги на стороне заказчика:

1. Регистрация и активация аккаунта: PIN по SMS, после регистрации — 15 сом «для проверки».
2. Заявка на альфа-имя.
3. Договор: нужен для подмены имени и бухгалтерских документов.
4. Пополнение счёта.
5. Внесение логина и пароля в секреты сервера.
6. При необходимости — IP-whitelist в ЛК. Push-DLR — R2, в R1 не настраивается.

## 3. Переменные окружения

Несекретные переменные задаются в `.env` (пример — корневой `.env.example`, 09 §6.11). Секреты передаются только
через `*_FILE` и подключаются Compose `secrets:` к сервисам `api` и `worker` (16 §4.4).

| Переменная | Значение | Примечание |
|---|---|---|
| `SMS_PROVIDER` | `smspro` (staging, prod) · `fake` (dev, автотесты) | `fake` при `APP_ENV=prod` — отказ в старте (OPS-027) |
| `SMSPRO_BASE_URL` | `https://smspro.nikita.kg/api` | только `https://`: шлюз принимает и `http://` без редиректа, при `APP_ENV=prod` `http://` — отказ в старте (SEC-056) |
| `SMSPRO_LOGIN_FILE`, `SMSPRO_PASSWORD_FILE` | `/run/secrets/smspro_login`, `/run/secrets/smspro_password` | секреты; сервисы `api` и `worker` |
| `SMSPRO_SENDER` | согласованное имя | до согласования шлюз подставляет номер регистрации; несогласованное имя → `status=5` |
| `SMSPRO_TEST_FLAG` | `false` | `true` → каждая отправка с `<test>1</test>` (ответ `status=11`, SMS не уходит и не тарифицируется); при `APP_ENV=prod` — отказ в старте |
| `SMS_STAGING_ALLOWED_PHONES` | `+996700000002,…` | только `APP_ENV=staging`: реальные SMS — только на эти номера, на остальные автоматически уходит `<test>1</test>` |
| `SMSPRO_TIMEOUT_MS`, `SMSPRO_RETRY_MAX` | `15000`, `3` | повторы с тем же `id` (09 §6.4) |
| `SMSPRO_DLR_MODE` | `poll` | `push` — R2 (нужны `SMSPRO_DLR_ALLOWED_IPS` и URL в ЛК) |
| `SMSPRO_BALANCE_POLL_MINUTES`, `SMSPRO_BALANCE_ALERT_SOM` | `15`, `300` | опрос `/api/info` воркером; порог алерта ≈ 150 OTP |
| `SMSPRO_CB_OPEN_MINUTES` | `5` | пауза после `CONFIG_ERROR`/`INSUFFICIENT_FUNDS` |
| `SMS_OTP_TEMPLATE` | `Kod: {code}. Optomstroy` | обязательно `{code}`; одна часть SMS (≤ 70 кириллицей / ≤ 160 латиницей) |
| `OTP_HMAC_SECRET_FILE` | `/run/secrets/otp_pepper` | **api и worker** (§1) |
| `AUTH_OTP_TEST_MODE`, `AUTH_OTP_TEST_PHONES`, `AUTH_OTP_TEST_CODE` | выключено | тестовый режим OTP без SMS (09 §5.8) — только dev и staging; при prod — отказ в старте |

Проверка конфигурации без запуска сервиса: `node dist/main.js` с неверной комбинацией завершается с кодом 1 и
списком нарушений. Значения секретов в этом списке не печатаются.

## 4. Тестовый режим `test=1` (без SMS и без списания)

Цель шага — проверить логин и пароль, IP-whitelist, имя отправителя и разбор ответов на реальном шлюзе. Реальных
SMS при этом нет.

1. На staging задайте `SMS_PROVIDER=smspro`, `SMSPRO_TEST_FLAG=true`. Секреты логина и пароля внесены,
   `AUTH_OTP_TEST_MODE=false`. Перезапустите `api` и `worker`.
2. Запросите код в приложении на синтетический номер `+996700000003` или вызовите `POST /api/v1/auth/otp/request`
   с заголовком `X-Device-Id`.
3. Ожидаемый результат:
   - ответ `202`;
   - в журнале `sms_outbox` статус `sent`, `outcome = ACCEPTED_TEST`;
   - в логе воркера `event: sms.send` с `providerStatus: 11`.

   Расшифровка других исходов:

   | Исход | Причина |
   |---|---|
   | `status=2` (алерт `smspro_auth_failed`) | неверный логин или пароль |
   | `status=3` | IP сервера не внесён в whitelist |
   | `status=5` | имя отправителя не согласовано |
   | `status=4` | нет средств |

   ```sql
   SELECT created_at, status, outcome, provider_status_code, attempts, request_id
     FROM sms_outbox ORDER BY created_at DESC LIMIT 5;      -- без номера и текста
   ```
4. В `<test>1</test>` код не доставляется, поэтому войти этим кодом нельзя. Это ожидаемо: шаг проверяет только
   канал.
5. Утечка флага `test` в prod невозможна: `SMSPRO_TEST_FLAG=true` при `APP_ENV=prod` — отказ в старте. На всякий
   случай заведён и алерт `smspro_test_flag_leaked`.

## 5. Первый реальный тест — только с письменного разрешения заказчика

Каждая реальная SMS списывает деньги со счёта заказчика (≈ 1,6–2,0 сом). Первый тест выполняется только после
письменного разрешения: кто разрешил, дата, сколько SMS, на какие номера.

1. Убедитесь, что §4 пройден (`status=11`) и баланс не ниже 15 сом (§6).
2. Staging:
   - `SMSPRO_TEST_FLAG=false`;
   - `SMS_STAGING_ALLOWED_PHONES` — 1–2 номера команды, давшей согласие;
   - перезапуск `api` и `worker`.

   SMS на номер вне списка всё равно уходит с `<test>1</test>`.
3. Запросите код на номер из списка, дождитесь SMS, войдите. Не больше 2 SMS на номер: cooldown 60 с, лимит
   3 / 15 мин (09 §5.4).
4. Проверьте:
   - `sms_outbox.status`: `sent`, через 30 с – 10 мин — `delivered` (отчёт `/api/dr` с `report=3`, задания
     `sms.dlr_poll`);
   - время доставки;
   - текст SMS ровно одной частью (`sms_parts = 1`);
   - имя отправителя на телефоне.
5. Запишите результат в протокол:
   - дата;
   - номер в маскированном виде (`+996 7** *** *01`);
   - `provider_message_id`;
   - время доставки;
   - списание.

   Протокол хранится у заказчика или в `docs/stages/`, без полного номера.
6. Для prod: `APP_ENV=prod`, `SMSPRO_TEST_FLAG=false`, переменной `SMS_STAGING_ALLOWED_PHONES` нет. Первый вход
   администратора — по `docs/ops/first_admin.md`.

## 6. Баланс и отчёты о доставке (DLR)

**Баланс.** Воркер опрашивает `POST /api/info` каждые `SMSPRO_BALANCE_POLL_MINUTES` (задание `sms.balance_poll`).

- Лог воркера: `event: sms.balance` с полями `providerStatus`, `state`, `account`, `belowThreshold`.
- Метрика `sms_balance_som`.
- При `account < SMSPRO_BALANCE_ALERT_SOM` — алерт `sms_balance_low` и in-app уведомление «Низкий баланс SMS»
  всем активным `admin`, не чаще раза в сутки.
- При `state=1` или `status∈{2,3}` — критичный алерт и уведомление.

Последний снимок баланса можно прочитать без обращения к шлюзу:

```sql
SELECT completed_on, output->>'account' AS account, output->>'state' AS state, output->>'belowThreshold' AS low
  FROM pgboss.job WHERE name = 'sms.balance_poll' AND state = 'completed' ORDER BY completed_on DESC LIMIT 1;
```

**DLR.** В R1 используется режим `poll` (`SMSPRO_DLR_MODE=poll`). После принятия отправки воркер ставит
`sms.dlr_poll`: опросы `POST /api/dr` через 30 с, 2 мин и 10 мин. Итог доставки по коду `report`
(09 §6.5; R2 §4.3):

| `report` | Статус в `sms_outbox` | Поле `delivery_status` |
|---|---|---|
| 3 | `delivered` (+ `delivered_at`) | `3` |
| 2, 4, 5 | `failed` | `2` / `4` / `5` |
| 7 | `expired` | `7` |
| 0, 1, 6 (промежуточные) | `sent` (не меняется) | `0` / `1` / `6` |

Для клиента (`GET /auth/otp/challenges/{id}`) `expired` показывается как `failed`.

Push-отчёты (`POST /api/v1/integrations/smspro/dlr`, allow-list `SMSPRO_DLR_ALLOWED_IPS`) — R2. В R1 URL в ЛК не
настраивается.

## 7. Нештатные ситуации

| Симптом | Где видно | Действие |
|---|---|---|
| `503 SMS_PROVIDER_ERROR` на запрос кода | приложение, лог `otp.rate_limited` / `sms_circuit_open` | проверить баланс, логин и пароль, IP (§6); через `SMSPRO_CB_OPEN_MINUTES` канал откроется сам |
| Коды в `failed_delivery`, `outcome = CONFIG_ERROR` | `sms_outbox`, алерт `smspro_auth_failed` / `smspro_ip_not_allowed` | исправить секреты или whitelist, перезапустить `api` и `worker` |
| `outcome = INSUFFICIENT_FUNDS` | алерт `sms_balance_low` | пополнить счёт |
| Строки `sms_outbox` висят в `queued` | `SELECT status, count(*) FROM sms_outbox GROUP BY 1` | воркер не запущен (`WORKERS_ENABLED`) или не может расшифровать задание: разный `OTP_HMAC_SECRET` у `api` и `worker` (§1) |
| SMS не доступна вовсе (авария у вендора) | — | вход сотрудника по аварийному коду администратора (09 §6.13 п. 3, SCR-45) |

# R6. Аутентификация и безопасность POS «Оптомстрой» — исследовательский отчёт

Агент 6 — Authentication and Security Engineer. Дата: 2026-10-18. Этап 1 (ТЗ), код не пишется.

Легенда статусов: **[ПОДТВЕРЖДЕНО: источник]** — проверено по официальному источнику (дата обращения 2026-10-18); **[ТИПОВО: …, требует проверки]** — верно для типовых конфигураций/версий, нужно подтверждение у заказчика; **[НЕ ПОДТВЕРЖДЕНО]** — предложение/допущение автора.

Ограничения исследования: нет доступа к реальной 1С, кабинету SMSPro, серверу заказчика. Backend-стек (язык, СУБД) на момент отчёта не утверждён (зона агента 5) — там, где рекомендации зависят от стека, они помечены как типовые. Все числовые параметры (TTL, лимиты) — предлагаемые значения по умолчанию для конфигурации, не «истина в последней инстанции».

Материалы проекта, относящиеся к зоне агента: `D:\optomstroy\resursi\photo_2026-10-18_16-03-36.jpg` (макет входа: логин/телефон + пароль, «Запомнить меня», выбор сотрудника Абдулла/Достон/Алишер/Ислом, «Вход по карте сотрудника»), `IMG_7090.PNG` (подтверждение заказа, способы оплаты, «отправлен на согласование»), мастер-промт `MASTER_PROMPT_extracted.md` (разделы 7, 8, 9, 13, 16, 17, 4.5, 4.12). Важное расхождение: мастер-промт описывает вход по номеру телефона + OTP (SMSPro) и системную биометрию, а макет входа показывает пароль и «карту сотрудника». Это открытый вопрос №1 (см. раздел 11).

---

## 0. Сводка решений (для ТЗ)

| № | Решение | Статус |
|---|---------|--------|
| 1 | OTP: 6 цифр из CSPRNG, хранится только HMAC-SHA-256 с серверным секретом (pepper) + привязка к challenge_id; TTL 5 мин (допустимый коридор 3–10 мин); ≤5 попыток ввода на код; единоразовое использование; cooldown повторной отправки 60 с; лимиты отправки на номер 3/10 мин и 10/сутки; на IP и device_id — отдельные лимиты | Нормы: [ПОДТВЕРЖДЕНО: NIST SP 800-63B §5.1.3.2, ASVS 5.0 6.5.x]; значения: [НЕ ПОДТВЕРЖДЕНО — предложение] |
| 2 | Антиперебор номеров: единый нейтральный ответ `/auth/otp/request`; ветка «вход vs регистрация» принимается сервером **только после** успешной проверки OTP | [ПОДТВЕРЖДЕНО: OWASP Authentication CS, ASVS 6.3.8] + проектное решение |
| 3 | Сессии: access JWT 15 мин (сотрудники) / 30 мин (клиенты — предложение, т.к. у клиентов нет кассовых прав); refresh — непрозрачный токен 256 бит, хранится хэш, ротация при каждом обновлении, детект повторного использования → отзыв всей «семьи», привязка к device_id; абсолютный срок refresh — 30 дней (клиент) / 7 дней (сотрудник); idle для сотрудников — блокировка экрана через 30 мин неактивности (NIST 63B-3 §4.2.3 SHALL), требует согласования | Ротация/reuse detection: [ПОДТВЕРЖДЕНО: RFC 9700 §4.14.2]; TTL: [НЕ ПОДТВЕРЖДЕНО] |
| 4 | Биометрия: «системная биометрия + безопасно хранимый токен»: Android — Keystore-ключ с `setUserAuthenticationRequired(true)` + `BiometricPrompt.CryptoObject`; iOS — Keychain с `kSecAccessControlBiometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`; Windows — только UX-гейт (Windows Hello через `UserConsentVerifier` даёт boolean), криптопривязки нет. Срок `biometric_refresh` — по ролям/платформам (раздел 3.3): сотрудник Android/iOS — не более абсолютного срока обычного refresh (7 дней); Windows — `biometric_refresh` не выдаётся (нет криптопривязки); клиент — 30 дней | Механизмы: [ПОДТВЕРЖДЕНО: Android Keystore docs, Microsoft Learn, OWASP MASTG]; детали Apple — [ТИПОВО, страница не отрендерилась]; сроки — [НЕ ПОДТВЕРЖДЕНО] |
| 5 | `local_auth` в Release 1 допустим только как UX-гейт/fallback; для привязки токена — `biometric_storage` (5.0.1, опубликован ~2 года назад, есть 6.0.0-dev) либо собственный platform channel | [ПОДТВЕРЖДЕНО: pub.dev] |
| 6 | «Сканирование лица» при регистрации: в Release 1 — НЕ собирать и НЕ хранить сырые биометрические данные; шаг = настройка системной биометрии (UX-гайд). Цифровой кодекс КР (в силе с 06.02.2026) относит биометрические данные для цифровой идентификации к специальным категориям, обработка которых запрещена по умолчанию (ст. 80) | [ПОДТВЕРЖДЕНО: reestr.dpa.gov.kg/ru/npa/59] |
| 7 | RBAC: 4 роли сотрудников + «клиент» как кандидат; серверная проверка на каждом запросе; step-up (повторный OTP или биометрия с CryptoObject) для критических операций | [ПОДТВЕРЖДЕНО: OWASP Authorization CS, ASVS 8.x] |
| 8 | Аудит: append-only таблица + выгрузка в отдельную систему; хранение 3 года (требует согласования с бухгалтерией/1С) | Нормы: [ПОДТВЕРЖДЕНО: ASVS 16.4.x]; срок: [НЕ ПОДТВЕРЖДЕНО] |
| 9 | API: TLS 1.3 (+1.2), HSTS, pinning — НЕ в Release 1 (опция Release 2 с backup-pin и expiration), JSON-schema валидация, лимит тела 1 MB (JSON) / 10 MB (фото), `Idempotency-Key` для финансовых POST, PII-маскирование в логах, секреты через Docker secrets/`*_FILE` | [ПОДТВЕРЖДЕНО: OWASP REST/TLS/Pinning CS, IETF draft-ietf-httpapi-idempotency-key-header-07] |
| 10 | Бэкапы: RPO ≤ 15 мин (WAL-архив, если PostgreSQL), RTO ≤ 4 ч, шифрование, копия вне сервера, ежемесячный тест восстановления | [ТИПОВО: PostgreSQL PITR, требует выбора СУБД] |

---

## 1. Телефонная авторизация с OTP

### 1.1. Нормативная база

| Требование | Формулировка источника | Статус |
|---|---|---|
| Энтропия OTP | 63B-3 §5.1.3.2: «The verifier SHALL generate random authentication secrets with at least 20 bits of entropy» — 6 десятичных цифр дают log2(10^6) ≈ 19,93 бит, т.е. **формально ниже порога 63B-3**; действующая ревизия 63B-4 §3.1.3.2 формулирует требование явно: «at least six decimal digits (or equivalent) in length» — 6 цифр допустимы. **Проект опирается на 63B-4** (63B-3 отозвана NIST с 01.08.2025) | [ПОДТВЕРЖДЕНО: https://pages.nist.gov/800-63-3/sp800-63b.html §5.1.3.2; https://pages.nist.gov/800-63-4/sp800-63b.html §3.1.3.2] |
| Срок действия | «the authentication SHALL be considered invalid if not completed within 10 minutes» | [ПОДТВЕРЖДЕНО: NIST SP 800-63B §5.1.3.2; ASVS 5.0 6.5.5 «maximum lifetime of 10 minutes»] |
| Единоразовость | «verifiers SHALL accept a given authentication secret only once during the validity period» | [ПОДТВЕРЖДЕНО: NIST SP 800-63B §5.1.3.2; ASVS 5.0 6.5.1] |
| Rate limiting | Секреты < 64 бит энтропии требуют ограничения попыток (§5.2.2); верхняя граница «no more than 100» последовательных неудач на аккаунт; ASVS 6.6.3 — out-of-band коды защищены rate limiting | [ПОДТВЕРЖДЕНО: NIST §5.1.3.2, §5.2.2; ASVS 5.0 6.6.3] |
| CSPRNG | «generated using a Cryptographically Secure Pseudorandom Number Generator (CSPRNG)» | [ПОДТВЕРЖДЕНО: ASVS 5.0 6.5.3] |
| Привязка к запросу | Код «bound to the original request» (нельзя использовать для другого запроса) | [ПОДТВЕРЖДЕНО: ASVS 5.0 6.6.2] |
| SMS = «restricted authenticator» | PSTN/SMS — RESTRICTED: CSP обязан предлагать хотя бы один нересtricted альтернативный аутентификатор, уведомлять о рисках, иметь план миграции; проверять признаки SIM-swap/портирования номера перед отправкой | [ПОДТВЕРЖДЕНО: NIST SP 800-63B §5.1.3.3, §5.2.10; 800-63B-4 «Restricted Authenticators»] |
| Не логировать OTP | «SHOULD NOT: Log OTP values»; хэширование защищает от утечки через логи/метрики | [ПОДТВЕРЖДЕНО: OWASP MFA Cheat Sheet] |
| Неразглашение существования аккаунта | «respond (both HTTP and HTML) in a generic manner», одинаковое время ответа; «valid users cannot be deduced from failed authentication challenges» | [ПОДТВЕРЖДЕНО: OWASP Authentication CS; ASVS 5.0 6.3.8 (L3)] |

Следствие для проекта: SMS-OTP как **единственный** фактор для сотрудников с финансовыми правами (кассир, администратор, владелец) противоречит духу NIST («Do not use SMS for high-value or PII-handling applications» — OWASP MFA CS). Рекомендация: для ролей с финансовыми правами — SMS-OTP **плюс** второй фактор на устройстве (биометрия/PIN устройства с криптопривязкой, раздел 3) и step-up на критические операции; для клиентов-покупателей (если роль будет) — SMS-OTP достаточно при ограничении видимости финансовых данных. [НЕ ПОДТВЕРЖДЕНО — рекомендация]

### 1.2. Генерация и хранение

- Генерация: 6 цифр из CSPRNG ОС/платформы (`/dev/urandom`, `crypto.randomInt`, `secrets.randbelow(10**6)` и т.п. — конкретный API зависит от стека, агент 5). Ведущие нули сохраняются (код «004512» допустим). [ТИПОВО]
- Хранение: **не хранить код открыто.** Так как пространство 10^6 перебирается мгновенно, простой хэш (SHA-256 без секрета) не защищает от офлайн-перебора при утечке БД. Хранить `HMAC-SHA-256(key = OTP_PEPPER, msg = challenge_id || otp)`, где `OTP_PEPPER` — серверный секрет вне БД (secret manager/Docker secret). Альтернатива — Argon2id (OWASP: m=19 MiB, t=2, p=1 минимум), но при 5 попытках на код и большом трафике HMAC с pepper дешевле и достаточен, т.к. офлайн-перебор без pepper невозможен. [ПОДТВЕРЖДЕНО: OWASP Password Storage CS — параметры Argon2id, концепция pepper; применение к OTP — НЕ ПОДТВЕРЖДЕНО (OWASP не адресует OTP прямо)]
- Сравнение — constant-time.
- **Альтернатива: OTP-сервис SMSPro.** На странице https://smspro.nikita.kg/kg/techno.html провайдер, помимо XML/SOAP/SMPP, заявляет отдельный «Сервис одноразовых паролей (One Time Password service)» с описанием в `documents/smspro.nikita.kg-OTP-api.pdf` и Swagger-документацию XML-API (`https://app.swaggerhub.com/apis-docs/ALEXEYSOLOMAKHIN/nikita_online_sms_api/1.0.0`) [ПОДТВЕРЖДЕНО: содержимое techno.html — ссылки присутствуют]. Содержание OTP-PDF в этом отчёте **не изучено** — [НЕ ПОДТВЕРЖДЕНО — PDF не изучен; детальная оценка — зона агента 2 (SMSPro)]. Сравнение вариантов: (а) «свой OTP» (базовый вариант отчёта: генерируем код сами, храним HMAC с pepper, проверяем сами) — плюсы: полный контроль TTL/попыток/привязки к `challenge_id`/`purpose`, единый аудит, тест-режим без SMS, провайдер взаимозаменяем; минусы: хранение хэшей кодов у нас (риск снимается pepper'ом), собственная реализация rate-limit; (б) «OTP-сервис SMSPro» (провайдер генерирует и проверяет код) — плюсы: коды не хранятся в нашей БД, меньше кода; минусы: зависимость от одного провайдера и его API, неизвестные (до чтения PDF) параметры TTL/длины/числа попыток/привязки к запросу, проверка кода выполняется вне нашего контура (аудит и антиперебор частично вне нашего контроля), невозможно соответствовать требованиям ASVS 6.6.2 (привязка к запросу) и 6.5.1 (единоразовость), если API их не гарантирует, нет офлайн/тестового режима без провайдера. Решение Release 1: **вариант (а)**; вариант (б) рассмотреть после изучения PDF агентом 2 — если API даёт TTL ≤10 мин, ≤5 попыток, одноразовость и идентификатор сессии проверки, его можно использовать как **опцию конфигурации** (`OTP_PROVIDER=internal|smspro`). [НЕ ПОДТВЕРЖДЕНО — проектное решение]
- Таблица `otp_challenges` (предложение, согласовать с агентом 5): `id (uuid)`, `phone_e164`, `purpose (login|register|step_up|change_phone)`, `otp_hmac`, `created_at`, `expires_at`, `attempts (int)`, `max_attempts (int=5)`, `consumed_at (nullable)`, `device_id`, `ip`, `sms_message_id` (идентификатор от SMSPro, если API его возвращает), `status`. [НЕ ПОДТВЕРЖДЕНО]

### 1.3. Параметры (предлагаемые значения и обоснование)

| Параметр | Значение по умолчанию | Обоснование |
|---|---|---|
| Длина | 6 цифр | Минимум NIST/ASVS (≥20 бит); 4 цифры — недопустимо |
| TTL | **5 мин** (конфигурируемо 3–10) | NIST допускает ≤10 мин. 3 мин рискованно при задержках доставки SMS операторами КР (подтверждённой статистики доставки SMSPro нет — [НЕ ПОДТВЕРЖДЕНО]); 5 мин даёт запас, при этом окно перебора ограничено лимитом попыток, а не временем. Повторная отправка через 60 с создаёт **новый** код и аннулирует старый (OWASP MFA CS: «On resend, generate a new OTP and overwrite the old record») |
| Попыток ввода на код | **5** | Вероятность угадать 5/10^6 = 0,0005 % на код. NIST верхняя граница 100 — слишком щедро для 6 цифр |
| Cooldown повторной отправки | **60 с** | Баланс UX/стоимости SMS; меньше — рост расходов и спама |
| Отправок на номер | **3 за 10 мин, 10 за 24 ч** | Защита от SMS-flood и исчерпания бюджета (OWASP MFA CS: «protect against attackers requesting a large number of messages to exhaust funds») |
| Отправок на IP | 20 за 10 мин, 100 за 24 ч (NAT операторов КР — не делать жёстче без телеметрии) | [НЕ ПОДТВЕРЖДЕНО] |
| Отправок на device_id | 5 за 10 мин, 20 за 24 ч | device_id генерируется приложением (UUID в secure storage); подделываем, поэтому только дополнительный сигнал |
| Глобальный лимит | N отправок/мин на весь сервис (circuit breaker) с алертом | Защита бюджета SMSPro при массовой атаке |
| Блокировка после исчерпания | Код аннулируется; новый запрос возможен после cooldown; после 3 аннулированных кодов подряд на номер — пауза 30 мин + алерт | Не блокировать аккаунт навсегда (OWASP Forgot Password CS: «Accounts should not be locked out») |
| Повторное использование | `consumed_at` выставляется атомарно (`UPDATE … WHERE consumed_at IS NULL AND expires_at > now()`); повторный ввод того же кода → отказ | NIST single-use |
| Привязка | Код проверяется только с тем `challenge_id`, для которого выдан, и с тем же `purpose` | ASVS 6.6.2 |

Все значения — [НЕ ПОДТВЕРЖДЕНО — предложение, подлежит утверждению заказчиком]; они должны быть вынесены в конфигурацию.

### 1.4. Антиперебор номеров vs «если аккаунта нет — открывается регистрация»

Мастер-промт (раздел 8) требует: «Backend проверяет, существует ли связанная учётная запись. Если аккаунт существует — OTP… Если аккаунта нет — регистрация» и одновременно «Предусмотри защиту от перебора номеров… Не раскрывай посторонним клиентскую информацию». Прямая реализация (ответ «нет аккаунта» до OTP) — это оракул существования номера в базе клиентов магазина: злоумышленник за ночь перебирает диапазоны +996 и получает список клиентов (утечка персональных данных, ст. 78/88 Цифрового кодекса, ст. 413-2 Кодекса о правонарушениях).

Варианты:

| Вариант | Описание | Плюсы | Минусы | Оценка |
|---|---|---|---|---|
| **A. Нейтральный ответ, ветвление после OTP** (рекомендуется) | `POST /auth/otp/request {phone}` всегда отвечает `202 {challenge_id, resend_after_sec, otp_ttl_sec}` и всегда отправляет SMS (новому номеру — тоже). `POST /auth/otp/verify {challenge_id, code}` отвечает либо `{status:"authenticated", access, refresh}` либо `{status:"registration_required", registration_token}`; клиент открывает экран регистрации уже после OTP | Нет оракула; соответствует OWASP/ASVS; регистрация завершается без второго OTP (промт: «После заполнения формы отправь OTP» — можно выполнить требование одним OTP, подтверждённым до формы, либо вторым OTP после формы — см. ниже) | SMS уходит и на несуществующие номера → стоимость; UX: пользователь узнаёт о регистрации на шаг позже | Лучший баланс; стоимость SMS контролируется лимитами |
| B. Явный ответ «нет аккаунта» + жёсткие лимиты + device attestation | Сервер отвечает `{exists:false}` до OTP, но только при валидном Play Integrity/App Attest и строгих лимитах | Точно соответствует букве промта | Оракул остаётся (медленный перебор через много устройств/эмуляторы без Play Services); attestation недоступна на части устройств КР (без Google Play) и на Windows | Не рекомендуется |
| C. Явный ответ + CAPTCHA | Как B, но с reCAPTCHA/hCaptcha | Проще attestation | CAPTCHA в мобильном POS мешает кассирам; сервисы CAPTCHA — трансграничная передача IP/поведенческих данных (ст. 89) | Не рекомендуется для Release 1 |
| D. Нейтральный ответ, но SMS только существующим; новым — «если номер не зарегистрирован, SMS не придёт» | Экономит SMS | Таймингом/отсутствием SMS выдаёт оракул (пользователь-злоумышленник видит, пришла ли SMS на свой тестовый номер — неприменимо к чужим номерам, но по времени ответа API возможна утечка) | Допустимо только при constant-time обработке; хуже A |

Рекомендация — **A**. Уточнение по регистрации: промт требует «После заполнения формы отправь OTP. При правильном вводе кода автоматически заверши регистрацию». Совместимый поток: (1) номер → SMS → OTP (вариант A) → сервер: `registration_required` + `registration_token` (JWT, 15 мин, `purpose=register`, `phone` уже подтверждён); (2) форма регистрации (ФИО, год рождения, сфера деятельности); (3) `POST /auth/register {registration_token, profile}` → аккаунт создан, выдаются токены. Второй OTP после формы не нужен (номер уже подтверждён в этой же сессии), но если заказчик настаивает на буквальном порядке, допустим `purpose=register` повторный OTP с тем же лимитом. Привязка к существующему клиенту 1С (поиск по подтверждённому номеру) выполняется на шаге (3) и **никогда** не раскрывает финансовые данные до завершения регистрации (промт, раздел 9). [НЕ ПОДТВЕРЖДЕНО — проектное решение]

Что видит ответ API в обоих случаях — одинаковая структура и статус-код, одинаковое время (OWASP Authentication CS: «the processing time can be significantly different… same processing path»).

### 1.5. CAPTCHA / device attestation (опция)

- Play Integrity API (Android): проверяет `appRecognitionVerdict=PLAY_RECOGNIZED`, `appLicensingVerdict=LICENSED`, `deviceIntegrity` (MEETS_BASIC/DEVICE/STRONG_INTEGRITY); квота по умолчанию 10 000 запросов/сутки; стандартные запросы ~сотни мс; токен **расшифровывается и проверяется только на сервере** («Never decrypt tokens or expose keys within your client app»); требуется Google Cloud project. Приложение, установленное не из Google Play, получает `UNLICENSED`. [ПОДТВЕРЖДЕНО: https://developer.android.com/google/play/integrity/overview, …/setup]
- App Attest (iOS 14+): ключ в Secure Enclave, `generateKey` → `attestKey(clientDataHash)` с одноразовым серверным challenge → сервер проверяет attestation; далее `generateAssertion` для чувствительных запросов; проверка `DCAppAttestService.isSupported` обязательна, при `false` сервер должен работать без assertions. [ТИПОВО: общая схема App Attest по документации Apple; страница https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity рендерится JavaScript и при загрузке 2026-10-18 отдала только заголовок — дословные цитаты, минимальный размер challenge и поведение ключей при переустановке приложения в этом отчёте **не подтверждены**, проверить на этапе разработки по отрендеренной странице/Xcode-документации]
- Для Flutter потребуется platform channel или сторонний пакет (не проверялся) — [НЕ ПОДТВЕРЖДЕНО].
- Решение для Release 1: **не вводить** attestation как обязательное условие (Windows-POS и устройства без Google Play не пройдут); зарезервировать поле `attestation` в `/auth/otp/request` и использовать как **сигнал риска** (повышенные лимиты для аттестованных устройств) в Release 2. CAPTCHA — не использовать. [НЕ ПОДТВЕРЖДЕНО — рекомендация]

### 1.6. Логирование без кодов и тестовый режим

- В логах/метриках/трейсах: `challenge_id`, маскированный телефон (`+996 55* *** *12`), результат (`sent|verified|wrong_code|expired|rate_limited`), `attempts`, `ip`, `device_id`, `request_id`. **Никогда** — сам код, его HMAC, тело запроса к SMSPro с учётными данными. [ПОДТВЕРЖДЕНО: OWASP Logging CS; OWASP MFA CS]
- Тестовый режим: `AUTH_OTP_TEST_MODE=true` разрешён **только** при `APP_ENV in (dev, staging)`; сервер при старте в `production` с включённым тест-режимом должен **отказываться запускаться**. Фиксированный код (например, из `AUTH_OTP_TEST_CODE`) принимается только для номеров из allowlist `AUTH_OTP_TEST_PHONES` (список E.164); для всех остальных — обычный путь. SMS в тест-режиме не отправляется, а пишется в лог/таблицу `outbox`. Тестовые номера не должны совпадать с реальными клиентскими. [НЕ ПОДТВЕРЖДЕНО — проектное решение]
- SMSPro: на странице https://smspro.nikita.kg/kg/techno.html указаны поля входа в кабинет («Логин», «Пароль», «Код»), протоколы XML (PDF `documents/smspro.nikita.kg-XML-api.pdf`, EN-версия, Swagger `https://app.swaggerhub.com/apis-docs/ALEXEYSOLOMAKHIN/nikita_online_sms_api/1.0.0`), SOAP (WSDL по http://smspro.nikita.kg/api/soap?wsdl, «для подключения к 1С»), SMPP v3.4, отправка SMS по Email (SMTP), отдельный «Сервис одноразовых паролей» (PDF `documents/smspro.nikita.kg-OTP-api.pdf`, см. раздел 1.2) и «Защита данных (HTTPS / SSL)»; параметры аутентификации API и XML-теги на самой странице не приведены (они в PDF/Swagger — зона агента 2). Следствие для безопасности: учётные данные SMSPro — только на сервере, в secret manager; исходящие вызовы — только по HTTPS (проверить, что API-эндпоинт доступен по HTTPS, т.к. WSDL-ссылка на странице — http). [ПОДТВЕРЖДЕНО: содержимое страницы techno.html (перечень ссылок); доступность HTTPS у API и содержание PDF — НЕ ПОДТВЕРЖДЕНО]

---

## 2. Сессии и токены

### 2.1. Нормы

| Требование | Источник | Статус |
|---|---|---|
| Верификация токенов — на доверенном backend; токены динамические, не статические ключи | ASVS 5.0 7.2.1, 7.2.2 (L1) | [ПОДТВЕРЖДЕНО] |
| Энтропия reference-токена ≥128 бит, CSPRNG | ASVS 5.0 7.2.3 | [ПОДТВЕРЖДЕНО] |
| Новый токен при каждой аутентификации/смене привилегий | ASVS 5.0 7.2.4; OWASP Session CS «renewed… after any privilege level change» | [ПОДТВЕРЖДЕНО] |
| Idle- и absolute-таймауты | ASVS 7.3.1, 7.3.2; NIST AAL2: 63B-3 §4.2.3 — **SHALL**: повторная аутентификация не реже раза в 12 ч («at least once per 12 hours») и после неактивности ≥30 мин («following any period of inactivity lasting 30 minutes or longer»); 63B-4 §2.2 — **SHALL** установить общий таймаут, значение **SHOULD** ≤24 ч; неактивность **SHOULD** ≤1 ч | [ПОДТВЕРЖДЕНО: https://pages.nist.gov/800-63-3/sp800-63b.html §4.2.3; https://pages.nist.gov/800-63-4/sp800-63b.html §2.2] |
| Logout инвалидирует на сервере; возможность завершить все сессии; админ может завершить сессии пользователя | ASVS 7.4.1, 7.4.3, 7.4.5, 7.5.2 | [ПОДТВЕРЖДЕНО] |
| Отзыв self-contained (JWT): denylist/«not before» per-user/ротация ключа | ASVS 7.4.1 | [ПОДТВЕРЖДЕНО] |
| Refresh-токены публичных клиентов: ротация **или** sender-constraining обязательны; при обнаружении повторного использования сервер отзывает активный refresh; refresh привязан к scope | RFC 9700 §2.2.2, §4.14.2 | [ПОДТВЕРЖДЕНО: https://www.rfc-editor.org/rfc/rfc9700.html] |
| JWT: проверять `iss`, `aud`, `exp`, явный allowlist алгоритмов, denylist по `jti` для logout | OWASP REST Security CS | [ПОДТВЕРЖДЕНО] |
| Секреты сессии «SHOULD NOT be placed in insecure locations (e.g., HTML5 Local Storage)» — рекомендация (SHOULD NOT), не запрет; допускается хранение в защищённых keystore устройства | NIST 800-63B-4 §5.1 | [ПОДТВЕРЖДЕНО: https://pages.nist.gov/800-63-4/sp800-63b.html §5.1] |

### 2.2. Проектное решение [НЕ ПОДТВЕРЖДЕНО — предложение]

**Access token** — JWT, подпись асимметричная (ES256 или EdDSA; HS256 только если один сервис и ключ в secret manager), `kid` для ротации ключей. Claims: `iss`, `aud=optomstroy-api`, `sub=user_id`, `iat`, `exp` (**15 мин** для сотрудников; **30 мин** для роли `customer` — предложение, у клиентов нет кассовых прав), `jti`, `sid` (session id), `did` (device_id), `role`, `pv` (permissions_version — целое, инкрементируется при смене роли/прав), `amr` (`["sms"]`, `["sms","bio"]`), `acr`/`step_up_until` (время, до которого действует step-up). Без PII (ФИО, телефон) в payload.

**Refresh token** — непрозрачная строка 32 байта CSPRNG (base64url), в БД хранится **только SHA-256** (тут достаточно хэша без pepper — энтропия 256 бит). Таблица `sessions`: `id`, `user_id`, `device_id`, `family_id`, `refresh_hash`, `prev_refresh_hash`, `issued_at`, `expires_at` (абсолютный), `last_used_at`, `revoked_at`, `revoke_reason`, `client (android|ios|windows)`, `app_version`, `ip_last`, `kind (standard|biometric)`.

- Ротация: каждый `/auth/refresh` выдаёт новую пару и помечает старый refresh как использованный (хранить `prev_refresh_hash` для окна грации 30 с на сетевые ретраи).
- Reuse detection: предъявлен уже использованный refresh вне окна грации → отозвать **всю семью** (`family_id`), записать событие `session.reuse_detected` в аудит, уведомить пользователя push/SMS (ASVS 6.3.5). [ПОДТВЕРЖДЕНО: механизм RFC 9700 §4.14.2]
- Привязка к `device_id`: refresh принимается только с тем `device_id`, с которым выдан; несовпадение → отказ + аудит. Это «мягкая» привязка (device_id подделываем); криптографическая (DPoP, RFC 9449) — опция Release 2.
- Абсолютный срок refresh: **клиент** 30 дней; **сотрудник** 7 дней (смены, текучка персонала) — повторный OTP раз в неделю; idle: если refresh не использовался 24 ч (сотрудник) / 14 дней (клиент) — отзыв. Это **не соответствует буквально** NIST AAL2: 63B-3 §4.2.3 требует (SHALL) повторную аутентификацию не реже 12 ч и после 30 мин неактивности; 63B-4 §2.2 — SHOULD ≤24 ч и неактивность SHOULD ≤1 ч. Компромисс для POS (кассир весь день у кассы): (1) **блокировка экрана приложения через 30 мин неактивности** с разблокировкой биометрией с криптопривязкой (Android/iOS) или PIN приложения (Windows) — это локальная повторная аутентификация, закрывающая требование о 30 мин/1 ч; (2) **полная повторная аутентификация (OTP) раз в 7 дней** для сотрудников — отклонение от 12/24 ч, которое заказчик должен принять явно (остаточный риск, раздел 10) либо сократить до 24 ч (тогда — ежедневный OTP, расходы на SMS ≈ число сотрудников × рабочих дней). Для клиентов (`customer`, без финансовых прав) 30 дней допустимы как бизнес-решение. [ТИПОВО: NIST AAL2 (цитаты в 2.1), требует согласования — открытый вопрос №4]
- Единый принцип для всех видов refresh: **биометрический refresh (раздел 3.3) не может жить дольше обычного refresh той же роли** — иначе включение биометрии обходит еженедельный OTP.
- Revoke-триггеры (отзыв всех сессий пользователя): смена номера телефона, смена роли/прав (`pv++`), «выйти со всех устройств», блокировка пользователя администратором, подозрение на компрометацию, удаление device.
- Обновление ролей: при проверке access JWT сервер сравнивает `pv` из токена с `users.permissions_version` (кэш in-memory/Redis с TTL 60 с). Несовпадение → `401 token_stale` → клиент делает refresh и получает токен с новыми правами. Это обеспечивает ASVS 8.3.2 («applied immediately») с задержкой ≤ TTL кэша. Без кэша — просто ждать истечения 15 мин (недостаточно для понижения прав кассира — нужен кэш).
- Logout: `POST /auth/logout` отзывает текущую сессию (refresh) и добавляет `jti` access в denylist до его `exp` (15 мин). `POST /auth/logout_all` — все сессии пользователя. Администратор: `POST /admin/users/{id}/sessions:revoke_all`.
- Ограничение числа одновременных сессий: сотрудник — до 3 устройств, клиент — до 5; при превышении — отзывается самая старая (ТЗ-параметр).

### 2.3. Хранение на устройстве (Flutter)

`flutter_secure_storage` 11.2.0 (verified publisher steenbakker.dev; Android, iOS, Linux, macOS, Web, Windows). [ПОДТВЕРЖДЕНО: https://pub.dev/packages/flutter_secure_storage]

- Android: по умолчанию «RSA OAEP + AES-GCM» (ключ в Android Keystore); `EncryptedSharedPreferences` (Jetpack Security) **deprecated** — не использовать; minSdk 23. Обязательно `android:allowBackup="false"` и исключение файлов плагина из бэкапа — иначе после восстановления из Google Drive `InvalidKeyException: Failed to unwrap key`. [ПОДТВЕРЖДЕНО: pub.dev]
- iOS/macOS: Keychain; `accessibility`: `unlocked` (по умолчанию) — доступ только при разблокированном устройстве; `first_unlock_this_device` — если нужен фоновый refresh. Рекомендация: `first_unlock_this_device` для refresh и device_id (не мигрирует в бэкап на другое устройство; доступен при фоновом обновлении токена после первой разблокировки); более строгий `unlocked` не требуется, т.к. биометрический токен защищён отдельно ключом с криптопривязкой (раздел 3.2), а обычный refresh и так ограничен ротацией и device_id. [ПОДТВЕРЖДЕНО: опции; выбор — НЕ ПОДТВЕРЖДЕНО]
- Windows: страница пакета говорит лишь «platform-specific secure mechanisms» и требует C++ ATL; конкретный механизм (DPAPI/Credential Manager) на pub.dev не назван — **[НЕ ПОДТВЕРЖДЕНО]**, проверить в исходниках пакета на этапе разработки. Следствие: на Windows-POS секрет защищён на уровне учётной записи Windows; общий аккаунт Windows для нескольких кассиров = общий доступ к токенам → в ТЗ: каждый кассир — отдельная учётная запись Windows **или** обязательный PIN приложения + короткий TTL.
- Web: экспериментально, ключи в LocalStorage — **не использовать для POS**.
- Что хранить: refresh token, device_id, `biometric_refresh` (отдельно, раздел 3). Access token — только в памяти процесса. Не хранить телефон/ФИО в secure storage без необходимости.
- Очистка: при `401 invalid_refresh`/reuse detected — стереть всё и показать вход.

---

## 3. Биометрический вход

### 3.1. Честная оценка `local_auth`

`local_auth` 3.0.2 (Android SDK 24+, iOS 13+, macOS 10.15+, Windows 10+). `authenticate()` возвращает `bool`; `biometricOnly: true` — только биометрия (не поддерживается на Windows: «the underlying Windows Hello API doesn't let the app choose the authentication method»). Android требует `FlutterFragmentActivity`, `USE_BIOMETRIC`, тему `Theme.AppCompat`. [ПОДТВЕРЖДЕНО: https://pub.dev/packages/local_auth, https://pub.dev/packages/local_auth_android]

Ключевой факт: `local_auth` возвращает **только boolean** и **не связывает** результат с криптографическим ключом. OWASP MASTG называет это «event-bound» аутентификацией: приложение доверяет callback `onAuthenticationSucceeded`. По тексту MASTG-TEST-0018 «Testing Biometric Authentication» (раздел «Fingerprint bypass»): «The authentication implementation relies on the callback onAuthenticationSucceded being called» (орфография источника) и «This Frida script will bypass authentication when the CryptoObject is not used in the authenticate method» [ПОДТВЕРЖДЕНО: исходник страницы https://raw.githubusercontent.com/OWASP/owasp-mastg/master/tests/android/MASVS-AUTH/MASTG-TEST-0018.md, 2026-10-18; на сайте https://mas.owasp.org/MASTG/tests/android/MASVS-AUTH/MASTG-TEST-0018/ тело страницы при загрузке обрезано навигацией]. Связанные идентификаторы: MASTG-TEST-0327 и MASTG-TEST-0266 «References to APIs for Event-Bound Biometric Authentication» (Android/iOS; для iOS — опора только на `LAContext.evaluatePolicy`), MASTG-TEST-0267 «Runtime Use Of Event-Bound Biometric Authentication»; соответствующая слабость в MASWE — **MASWE-0020 «Local Authentication Can Be Bypassed»** (раздел MASVS-AUTH; смежные: MASWE-0021 «Fallback to Non-biometric Credentials Allowed for Sensitive Transactions», MASWE-0022 «Crypto Keys Not Invalidated on New Biometric Enrollment», MASWE-0023 «Step-Up Authentication Not Implemented for Sensitive Actions»). Рекомендация MASTG-BEST-0036 «Use Cryptographic Binding for Biometric Authentication»: Keystore-ключ с `setUserAuthenticationRequired(true)`, timeout 0, `CryptoObject`; MASTG-BEST-0037 — инвалидировать ключи при изменении enrolled-биометрии. [ПОДТВЕРЖДЕНО (заголовки/идентификаторы): https://mas.owasp.org/MASWE/ (перечень MASVS-AUTH: MASWE-0018…0025), https://mas.owasp.org/MASTG/best-practices/MASTG-BEST-0036/, https://mas.owasp.org/MASTG/tests/android/MASVS-AUTH/MASTG-TEST-0327/; содержание BEST-0036/0037 — ТИПОВО по заголовкам и документации Android]

Риск при использовании `local_auth` «как есть»: на рутованном/отлаженном устройстве хук возвращает `true` → токен из secure storage читается без биометрии. Для POS с финансовыми данными это неприемлемо как единственная защита.

### 3.2. Целевая архитектура: «системная биометрия + безопасно хранимый токен с криптопривязкой»

**Android** [ПОДТВЕРЖДЕНО: https://developer.android.com/privacy-and-security/keystore, https://developer.android.com/identity/sign-in/biometric-auth]
- Ключ AES-256-GCM в `AndroidKeyStore`: `setUserAuthenticationRequired(true)`, `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` (auth-per-use; при timeout>0 нельзя передать `CryptoObject`), `setInvalidatedByBiometricEnrollment(true)` (по умолчанию true — новый отпечаток/лицо инвалидирует ключ), при наличии `FEATURE_STRONGBOX_KEYSTORE` — `setIsStrongBoxBacked(true)` с fallback на `StrongBoxUnavailableException` (Google: «For most apps, StrongBox is not necessary»).
- `BiometricPrompt.authenticate(promptInfo, CryptoObject(cipher))` с `BIOMETRIC_STRONG` (Class 3). Успех → `result.cryptoObject.cipher.doFinal()` расшифровывает `biometric_refresh`. Подмена callback без реального подтверждения не даёт расшифровать (операция ключа авторизуется секьюрным железом: `KeyInfo.isUserAuthenticationRequirementEnforcedBySecureHardware()`).
- Что доступно из Flutter: `biometric_storage` 5.0.1 («Uses androidx with KeyStore», minSdk 23, `FlutterFragmentActivity`; iOS/macOS «LocalAuthentication with KeyChain»; Windows — по README «Uses wincreds.h to store into read/write into credential store», т.е. Credential Manager; README явно говорит об отсутствии биометрии только для Linux, поэтому утверждение «на Windows — без биометрической блокировки» — [ТИПОВО: следует из того, что Credential Manager не имеет привязки к Windows Hello; проверить в исходниках пакета]; web — незашифрованный localStorage). Опубликован «2 years ago», есть prerelease 6.0.0-dev.5; verified publisher codeux.design. Параметры валидности (`authenticationValidityDurationSeconds`) на странице pub.dev не описаны — проверить в API-документации. [ПОДТВЕРЖДЕНО: https://pub.dev/packages/biometric_storage; детали опций — НЕ ПОДТВЕРЖДЕНО] Риск: возраст релиза; при несовместимости с Flutter 3.38/AGP — собственный platform channel (Kotlin ≈150 строк + Swift ≈100 строк) по документации выше. Решение о пакете vs channel — на этапе Foundation после сборки прототипа.

**iOS** [ТИПОВО: страница https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset рендерится JavaScript и при загрузке 2026-10-18 отдала только заголовок; дословные цитаты и версия iOS ниже — по общеизвестной документации Apple, проверить на этапе разработки по отрендеренной странице/Xcode]
- Элемент Keychain с `SecAccessControlCreateWithFlags(kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet)`: элемент инвалидируется при добавлении/удалении отпечатков Touch ID или повторной регистрации Face ID (флаг введён как переименование `touchIDCurrentSet`; версия доступности — [ТИПОВО: iOS 11.3+, не подтверждено по странице]). `WhenPasscodeSetThisDeviceOnly` — элемент не мигрирует в бэкап и удаляется при снятии пароля [ТИПОВО]. Чтение `SecItemCopyMatching` с `kSecUseAuthenticationContext` вызывает системный Face ID/Touch ID; без успешной биометрии данные не возвращаются. `.biometryAny` — не использовать (переживает смену enrolled-биометрии); `.userPresence` допускает passcode-fallback — допустимо только если заказчик согласен считать passcode устройства достаточным.
- `NSFaceIDUsageDescription` в Info.plist обязателен.

**Windows** [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.ui.userconsentverifier]
- Windows Hello для desktop-приложений — `UserConsentVerifierInterop.RequestVerificationForWindowAsync(hwnd, message)` → `UserConsentVerificationResult` (`Verified`, `DeviceNotPresent`, `NotConfiguredForUser`, `RetriesExhausted`, `Canceled`, …). Это **проверка согласия/присутствия**, не связанная с ключом; метод не позволяет выбирать биометрию vs PIN. Криптопривязки, аналогичной Keystore/Keychain, через этот API нет. Привязка ключа к Windows Hello возможна через `KeyCredentialManager` (Windows Hello for apps), но её поддержка во Flutter-плагинах не проверена — [НЕ ПОДТВЕРЖДЕНО].
- Решение для Release 1 на Windows-POS: Windows Hello — только UX-гейт перед чтением refresh из хранилища; `biometric_refresh` на Windows **не выдаётся** (нет криптопривязки — иначе это «долгоживущий токен без реальной повторной аутентификации»); дополнительно обязательный **PIN приложения** (6 цифр, 5 попыток → OTP) для разблокировки экрана кассы после 30 мин неактивности и смены кассира; все критические операции — step-up (раздел 5). Либо вовсе не заявлять «биометрический вход» на Windows в Release 1.
- **Хранение PIN приложения.** 6-значный PIN имеет пространство 10^6 — как и OTP (раздел 1.2), простой хэш и даже Argon2id без секрета перебираются офлайн при утечке БД за часы на одном ядре. Варианты:

| Вариант | Описание | Плюсы | Минусы |
|---|---|---|---|
| **П1. Серверный PIN с pepper** (рекомендуется для Release 1) | На сервере хранится `Argon2id(pepper ∥ pin ∥ user_id)` с параметрами не ниже OWASP (m=19 MiB, t=2, p=1); `PIN_PEPPER` — отдельный серверный секрет вне БД (secret manager/`*_FILE`, ротация с версионированием как у `OTP_PEPPER`, раздел 7.8); проверка только на сервере с rate-limit по `user_id` **и** `device_id` (5 попыток → блокировка PIN на этом устройстве до OTP), constant-time сравнение; PIN в логи не пишется | Единая серверная политика, PIN работает на любой кассе, отзыв/сброс администратором, аудит попыток; без pepper утечка БД не даёт перебора | Нужен онлайн для разблокировки (для Windows-POS с сервером в локальной сети допустимо); ещё один секрет для ротации |
| П2. Локальный PIN как ключ-обёртка refresh | PIN никуда не передаётся; из PIN + локальная соль через Argon2id/PBKDF2 выводится ключ, которым шифруется refresh в Credential Manager/DPAPI; счётчик попыток — локальный | Работает офлайн; на сервере нет PIN-хэшей | Счётчик попыток на диске обходится (копия хранилища + офлайн-перебор 10^6 за минуты, т.к. у атакующего есть шифротекст); на Windows DPAPI уже привязан к учётной записи Windows — защита не выше, чем у самой учётной записи; нет центрального сброса |
| П3. Комбинация П1 + локальная DPAPI-обёртка | Refresh в Credential Manager (DPAPI), а разблокировка экрана — серверная проверка PIN (П1) | Лучшее из обоих | Сложнее; офлайн-разблокировка всё равно невозможна |

Решение: **П1** (при недоступности сервера касса остаётся заблокированной — приемлемо, т.к. без сервера POS всё равно не проводит операции; офлайн-режим чтения каталога — зона агента 3/5). Если заказчик требует офлайн-разблокировку — П2 с явным принятием риска офлайн-перебора. [НЕ ПОДТВЕРЖДЕНО — проектное решение; параметры Argon2id — ПОДТВЕРЖДЕНО: OWASP Password Storage CS]

### 3.3. Токен биометрического входа и step-up

- Отдельный `biometric_refresh` (kind=`biometric`, своя `family_id`), выдаётся **только** после успешной OTP-аутентификации на этом устройстве и явного включения биометрии пользователем. Хранится только под биометрическим ключом (3.2). При смене enrolled-биометрии ключ инвалидируется ОС → OTP заново (это желаемое поведение, объяснить пользователю).
- **Срок `biometric_refresh` — по ролям и платформам.** Принцип: биометрия с криптопривязкой (Android Keystore + `CryptoObject`, iOS Keychain + `biometryCurrentSet`) — это полноценный локальный фактор «что-то, чем я являюсь», подтверждаемый защищённым железом при каждом использовании, поэтому её можно считать повторной аутентификацией для **idle-таймаута** (30 мин/1 ч), но **не заменой** периодического OTP (владение номером телефона) — иначе включение биометрии обходит еженедельный OTP для финансовых ролей. Windows Hello через `UserConsentVerifier` криптопривязки не имеет — там `biometric_refresh` не выдаётся.

| Роль / платформа | `biometric_refresh` TTL (абсолютный) | Обычный refresh (2.2) | Idle-блокировка экрана | Статус |
|---|---|---|---|---|
| Сотрудник (seller, cashier, senior_seller, admin, owner), Android/iOS с криптопривязкой | **7 дней** (= обычному refresh; истекает одновременно, затем OTP) | 7 дней | 30 мин → биометрия с `CryptoObject`/Keychain | [НЕ ПОДТВЕРЖДЕНО — предложение] |
| Сотрудник, Windows-POS | **не выдаётся** (Windows Hello — только UX-гейт) | 7 дней | 30 мин → PIN приложения (П1) | [НЕ ПОДТВЕРЖДЕНО — предложение] |
| Сотрудник, Android/iOS без Class 3 биометрии (`BIOMETRIC_STRONG` недоступен) | не выдаётся; разблокировка — PIN приложения | 7 дней | 30 мин → PIN | [НЕ ПОДТВЕРЖДЕНО] |
| Клиент (`customer`), Android/iOS | **30 дней** (= обычному refresh клиента) | 30 дней | не требуется (нет финансовых операций); опционально 1 ч | [НЕ ПОДТВЕРЖДЕНО] |

Вынесено в открытые вопросы (№4 и №12).
- Access-токен, полученный через biometric_refresh, имеет `amr=["sms","bio"]`; операции из списка step-up требуют **свежего** подтверждения: либо повторная биометрия с `CryptoObject`/Keychain в последние N минут (сервер получает подписанный nonce — Release 2), либо (Release 1) повторный OTP, либо PIN приложения. Для Release 1 простое правило: step-up = OTP (`purpose=step_up`, TTL 5 мин, действует 10 мин, `step_up_until` в новом access). [НЕ ПОДТВЕРЖДЕНО — проектное решение]
- Отказ/ошибка биометрии → экран входа по номеру (промт, раздел 7). Биометрия не заменяет OTP при первом входе на устройстве и при смене номера.
- Не обещать: «Face ID на всех Android» — Android различает Class 2/Class 3; с `BIOMETRIC_STRONG` часть устройств (слабая камера-«лицо») откажет и предложит только отпечаток/PIN. [ПОДТВЕРЖДЕНО: Android biometric-auth docs — BIOMETRIC_STRONG = Class 3]

---

## 4. «Сканирование лица» при регистрации (прямо/влево/вправо/вверх)

### 4.1. Что это даёт реально

| Трактовка | Что получаем | Что НЕ получаем | Оценка |
|---|---|---|---|
| (а) UX-гайд для привязки системной биометрии | Пользователь проходит анимированный шаг «настройте вход по лицу/отпечатку», в конце — системный `BiometricPrompt`/Face ID enrollment-подсказка. Приложение **не снимает** и **не хранит** изображения | Собственного распознавания; эталона | Единственный вариант без обработки биометрических данных приложением. Рекомендуется для Release 1 |
| (б) Сбор эталона для будущего распознавания | 4 кадра лица → сервер/устройство хранит фото или эмбеддинг | Сопоставление «лицо ↔ аккаунт» требует собственной модели/сервиса (ArcFace и т.п.), серверной инфраструктуры, DPIA; это обработка специальных категорий (ст. 80 ЦК) | Не для Release 1 |
| (в) Liveness (защита от фото/видео) | Серия поворотов головы по подсказкам — это **активный liveness-челлендж**, но без специализированной модели (анализ текстуры, 3D-глубины, моаре, таймингов) его обходят видео на экране/маской | Промт прямо: «Не считай серию фотографий полноценной защитой от подделки» | Только коммерческий SDK (iProov, FaceTec, VerifyID, Regula, Innovatrics, Sumsub и т.п. — перечень не проверялся, стоимость неизвестна — [НЕ ПОДТВЕРЖДЕНО]) |

NIST 800-63B-4 §3.2.3: биометрия допустима **только** как часть многофакторной аутентификации с физическим аутентификатором; PAD (presentation attack detection) для распознавания лица — **SHALL**; FMR ≤ 1:10 000; всегда должна быть небиометрическая альтернатива; ограничение 5 неудач (10 с PAD), затем задержка ≥30 с. [ПОДТВЕРЖДЕНО: https://pages.nist.gov/800-63-4/sp800-63b.html §3.2.3]

### 4.2. Правовая рамка Кыргызской Республики

**Статус Закона № 58.** Закон КР от 14.04.2008 № 58 «Об информации персонального характера» (редакции по карточке spinform: Законы от 20.07.2017 № 129, 29.11.2021 № 142, 30.06.2022 № 53, 12.07.2022 № 61) **утратил силу** на основании ст. 2 Закона КР от 31.07.2025 № 179 «О введении в действие Цифрового кодекса Кыргызской Республики». [ПОДТВЕРЖДЕНО: https://base.spinform.ru/show_doc.fwx?rgn=22274 (карточка документа: «Документ утратил силу с 6 февраля 2026 года»); https://www.icnl.org/wp-content/uploads/KG-Personal-Data-Guidance-Note_Digital-Code_February-10-2026_RU.pdf (ICNL, текст PDF: «5 февраля 2026 года Закон 2008 года „Об информации персонального характера“ утратил силу и заменен соответствующими положениями Цифрового кодекса»; там же: «Цифровой кодекс… от 31 июля 2025 года №178 и вступил в силу 5 февраля 2026 года»); https://dpa.gov.kg/ru/question/7 (ГАЗПД: Цифровой кодекс «вступивший в силу с февраля 2026 года»)]. **Расхождение дат:** spinform — 6 февраля 2026, ICNL — 5 февраля 2026; точная дата определяется текстом Закона № 179 (ст. 1–2) и подлежит сверке по cbd.minjust.gov.kg — в ТЗ писать «с февраля 2026 года». Штрафы по ст. 413-2…413-5 КоП применяются, по ICNL, с 23.11.2025 («С 23 ноября 2025 года организации… могут быть привлечены к ответственности в виде штрафов… (статьи 413-2, 413-3, 413-4, 413-5)»); номер и дата закона, которым они введены, в использованных источниках **не указаны** — [НЕ ПОДТВЕРЖДЕНО: ранее приводившаяся ссылка «Закон № 95 от 19.05.2025» удалена как неподтверждённая]. Официальные карточки: Закон № 58 — https://cbd.minjust.gov.kg/202269/edition/1448/ru (при загрузке 2026-10-18 отдана только шапка «Закон КР от 14 апреля 2008 года № 58», статус/текст не получены); Закон № 179 — https://cbd.minjust.gov.kg/4-5604/edition/35394/ru (шапка «Закон КР от 31 июля 2025 года № 179 „О введении в действие…“», текст не получен) — [ТИПОВО: статус подтверждён карточкой spinform, ICNL и ГАЗПД, требует проверки по тексту на cbd.minjust.gov.kg].

Следовательно, в ТЗ ссылаться надо на **Цифровой кодекс КР № 178 от 31.07.2025 (принят ЖК 18.06.2025), глава 11 «Обработка персональных данных» (ст. 77–91)** и смежные статьи. Источник текста, использованный в отчёте: реестр ГАЗПД https://reestr.dpa.gov.kg/ru/npa/59 [ПОДТВЕРЖДЕНО: страница реестра регулятора]; официальная карточка Кодекса в базе Минюста: https://cbd.minjust.gov.kg/3-48/edition/35412/ru (шапка «Цифровой Кодекс Кыргызской Республики от 31 июля 2025 года», текст статей при загрузке не отдан — рендерится скриптом) — сверка формулировок статей по cbd.minjust.gov.kg вынесена в открытый вопрос №13. Все изложения статей ниже даны **по тексту реестра ГАЗПД**.

Ключевые положения (изложение по тексту Кодекса; дословные цитаты — короткие):

| Статья | Содержание | Значение для проекта |
|---|---|---|
| ст. 1 п. 42, 21, 69, 75, 78 | «Персональные данные» — «цифровые данные, содержащие информацию персонального характера»; «субъект персональных данных»; «трансграничная передача» — передача владельцам записей под юрисдикцией других государств; «утечка» — данные стали доступны лицам без законного основания | Телефон, ФИО, год рождения, история покупок, долги, device_id — персональные данные |
| ст. 77 | Кодекс применяется к любым отношениям по обработке ПД (кроме обработки физлицом в личных целях) | Магазин — «владелец записей», подрядчик/хостинг — «обработчик» |
| ст. 78 | Принципы: законность/справедливость/открытость; ограничение цели; минимизация («не должны быть избыточными»); точность; **хранение не дольше необходимого для цели**, затем уничтожение или обезличивание; обязательные орг./тех. меры; владелец обязан уметь подтвердить соблюдение | Нужны политика хранения и retention-джобы; год рождения/сфера деятельности — обосновать цель |
| ст. 79 | Основания: договор, законная обязанность, жизненно важные интересы, общественно полезные задачи, законные интересы; иначе — согласие. Согласие «должно быть добровольным, конкретным, информированным и сознательным», в любой форме, если можно подтвердить факт получения; запрос на согласие должен быть **отдельным и ясным**; ничтожно, если не выделен/непонятен/направлен при наличии другого основания; отзыв не сложнее предоставления | Для регистрации клиента — основание «договор» (оптовая покупка) плюс отдельное согласие на необязательные цели; хранить доказательство согласия (версия текста, время, device, challenge_id) |
| **ст. 80** | «Запрещается обработка следующих специальных категорий персональных данных», в т.ч. «биометрических данных для цифровой идентификации физического лица». Исключения (ч. 2): договор, прямое указание закона, жизненно важные интересы, данные, сделанные субъектом общедоступными, медицинские/научные цели — при условии закреплённых в законе и применяемых мер защиты | **Ключевой риск.** Собственное распознавание лица = обработка специальных категорий; опора на исключение «договор» спорна и требует юридического заключения |
| ст. 48 ч. 2, 5 | Государственная система биометрической идентификации: биометрия обрабатывается для цифровой аутентификации на выборах/госуслугах и «в случаях, прямо предусмотренных законом»; идентификация сравнением «со всеми имеющимися в базах данных» запрещена; ч. 5: обработка в иных целях «не допускается». Формулировка не уточняет, ограничен ли запрет государственной системой | Неопределённость сферы запрета для частных систем — требует юридического заключения |
| ст. 82 | Оценка воздействия обязательна, в частности, при обработке специальных категорий «в отношении более чем тысячи субъектов» и при систематической автоматизированной оценке личности | Распознавание лиц для >1000 клиентов → DPIA обязательна |
| ст. 83 | «Немедленно удалить» по запросу субъекта или при отпадении основания (в т.ч. отзыв согласия); исключения — защита претензий, требования закона о хранении | Нужна процедура удаления аккаунта с сохранением финансовых документов 1С по закону о бухучёте |
| ст. 84, 85 | Возражение — ответ в 7 рабочих дней; ограничение обработки — уведомление в 1 рабочий день | Процесс поддержки |
| ст. 86 | Обработчик — только по договору с обязательными условиями (период, цель, типы данных, письменные распоряжения, ограничение доступа, учёт операций); субобработчик — с письменного разрешения | Договор с хостингом/SMS-провайдером/разработчиком |
| ст. 88 | Защита: «конструктивная защита при проектировании» (privacy by design), учёт операций, **ответственное лицо при >10 работников**, обучение персонала; уровни защищённости устанавливает Кабмин | Назначить ответственного за ПД в магазине |
| ст. 63 ч. 5–8 | Уведомление регулятора об инциденте «не позднее чем через 72 часа» после обнаружения; обработчик уведомляет владельца ≤48 ч; состав уведомления | Процедура реагирования на инциденты + контакт ГАЗПД |
| ст. 89 | Трансграничная передача: регулятор ведёт перечень государств с адекватной защитой; в них — свободно (владелец обязан убедиться, что государство в перечне); в иные — при согласии субъекта, по договору с субъектом и др. На сайте ГАЗПД в перечне помечен «Соответствует» только Кыргызстан, остальные «Неизвестно» | Облачные сервисы за пределами КР (Firebase, зарубежные VPS, reCAPTCHA, аналитика) = трансграничная передача; штраф по ст. 413-3 КоП до 65 000 сом (повторно 100 000). Размещение backend на сервере заказчика в КР снимает риск |
| ст. 90 | Регулятор — Государственное агентство по защите персональных данных при Кабинете Министров КР (dpa.gov.kg); ведёт реестр владельцев записей с данными об инцидентах/проверках | ГАЗПД сообщает: «ведутся технические работы по запуску Реестра владельцев записей»; ICNL: регистрация в реестре по ЦК «больше не требуется». Противоречие — уточнить у ГАЗПД |

Ответственность (Кодекс КР о правонарушениях, по ICNL/Economist.kg): ст. 413-2 (нарушение требований о защите ПД) — юрлица 65 000 сом, повторно 120 000; ст. 413-3 (трансграничная передача с нарушением) — 65 000 / 100 000; ст. 413-4 (отказ субъекту в доступе) — 25 000 / 45 000; ст. 413-5 — 30 000; ст. 228-3 («Нарушение прав принципалов данных»), 228-6, 228-7 — новые составы, вступившие в силу одновременно с Цифровым кодексом (ICNL: «новые составы правонарушений… (статьи 228-3, 228-6 и 228-7)»; недобросовестная обработка: избыточный сбор, «связанное» согласие, отсутствие информирования) — 10 000 / 25 000 для юрлиц; УК КР ст. 190 (нарушение неприкосновенности частной жизни). Действующая редакция КоП в базе Минюста: https://cbd.minjust.gov.kg/3-36/edition/40617/ru (текст не загружался). [ТИПОВО: по вторичным источникам ICNL (апрель 2026) и Economist.kg (сентябрь 2025), размеры штрафов требуют проверки по cbd.minjust.gov.kg]

Ориентир GDPR (как best practice, не как норма КР): биометрические данные — особая категория (ст. 9 GDPR), требуют явного согласия или иного исключения, DPIA, минимизации; принципы совпадают с ст. 78–82 ЦК. [ТИПОВО — общеизвестное, URL не приводится]

### 4.3. Рекомендация для ТЗ

1. **Release 1: сырые биометрические данные (фото лица, видео, эмбеддинги) не собираются и не хранятся ни на сервере, ни на устройстве приложением.** Шаг регистрации «Сканирование лица или настройка биометрии» реализуется как «настройка биометрического входа» через системную биометрию (раздел 3): приложение не получает доступ к изображению; эталон живёт в защищённом железе ОС, что не является обработкой биометрии приложением/магазином.
2. Шаг — **опциональный** с явным, отдельным, отзываемым согласием-переключателем (ст. 79 ч. 3–5); отказ не блокирует регистрацию (NIST: небиометрическая альтернатива обязательна). Промт называет шаг «обязательным по утверждённому безопасному сценарию» — «обязательность» трактуется как «обязательно показать и предложить», не «обязательно включить».
3. Анимационная последовательность «прямо/влево/вправо/вверх» может быть сохранена как UX-подсказка перед системным промптом (персонаж показывает, как держать телефон), но ТЗ должно явно указать: **кадры не захватываются**; никаких заявлений о liveness.
4. Если бизнес настаивает на собственном распознавании лица с liveness: отдельный этап (Release 2+), условия: (а) юридическое заключение по ст. 80/48 ЦК; (б) DPIA по ст. 82; (в) коммерческий SDK с сертифицированным PAD (iBeta/ISO 30107-3 — [ТИПОВО]); (г) эталон хранится только на устройстве либо шифруется ключом с разделённым хранением; (д) срок хранения и процедура удаления; (е) локализация в КР (ст. 89); (ж) информирование ГАЗПД/ответственное лицо.
5. **Что обещать нельзя** (в ТЗ — раздел «Ограничения»): полноценную защиту от подделки серией селфи; «Face ID на любом Android»; распознавание одного лица на разных устройствах без серверного эталона; соответствие закону без юридической проверки; что биометрия заменяет OTP при смене устройства/номера; что «вход по карте сотрудника» (макет) работает без выбора и закупки NFC/RFID-оборудования.

---

## 5. RBAC — роли, матрица прав, серверная проверка, step-up

Нормы: «never rely on client-side access control checks»; deny by default; проверка прав «on every request for the specific object or functionality»; ASVS 8.2.1 (function-level), 8.2.2 (object-level/IDOR), 8.2.3 (field-level, L2), 8.3.1 (enforce at trusted service layer), 8.3.2 (изменения прав применяются немедленно). OWASP отмечает, что ABAC/ReBAC предпочтительнее для роста сложности; для Release 1 достаточно RBAC с атрибутами (склад, лимит скидки). [ПОДТВЕРЖДЕНО: OWASP Authorization CS; ASVS 5.0 V8]

### 5.1. Роли (предварительно, из промта разд. 13; согласовать с магазином)

| Роль | Код | Описание | Источник |
|---|---|---|---|
| Продавец | `seller` | Каталог, корзина, создание заказа в рамках правил; макет каталога показывает «Абдулла, Продавец» | промт §13, макет |
| Кассир | `cashier` | Кассовые операции, клиенты, долги (разрешённая часть), транзакции, скидки в лимите | промт §12–13 |
| Старший продавец | `senior_seller` (кандидат) | Макет входа: «Ислом — старший продавец»; возможно = продавец + подтверждение скидок/отмен | макет входа — [НЕ ПОДТВЕРЖДЕНО] |
| Администратор | `admin` | Пользователи, роли, настройки, синхронизация | промт §13 |
| Руководитель/владелец | `owner` | Отчёты, финансовые данные, полный аудит; не обязан иметь права кассира | промт §13 |
| Клиент-покупатель | `customer` (кандидат) | Регистрация по телефону, свой каталог/корзина/заказы, свой долг — только после подтверждения владения | промт §8–9 |
| Интеграционный сервис 1С | `integration` (технический) | Только обмен данными, не интерактивный | архитектура |

### 5.2. Матрица прав (ресурс × действие). R — чтение, C — создание, U — изменение, X — отмена/удаление, A — утверждение; `S!` — требуется step-up; `lim` — в пределах лимита роли; `own` — только свои объекты

| Ресурс | seller | cashier | admin | owner | customer |
|---|---|---|---|---|---|
| Каталог/товары/остатки | R | R | R | R | R (цены — по правилам оптовых условий) |
| Закупочные цены / себестоимость | — | — | — | R | — |
| Корзина/черновики | CRUX own | CRUX own | — | R | CRUX own |
| Заказы | C, R own, U own(до согласования) | C, R, U | R | R, A | C, R own |
| Отмена заказа | X own (до согласования) | X `S!` | — | X `S!` | X own (до согласования) |
| Продажа/оплата (кассовая операция) | — | C `S!`(свыше порога), R | — | R | — |
| Отмена/возврат транзакции | — | X `S!` | — | A `S!` | — |
| Скидка | C lim (например ≤5 %) | C lim (≤10 %), выше — `S!` + A старшего/owner | — | A | — |
| Клиенты: имя, телефон | R | CRU | CRU | R | R own |
| Клиенты: история покупок | — | R | — | R | R own |
| Клиенты: долг/взаиморасчёты | — | R (сумма, статус) | — | R полный | R own (после подтверждения владения) |
| Избранное клиентов | — | CRUX | — | R | — |
| Пользователи/роли | — | — | CRU `S!`, X `S!` | R, A | — |
| Своя сессия/устройства | RU own | RU own | RU own | RU own | RU own |
| Чужие сессии (revoke) | — | — | X `S!` | X `S!` | — |
| Настройки (лимиты скидок, OTP-параметры, SMSPro) | — | — | U `S!` | R | — |
| Синхронизация 1С (ручной запуск, статус) | R статус | R статус | C, R | R | — |
| Аудит-лог | — | — | R (без финансовых деталей?) | R полный | — |
| Отчёты | — | — | — | R | — |
| Экспорт данных | — | — | — | C `S!` | — |

Статус матрицы: [НЕ ПОДТВЕРЖДЕНО — предложение; каждая строка требует подтверждения владельцем магазина; пороги скидок и суммы для step-up — параметры конфигурации].

### 5.3. Серверная реализация

- Проверка на каждом endpoint: middleware → `authorize(subject, action, resource, context)`; политика в коде/таблице `permissions(role, resource, action, constraint_json)`; deny by default; результат «deny» логируется (ASVS 16.3.2).
- Object-level: для `own`-ресурсов — фильтр по `user_id` в SQL/репозитории, а не post-фильтрация в контроллере; идентификаторы — UUID v4 (не угадываемые), но это не защита — проверка владения обязательна.
- Field-level: DTO по роли (кассир не получает поле `cost_price`; клиент не получает `debt` до подтверждения). Сериализация — allowlist полей.
- «Кнопка в UI не защита»: Flutter скрывает недоступные действия по `permissions` из `/me`, но сервер всегда проверяет; тест: вызов endpoint с токеном продавца должен дать `403`.
- Step-up: сервер проверяет `step_up_until > now()` в access-токене и `amr` содержит свежий фактор; иначе `403 step_up_required` → клиент запрашивает OTP (`purpose=step_up`) или (Release 2) биометрическое подтверждение с криптопривязкой; подтверждение действует 10 мин, привязано к `sid`.
- Операции step-up (минимум): отмена/возврат транзакции; скидка сверх лимита; изменение цены вручную (если вообще разрешено); смена роли/прав; смена номера телефона; отзыв чужих сессий; изменение настроек OTP/SMS/лимитов; экспорт данных; просмотр полного долга клиента кассиром при сумме выше порога (опция).
- Лимит видимости финансовых данных: долг клиента показывается кассиру как сумма/статус/дата последней синхронизации; детальная история платежей — owner; клиент видит только свой долг после привязки аккаунта к карточке 1С с подтверждением (OTP на номер из 1С) — промт §9.

---

## 6. Аудит

Нормы: логировать «when, where, who and what»; аутентификация (успех/неудача), отказ в авторизации, ошибки валидации, события сессий; **не** логировать пароли/токены/OTP/платёжные данные; «Build in tamper detection»; «Store or copy log data to read-only media as soon as possible»; ASVS 16.2.1 (метаданные), 16.2.2 (UTC/синхронизация времени), 16.2.5 (L2: «when logging sensitive data, the application enforces logging based on the data's protection level» — т.е. политика логирования по уровню защиты данных; в пояснении стандарта: учётные данные/платёжные данные не логируются, токены сессий — только хэшированные/маскированные; хэш/маска — наш проектный выбор в рамках этой политики, раздел 7.7), 16.4.1 (log injection), 16.4.2 (нельзя модифицировать), 16.4.3 (передача в логически отдельную систему). [ПОДТВЕРЖДЕНО: OWASP Logging CS; ASVS 5.0 V16]

### 6.1. Что логировать (таблица `audit_logs`, предложение)

| Поле | Описание |
|---|---|
| `id` | монотонный BIGSERIAL/ULID |
| `occurred_at` | UTC, из NTP-синхронизированных часов |
| `request_id` | корреляция с HTTP-логами/трейсами |
| `actor_user_id`, `actor_role`, `on_behalf_of` | кто; для технического сервиса — `integration` |
| `session_id`, `device_id`, `ip`, `app_version`, `client_platform` | откуда |
| `action` | словарь: `auth.otp.sent`, `auth.otp.verified`, `auth.otp.failed`, `auth.login`, `auth.logout`, `session.reuse_detected`, `user.role_changed`, `order.created`, `order.cancelled`, `sale.created`, `sale.refunded`, `discount.applied`, `discount.over_limit_approved`, `price.changed`, `stock.adjusted`, `customer.debt_viewed`, `settings.changed`, `sync.started/finished/failed`, `export.created`, `authz.denied` … |
| `entity_type`, `entity_id`, `onec_ref` | что; ссылка на объект 1С |
| `before`, `after` (JSONB) | снимки изменённых полей (с маскированием PII по политике) |
| `result` | `ok|denied|error` |
| `step_up_method` | `otp|bio|pin|none` |
| `reason` | комментарий оператора (обязателен для отмен/корректировок) |
| `prev_hash`, `row_hash` | хэш-цепочка (опционально, tamper-evidence) |

Не писать в аудит: OTP, токены, пароли/PIN-хэши, полные номера карт/телефонов (маска), фото.

### 6.2. Append-only и защита от изменения [ТИПОВО: PostgreSQL, требует выбора СУБД]

- Приложение пишет под ролью БД с правами `INSERT` only на `audit_logs` (без `UPDATE/DELETE`); владелец схемы — отдельная миграционная роль; триггер `BEFORE UPDATE OR DELETE … RAISE EXCEPTION`.
- Партиционирование по месяцам; старые партиции — `READ ONLY`/перенос в архив.
- Хэш-цепочка `row_hash = SHA-256(prev_hash || canonical(row))` + ежедневная «якорная» запись хэша в отдельное хранилище (файл на бэкап-сервере/объектное хранилище) — даёт tamper-evidence без HSM.
- Стриминг копии (логическая репликация/экспорт) в отдельную систему логов на другом хосте/бакете (ASVS 16.4.3); доступ администратора приложения к ней — только чтение.
- Все обращения к аудиту (чтение owner/admin) тоже логируются.

### 6.3. Хранение

- Предложение: оперативная таблица 1 год, архив 3 года; события аутентификации/сессий — 1 год; финансовые события (продажи, отмены, возвраты, скидки, корректировки) — не менее срока хранения первичных бухгалтерских документов в КР (конкретный срок в этом отчёте **не подтверждён** — уточнить у бухгалтера/1С-специалиста). OWASP: не уничтожать раньше требуемого срока и не хранить дольше (ст. 78 ч. 5 ЦК — минимизация хранения). [НЕ ПОДТВЕРЖДЕНО]
- Логи приложения (не аудит): 90 дней горячие, 1 год холодные; PII маскируется (раздел 7.7).

---

## 7. Защита API

### 7.1. TLS
- Только HTTPS; «Web applications must default to TLS 1.3 and may support TLS 1.2»; TLS 1.0/1.1 отключены (RFC 8996); AEAD-шифры (AES-GCM, ChaCha20-Poly1305), без CBC; RSA ≥2048 или ECDSA P-256; конфигурация — Mozilla SSL Configuration Generator (профиль «intermediate»). [ПОДТВЕРЖДЕНО: OWASP TLS CS]
- Сертификат: Let's Encrypt с автообновлением или сертификат заказчика; `cleartextTrafficPermitted=false` (Android 9+ по умолчанию) — явно зафиксировать в `network_security_config.xml`. [ПОДТВЕРЖДЕНО: Android security-config]
- Между backend и 1С (внутри сети заказчика): также TLS или изолированный VLAN/VPN — зона агента 2/5.

### 7.2. HSTS и заголовки
`Strict-Transport-Security: max-age=63072000; includeSubDomains` (preload — только после проверки на hstspreload.org); `X-Content-Type-Options: nosniff`; `Cache-Control: no-store` для API; `Content-Security-Policy: frame-ancestors 'none'`; `X-Frame-Options: DENY`; `Referrer-Policy: strict-origin-when-cross-origin`; удалить `Server`, `X-Powered-By`. Для чистого JSON-API заголовки CSP/Permissions-Policy актуальны только при наличии web-админки. [ПОДТВЕРЖДЕНО: OWASP HTTP Headers CS, REST Security CS]

### 7.3. Certificate pinning — за/против
- OWASP: «Should I Pin? The answer to this is probably never»; «The risk of outages almost always outweighs any security risks»; если пиннить — только нативное мобильное приложение, SPKI (public key) leaf + backup pin промежуточного CA, использовать Android Network Security Config (`<pin-set expiration="yyyy-MM-dd">` с `digest="SHA-256"` и backup-пином; без `expiration` пины не истекают → риск «кирпича» при смене ключа), не писать свою валидацию. [ПОДТВЕРЖДЕНО: OWASP Pinning CS; Android security-config]
- Для Оптомстрой: за — защита от MITM на недоверенных Wi-Fi/корпоративных прокси; против — Let's Encrypt ротирует ключ при каждом обновлении (90 дней), если не зафиксировать ключ; Windows-клиент Flutter не использует Android NSC (нужна реализация в Dart `SecurityContext`/`badCertificateCallback` — ошибки вероятны); нет процесса безопасной доставки нового pinset. **Решение: Release 1 — без pinning**, но: (1) TLS-ключ сервера генерируется один раз и переиспользуется при обновлении сертификата (certbot `--reuse-key`) — чтобы в Release 2 можно было пиннить SPKI; (2) запрет user-added CA на Android (`<trust-anchors><certificates src="system"/>` — поведение по умолчанию для API 24+). [НЕ ПОДТВЕРЖДЕНО — рекомендация]

### 7.4. Валидация входных данных
- «Do not trust input parameters/objects»; валидировать синтаксис и семантику на сервере; JSON Schema с явными `required` и `additionalProperties: false` (иначе лишние поля не отклоняются → mass assignment); схемы для вложенных объектов, лимиты массивов. [ПОДТВЕРЖДЕНО: OWASP Input Validation CS; REST Security CS]
- Телефон: нормализовать к E.164 (`+996XXXXXXXXX`, 9 цифр после кода — [ТИПОВО: план нумерации КР, требует проверки]), хранить только нормализованный вид.
- Деньги: строка/целое в тыйынах (минорные единицы) или decimal; не `double`; скидка — проценты с 2 знаками, пределы по роли.
- Количество: ≥0, кратность упаковке по данным 1С.
- Лимит тела: JSON ≤ 1 MB (`413 Payload Too Large`); загрузка фото (если будет) — отдельный endpoint ≤ 10 MB, проверка magic bytes, перекодирование изображения, без выполнения; `415` для неподдерживаемых Content-Type; allowlist HTTP-методов (`405`). [ПОДТВЕРЖДЕНО: OWASP REST Security CS; File Upload CS — не загружался, ТИПОВО]
- Ошибки: generic (`{code, message, request_id}`), без стек-трейсов (ASVS 16.5.1); fail-closed (16.5.3).

### 7.5. Идемпотентность финансовых запросов
Заголовок `Idempotency-Key` (IETF draft-ietf-httpapi-idempotency-key-header-07 от 15.10.2025; статус на datatracker: **expired Internet-Draft** («no longer active», страница обновлена 18.04.2026), не RFC — используется как де-факто практика (Stripe и др.), не норматив): ключ уникален, **не переиспользуется с другим payload** (RECOMMENDED UUID); повтор завершённой операции → «respond with the result of the previously completed operation, success or an error»; повтор во время выполнения → `409 Conflict`; тот же ключ с другим payload → `422`; отсутствие обязательного ключа → `400`; политика срока хранения ключей публикуется. [ПОДТВЕРЖДЕНО: https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-idempotency-key-header]

Проект: обязателен для `POST /orders`, `POST /sales`, `POST /payments`, `POST /refunds`, `POST /orders/{id}:cancel`, `POST /discounts:approve`. Таблица `idempotency_keys(key, user_id, endpoint, request_fingerprint(SHA-256 тела), status, response_code, response_body, created_at, expires_at=24 ч)`; ключ скоупится по `user_id` (чужой ключ не конфликтует); генерируется клиентом при создании черновика операции и сохраняется локально до получения ответа (переживает перезапуск приложения — промт §12 «повторные запросы»). [НЕ ПОДТВЕРЖДЕНО — проектное решение]

### 7.6. CORS
Мобильные/desktop клиенты CORS не используют → CORS **отключён** («Disable CORS headers if cross-domain calls are not supported/expected»); если появится web-админка — явный allowlist origin, без `*`, без credentials для wildcard. [ПОДТВЕРЖДЕНО: OWASP REST Security CS]

### 7.7. Защита от утечек в логах (PII-маскирование)
- Структурированные логи (JSON), централизованный форматтер с denylist полей: `otp`, `code`, `password`, `pin`, `token`, `refresh`, `authorization`, `set-cookie`, `phone` (маска), `full_name` (маска), `birth_year` (не логировать), `debt` (не логировать значения). Токены — только `sha256[:8]`.
- Тела запросов не логируются по умолчанию; при debug — только через маскирующий фильтр; `DEBUG` запрещён в production конфигом.
- Кодирование данных против log injection (ASVS 16.4.1).
- Логи ошибок SMSPro — без логина/пароля/тела XML с учётными данными.

### 7.8. Секреты
- Источники: OWASP Secrets Management CS — переменные окружения «not recommended unless the other methods are not possible» (видны всем процессам, попадают в дампы); предпочтительно secret manager или mounted-secrets; не `ENV/ARG` в Docker-образе. Docker secrets: в Swarm — шифруются в Raft-логе, монтируются в tmpfs `/run/secrets/<name>`, не выставляются как env; в Compose — `secrets:` из файлов, приложение читает `*_FILE`. [ПОДТВЕРЖДЕНО: OWASP Secrets Management CS; https://docs.docker.com/engine/swarm/secrets/]
- Для сервера заказчика (один хост, без Kubernetes — [ТИПОВО]): Docker Compose + файловые секреты (`chmod 600`, владелец root, каталог вне репозитория) либо Vault/`sops`-шифрованные файлы; приложение читает `SMSPRO_LOGIN_FILE`, `SMSPRO_PASSWORD_FILE`, `JWT_PRIVATE_KEY_FILE`, `OTP_PEPPER_FILE`, `PIN_PEPPER_FILE` (раздел 3.2, вариант П1), `DB_PASSWORD_FILE`, `ONEC_*_FILE`, `BACKUP_ENCRYPTION_KEY_FILE`.
- В репозитории — только `.env.example` без значений; pre-commit secret-scanning (gitleaks/trufflehog — [ТИПОВО]).
- Ротация: JWT-ключ — раз в 90 дней с перекрытием через `kid` (старый ключ остаётся для проверки до истечения всех access); `OTP_PEPPER` — ротация с версионированием (`pepper_version` в `otp_challenges`), старые челленджи истекают за 10 мин; пароли БД/SMSPro/1С — раз в 180 дней и немедленно при увольнении администратора/подозрении; учёт «кто и когда запросил секрет» (OWASP §2.6).
- Никаких секретов во Flutter-сборке: ни SMSPro, ни 1С, ни ключей подписи (промт §16). Единственные клиентские «ключи» — публичные (Firebase config, если будет), и они не являются секретами.

---

## 8. Резервное копирование и восстановление

Предложение (RPO/RTO — подлежат утверждению владельцем; СУБД не выбрана — [ТИПОВО: PostgreSQL]):

| Параметр | Предложение | Обоснование |
|---|---|---|
| RPO (допустимая потеря данных) | ≤ 15 мин для БД POS | Заказы/продажи, не попавшие в 1С, теряются; 1С — отдельный источник истины и бэкапится заказчиком отдельно (вне нашей зоны) |
| RTO (время восстановления) | ≤ 4 ч (рабочий день), ≤ 1 ч для «деградированного» режима (приложение работает с кэшем каталога, заказы — в офлайн-очередь) | Магазин может принимать заказы в 1С напрямую, пока POS недоступна |
| Механизм | Ежедневный `pg_basebackup` + непрерывный WAL-архив (`archive_mode=on`, `archive_command` с проверкой, что файл не перезаписывается) → PITR «restore the database to its state at any time since your base backup»; `pg_dump` не подходит для PITR | [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/continuous-archiving.html] |
| Шифрование | Бэкапы шифруются до выгрузки (age/GPG, ключ — в secret manager, копия ключа у владельца офлайн); в покое и при передаче | [ТИПОВО] |
| Хранение вне сервера | Правило 3-2-1: локальная копия + объектное хранилище/второй сервер в КР (ст. 89 ЦК: хранение за рубежом = трансграничная передача) + офлайн-копия раз в месяц | [НЕ ПОДТВЕРЖДЕНО — рекомендация] |
| Ретенция | Ежедневные — 30 дней, еженедельные — 3 мес, ежемесячные — 12 мес; WAL — 30 дней | [НЕ ПОДТВЕРЖДЕНО] |
| Что ещё | Docker-секреты/конфиги (шифрованно), файлы фото товаров (если хранятся локально), аудит-архив, ключи JWT (иначе после восстановления все сессии недействительны — это допустимо) | |
| Проверка восстановления | Ежемесячно автоматический restore на staging с проверкой контрольных сумм/количества строк (`SELECT count(*)` по ключевым таблицам), раз в квартал — ручное учение с замером RTO; PostgreSQL: «Inspect the contents of the database to ensure you have recovered to the desired state» | [ПОДТВЕРЖДЕНО: PostgreSQL docs — шаги восстановления] |
| Мониторинг | Алерт при отсутствии успешного бэкапа > 24 ч и WAL-архива > 30 мин | |
| Документ | Runbook восстановления (кто, команды, порядок: БД → секреты → приложение → проверка синхронизации с 1С) — часть ТЗ, раздел развёртывания (агент 5) | |

---

## 9. Тесты безопасности (перечень для TEST_PLAN)

Идентификаторы OWASP WSTG v4.2 и MASTG. [ПОДТВЕРЖДЕНО: https://wstg.owasp.org/v4.2/4-Web_Application_Security_Testing/; https://mas.owasp.org/]

| ID теста (ТЗ) | Проверка | Ожидаемый результат | Ссылка |
|---|---|---|---|
| SEC-AUTH-001 | Перебор OTP: 6+ попыток на один challenge | 6-я попытка → `429/403`, код аннулирован, событие в аудите | WSTG-ATHN-03 |
| SEC-AUTH-002 | Повторное использование OTP после успеха | Отказ | NIST single-use |
| SEC-AUTH-003 | Истёкший OTP (TTL+1 с) | Отказ `expired` | — |
| SEC-AUTH-004 | OTP от другого challenge/purpose | Отказ | ASVS 6.6.2 |
| SEC-AUTH-005 | Rate-limit отправки: 4-я SMS за 10 мин на номер; 11-я за сутки; обход сменой IP/device_id/формата номера (`+996…` vs `996…` vs `0…`) | Лимит применяется к нормализованному E.164; обход невозможен | WSTG-BUSL-05 |
| SEC-AUTH-006 | Перебор номеров: ответы `/auth/otp/request` для существующего и несуществующего номера | Одинаковые статус, тело, время (±джиттер) | WSTG-IDNT-04 |
| SEC-AUTH-007 | Тест-режим в production | Сервер не стартует / фиксированный код не принимается | — |
| SEC-AUTH-008 | OTP в логах/метриках/трейсах/ответах SMS-провайдера | Отсутствует | OWASP Logging CS |
| SEC-SESS-001 | JWT tampering: `alg=none`, смена `role`/`sub`, подпись другим ключом, истёкший `exp`, чужой `aud` | `401` | WSTG-SESS-01, OWASP JWT CS |
| SEC-SESS-002 | Refresh reuse: использовать старый refresh после ротации | Отказ + отзыв семьи + аудит | RFC 9700 §4.14 |
| SEC-SESS-003 | Refresh с другим `device_id` | Отказ | — |
| SEC-SESS-004 | Logout / logout_all / отзыв админом → старые access/refresh | Недействительны (access — через denylist) | WSTG-SESS-06 |
| SEC-SESS-005 | Смена роли → старый access | `401 token_stale` в пределах TTL кэша | ASVS 8.3.2 |
| SEC-SESS-006 | Абсолютный/idle таймаут refresh | Отказ после срока | WSTG-SESS-07 |
| SEC-AUTHZ-001 | IDOR: продавец читает чужую корзину/заказ, клиент — чужой долг, по подмене id | `403/404` единообразно | WSTG-ATHZ-04 |
| SEC-AUTHZ-002 | Вертикальная эскалация: продавец вызывает `admin`/`cashier` endpoints | `403` | WSTG-ATHZ-03 |
| SEC-AUTHZ-003 | Field-level: ответ для кассира не содержит `cost_price`; для клиента до привязки — `debt` | Поля отсутствуют | ASVS 8.2.3 |
| SEC-AUTHZ-004 | Step-up: отмена транзакции без свежего подтверждения (`step_up_until` истёк или отсутствует) | `403 step_up_required` | Проектное требование раздела 5.3 (ASVS 8.1.4 — L3-требование к **документированию** контекстных факторов и step-up в ТЗ, а не функциональный тест; ASVS 6.8.4 — проверка recentness, применимо при внешнем IdP) |
| SEC-AUTHZ-005 | Скидка сверх лимита роли в запросе | Отказ/отправка на согласование | WSTG-BUSL-01 |
| SEC-AUTHZ-006 | Mass assignment: лишние поля (`role`, `price`, `discount`) в JSON | Отклонены (`additionalProperties:false`) | OWASP Input Validation CS |
| SEC-API-001 | Replay финансового POST с тем же `Idempotency-Key` | Тот же ответ, одна операция | IETF draft §2.6 |
| SEC-API-002 | Тот же ключ, другой payload | `422` | IETF draft §2.7 |
| SEC-API-003 | Параллельные запросы с одним ключом | Одна операция, второй — `409` | — |
| SEC-API-004 | Тело > лимита; неверный Content-Type; запрещённый метод | `413`/`415`/`405` | OWASP REST CS |
| SEC-API-005 | TLS: SSLv3/TLS1.0/1.1, слабые шифры, HSTS, cleartext HTTP | Отклонено; HTTP → редирект/закрыт | WSTG-CRYP-01 |
| SEC-API-006 | SQL/NoSQL-инъекции в поиске каталога (название, артикул, штрихкод) | Параметризованные запросы | WSTG-INPV-05 |
| SEC-API-007 | Ошибки: стек-трейсы, версии ПО, заголовок `Server` | Отсутствуют | WSTG-ERRH-01/02 |
| SEC-LOG-001 | PII в логах: телефон, ФИО, долг, токены | Маскированы/отсутствуют | ASVS 16.2.5 |
| SEC-LOG-002 | Попытка `UPDATE/DELETE audit_logs` под ролью приложения | Ошибка прав | ASVS 16.4.2 |
| SEC-MOB-001 | Android: биометрический вход на устройстве с Frida-хуком `onAuthenticationSucceeded` без CryptoObject | Токен не расшифровывается | MASTG-TEST-0018/0327 |
| SEC-MOB-002 | Android: добавление нового отпечатка → биометрический токен | Инвалидирован, требуется OTP | MASTG-BEST-0037 |
| SEC-MOB-003 | iOS: re-enroll Face ID → Keychain item | Недоступен | Apple `biometryCurrentSet` |
| SEC-MOB-004 | iOS: опора только на `LAContext.evaluatePolicy` | Не используется для доступа к токену | MASTG-TEST-0266 |
| SEC-MOB-005 | Android backup/восстановление → secure storage | `allowBackup=false`, токены не переносятся | pub.dev flutter_secure_storage |
| SEC-MOB-006 | Секреты в APK/IPA/EXE (strings, `flutter_assets`) | Нет SMSPro/1С/ключей | промт §16 |
| SEC-MOB-007 | Скриншоты/экран «Недавние» с финансовыми данными (`FLAG_SECURE` на экранах долга/кассы — опция) | По решению заказчика | [НЕ ПОДТВЕРЖДЕНО] |
| SEC-SEC-001 | Секреты в репозитории/образах/`docker inspect` | Отсутствуют | OWASP Secrets CS |
| SEC-BCK-001 | Восстановление из бэкапа на staging | Успешно в пределах RTO, данные совпадают | PostgreSQL docs |
| SEC-SMS-001 | Недоступность SMSPro | Понятная ошибка, ретрай с backoff, без утечки учётных данных | промт §17 |

Инструменты (типовые): OWASP ZAP/Burp для API, `sqlmap`, `testssl.sh`, `jwt_tool`, Frida + objection/MASTG-скрипты, MobSF для статики, `gitleaks`. [ТИПОВО]

---

## 10. Модель угроз (STRIDE, кратко)

STRIDE: Spoofing → аутентификация; Tampering → целостность; Repudiation → учёт; Information Disclosure → конфиденциальность; Denial of Service → доступность; Elevation of Privilege → авторизация. [ПОДТВЕРЖДЕНО: OWASP Threat Modeling CS]

Активы: учётные записи сотрудников и клиентов; телефоны/ФИО/год рождения; долги и взаиморасчёты; цены и скидки; заказы/продажи/возвраты; учётные данные SMSPro и 1С; аудит; бэкапы.

| Категория | Угроза (пример для POS) | Вероятность / влияние | Контрмеры (разделы) |
|---|---|---|---|
| **S**poofing | SIM-swap/перехват SMS → вход от имени кассира; подделка device_id; кража refresh с устройства; рутованное устройство обходит `local_auth`; подделка клиента к 1С | средняя / высокое | OTP + второй фактор для финансовых ролей (1.1, 3), короткие TTL, криптопривязка биометрии (3.2), reuse detection (2.2), уведомления о входе (ASVS 6.3.5), проверка смены SIM — не реализуемо без оператора (НЕ ПОДТВЕРЖДЕНО), TLS к 1С |
| **T**ampering | Изменение цены/скидки/количества в запросе; модификация JWT; правка аудита; подмена ответа SMSPro/1С (MITM) | высокая / высокое | Серверный пересчёт цен и правил (промт §11), схемы, подпись JWT, append-only аудит (6.2), TLS 1.3 (7.1), идемпотентность (7.5) |
| **R**epudiation | Кассир отрицает отмену транзакции/скидку; общий аккаунт Windows | высокая / среднее | Персональные учётные записи, step-up на критические операции с `step_up_method` в аудите (5.3), `reason` обязателен, хэш-цепочка аудита |
| **I**nformation Disclosure | Перебор номеров → список клиентов; долги видны продавцу; PII в логах; утечка БД → OTP-хэши/телефоны; бэкап без шифрования; трансграничная передача через зарубежные SaaS | средняя / высокое (штрафы ст. 413-2/413-3, репутация) | Нейтральные ответы (1.4), field-level DTO (5.2), маскирование (7.7), HMAC с pepper для OTP (1.2), шифрованные бэкапы в КР (8), минимизация полей (ст. 78) |
| **D**enial of Service | SMS-flood → исчерпание баланса SMSPro и блокировка входа; блокировка аккаунтов кассиров перебором; падение сервера заказчика | средняя / высокое (магазин не продаёт) | Лимиты на номер/IP/device + глобальный circuit breaker (1.3), «не блокировать аккаунт» (1.3), офлайн-режим чтения каталога и очередь заказов (агент 3/5), бэкапы и RTO (8) |
| **E**levation of Privilege | Продавец вызывает endpoint кассира; mass assignment `role`; старый токен после понижения прав; админ меняет свою роль на owner | средняя / высокое | Deny by default, проверка на каждом запросе (5.3), `additionalProperties:false`, `permissions_version` (2.2), четырёхглазный принцип для назначения `owner` (step-up + подтверждение владельца) |

Остаточные риски, которые должны быть явно приняты заказчиком: (1) SMS как канал OTP (SIM-swap, перехват) — NIST «restricted»; (2) Windows-POS без криптопривязки биометрии (biometric_refresh не выдаётся, разблокировка — серверный PIN); (2а) полная повторная аутентификация сотрудников раз в 7 дней вместо 12/24 ч по NIST AAL2 (компенсация — 30-минутная idle-блокировка с биометрией/PIN); (3) отсутствие pinning в Release 1; (4) зависимость от одного сервера заказчика (без HA); (5) юридическая неопределённость ст. 48/80 ЦК для любых будущих функций распознавания лица.

---

## 11. Открытые вопросы (для 14_OPEN_QUESTIONS.md)

1. Способ входа сотрудников: макет показывает «логин/телефон + пароль» и «вход по карте сотрудника», промт — телефон + OTP. Нужен ли пароль/PIN для сотрудников вообще? Будут ли NFC/RFID-карты и какой считыватель?
2. Какие роли реально есть в магазине (старший продавец?), пороги скидок по ролям, суммы для step-up, кто согласует заказы в 1С (макет: «отправлен на согласование»).
3. Платформы Release 1: Windows-POS обязателен? Если да — один Windows-аккаунт на кассу или по кассиру?
4. Утверждение числовых параметров OTP/сессий (разделы 1.3, 2.2) и допустимости еженедельного повторного OTP для сотрудников.
5. Параметры аутентификации API SMSPro (логин/пароль vs ключ, HTTPS-эндпоинт, IP-allowlist) — из PDF/Swagger SMSPro, не из страницы techno.html.
6. Юридическое заключение по Цифровому кодексу КР: применимость ст. 48 ч. 5 к частным системам; допустимость «сканирования лица» даже как опции; необходимость DPIA (ст. 82) для базы клиентов >1000; требуется ли регистрация в реестре ГАЗПД (противоречие между ICNL и сайтом ГАЗПД); назначение ответственного за ПД (ст. 88, >10 работников).
7. Сроки хранения финансовых и аудиторских записей по законодательству КР о бухучёте (для раздела 6.3 и ст. 78 ЦК).
8. Где будет размещён backend и бэкапы (сервер заказчика в КР?) — влияет на трансграничную передачу (ст. 89) и выбор Firebase/зарубежных облаков.
9. Нужно ли уведомление пользователя о входе с нового устройства по SMS (стоимость) или push (требует Firebase → трансграничная передача токенов устройств).
10. Согласие клиента на обработку ПД и на SMS-уведомления: текст, версия, место хранения доказательства (нужен юрист заказчика).
11. Политика по рутованным/jailbreak-устройствам: блокировать вход кассиров или только предупреждать.
12. TTL `biometric_refresh` по ролям/платформам (раздел 3.3): принять предложенные 7 дней (сотрудник, Android/iOS) / не выдавать (Windows) / 30 дней (клиент); принять ли отклонение от NIST AAL2 (12/24 ч полной повторной аутентификации) в пользу 7 дней + 30-минутная idle-блокировка с биометрией/PIN; хранение PIN приложения по варианту П1 (серверный, с pepper) или П2 (локальный).
13. Сверить формулировки ст. 48, 63, 77–91 (особенно 79–83, 86–89) Цифрового кодекса по официальному тексту на cbd.minjust.gov.kg: карточка Кодекса № 178 — https://cbd.minjust.gov.kg/3-48/edition/35412/ru, Закона № 179 о введении в действие — https://cbd.minjust.gov.kg/4-5604/edition/35394/ru (точная дата вступления в силу: 5 или 6 февраля 2026), Закона № 58 — https://cbd.minjust.gov.kg/202269/edition/1448/ru, КоП — https://cbd.minjust.gov.kg/3-36/edition/40617/ru (размеры штрафов ст. 413-2…413-5, 228-3/228-6/228-7). В отчёте статьи изложены по тексту реестра ГАЗПД.
14. Изучить PDF OTP-API SMSPro (`documents/smspro.nikita.kg-OTP-api.pdf`): длина кода, TTL, число попыток, идентификатор проверки, одноразовость — для решения «свой OTP vs OTP-сервис провайдера» (раздел 1.2; агент 2).

---

## 12. Источники (дата обращения 2026-10-18)

- NIST SP 800-63B (rev. 3): https://pages.nist.gov/800-63-3/sp800-63b.html — §4.2.3, §5.1.3.2–5.1.3.3, §5.2.2, §5.2.10
- NIST SP 800-63B-4 (2025): https://pages.nist.gov/800-63-4/sp800-63b.html — §2.x, §3.1.3, §3.2.2, §3.2.3, §3.2.9, §5.1, §5.2
- OWASP Cheat Sheets: Authentication, Forgot Password, Multifactor Authentication, Session Management, Authorization, Logging, REST Security, HTTP Headers, Transport Layer Security, Pinning, Input Validation, Password Storage, Secrets Management, Threat Modeling — https://cheatsheetseries.owasp.org/
- OWASP ASVS 5.0: V6 (0x15), V7 (0x16), V8 (0x17), V16 (0x25) — https://github.com/OWASP/ASVS/tree/master/5.0/en
- OWASP WSTG v4.2: https://wstg.owasp.org/v4.2/4-Web_Application_Security_Testing/
- OWASP MASTG/MASWE: MASTG-BEST-0036, MASTG-BEST-0037, MASTG-TEST-0018 (исходник: https://raw.githubusercontent.com/OWASP/owasp-mastg/master/tests/android/MASVS-AUTH/MASTG-TEST-0018.md), MASTG-TEST-0327, MASTG-TEST-0266, MASTG-TEST-0267, MASWE-0020/0021/0022/0023 (перечень MASVS-AUTH: https://mas.owasp.org/MASWE/) — https://mas.owasp.org/
- RFC 9700 (OAuth 2.0 Security BCP): https://www.rfc-editor.org/rfc/rfc9700.html — §2.2.2, §4.14.2
- IETF draft-ietf-httpapi-idempotency-key-header-07 (expired Internet-Draft): https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/ ; текст: https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-idempotency-key-header
- Android: https://developer.android.com/privacy-and-security/keystore ; https://developer.android.com/identity/sign-in/biometric-auth ; https://developer.android.com/privacy-and-security/security-config ; https://developer.android.com/google/play/integrity/overview ; https://developer.android.com/google/play/integrity/setup
- Apple (страницы рендерятся JavaScript; при загрузке 2026-10-18 получены только заголовки — детали помечены ТИПОВО): https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset ; https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity
- Microsoft: https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.ui.userconsentverifier
- pub.dev: local_auth 3.0.2, local_auth_android, local_auth_windows 2.0.2, biometric_storage 5.0.1, flutter_secure_storage 11.2.0
- Docker secrets: https://docs.docker.com/engine/swarm/secrets/
- PostgreSQL continuous archiving/PITR: https://www.postgresql.org/docs/current/continuous-archiving.html
- SMSPro Nikita KG: https://smspro.nikita.kg/kg/techno.html
- Цифровой кодекс КР № 178 от 31.07.2025 (текст, использованный в отчёте): https://reestr.dpa.gov.kg/ru/npa/59 ; оглавление: https://base.spinform.ru/show_doc.fwx?rgn=168581 ; официальная карточка Минюста (текст не отдан при загрузке): https://cbd.minjust.gov.kg/3-48/edition/35412/ru
- Закон КР № 179 от 31.07.2025 «О введении в действие Цифрового кодекса КР» (карточка Минюста, текст не отдан): https://cbd.minjust.gov.kg/4-5604/edition/35394/ru ; Закон № 180 от 31.07.2025 о внесении изменений в связи с принятием ЦК: https://cbd.minjust.gov.kg/4-5605/edition/35396/ru
- Закон КР № 58 от 14.04.2008 (карточка spinform, статус «Документ утратил силу с 6 февраля 2026 года»): https://base.spinform.ru/show_doc.fwx?rgn=22274 ; карточка Минюста (только шапка): https://cbd.minjust.gov.kg/202269/edition/1448/ru
- Кодекс КР о правонарушениях № 128 от 28.10.2021 (карточка Минюста, текст не загружался): https://cbd.minjust.gov.kg/3-36/edition/40617/ru
- ГАЗПД при Кабинете Министров КР: https://dpa.gov.kg/ru/question/7
- ICNL, «Руководство по персональным данным: Цифровой кодекс КР» (февраль/апрель 2026): https://www.icnl.org/wp-content/uploads/KG-Personal-Data-Guidance-Note_Digital-Code_February-10-2026_RU.pdf
- Economist.kg (10.09.2025) о реестре и штрафах: https://economist.kg/exclusive/2025/09/10/komu-i-zachiem-rieghistrirovatsia-v-rieiestrie-piersonalnykh-dannykh-kr-i-chiem-ghrozit-otkaz-obzor-economist-kg/
- 24.kg (22.05.2026) о постановлении Кабмина по биометрии в госресурсе: https://24.kg/obschestvo/374890_utverjdenyi_novyie_trebovaniya_khraneniyu_izaschite_biometricheskih_dannyih/

---

## 13. Журнал проверки (правки по замечаниям независимого проверяющего, 2026-10-18)

| № | Серьёзность | Замечание | Что исправлено | Проверка (2026-10-18) |
|---|---|---|---|---|
| 1 | major | Ссылка на MASWE-0044 (404; на самом деле — «Dependencies with Known Vulnerabilities», MASVS-CODE); цитаты Frida не подтверждены по телу страниц | Ссылка на MASWE-0044 удалена из 3.1 и 12; заменена на MASWE-0020 «Local Authentication Can Be Bypassed» (+ смежные 0021/0022/0023, MASVS-AUTH). Цитаты «relies on the callback onAuthenticationSucceded being called» и «will bypass authentication when the CryptoObject is not used in the authenticate method» подтверждены по исходнику MASTG-TEST-0018 (раздел «Fingerprint bypass») на GitHub; [ПОДТВЕРЖДЕНО] оставлено только для идентификаторов/заголовков MASTG-TEST-0018/0327/0266/0267, BEST-0036/0037; содержание BEST-0036/0037 понижено до ТИПОВО | WebFetch https://mas.owasp.org/MASWE/ (перечень MASVS-AUTH: MASWE-0018…0025; MASWE-0044 в MASVS-CODE); WebFetch raw.githubusercontent.com/OWASP/owasp-mastg/master/tests/android/MASVS-AUTH/MASTG-TEST-0018.md |
| 2 | major | Противоречие: biometric_refresh 30 дней для всех vs refresh сотрудника 7 дней; Windows без криптопривязки; несогласованность с NIST AAL2 | В 3.3 добавлена таблица «biometric_refresh TTL по ролям/платформам»: сотрудник Android/iOS — 7 дней (= обычному refresh), Windows — не выдаётся, без Class 3 — не выдаётся (PIN), клиент — 30 дней; обоснование, почему криптопривязанная биометрия закрывает idle-таймаут, но не заменяет периодический OTP; принцип «biometric_refresh ≤ обычного refresh» добавлен в 2.2; в 2.2 добавлена 30-минутная idle-блокировка экрана и явное отклонение от 12/24 ч NIST как остаточный риск (раздел 10, п. 2а); сводка (раздел 0, стр. 3–4) и открытые вопросы (№12) обновлены | NIST 63B-3 §4.2.3 и 63B-4 §2.2 — WebFetch pages.nist.gov |
| 3 | major | PIN приложения: Argon2id без pepper перебирается офлайн; нет обоснования серверного хранения | В 3.2 (Windows) добавлена таблица вариантов П1 (серверный `Argon2id(pepper ∥ pin ∥ user_id)` с `PIN_PEPPER` вне БД, rate-limit по user_id и device_id), П2 (локальная обёртка refresh), П3 (комбинация) с плюсами/минусами; выбран П1; `PIN_PEPPER_FILE` добавлен в 7.8 | Параметры Argon2id — OWASP Password Storage CS (ранее подтверждено) |
| 4 | minor | Неточность уровней требований NIST (SHALL/SHOULD; 30 мин не упомянуты; §5.1 — SHOULD NOT) | 2.1: указано 63B-3 §4.2.3 — SHALL 12 ч / 30 мин; 63B-4 §2.2 — SHALL наличие таймаута, SHOULD ≤24 ч / ≤1 ч; §5.1 — «SHOULD NOT be placed in insecure locations»; 2.2: idle 24 ч для сотрудников пересмотрен — добавлена блокировка экрана через 30 мин + биометрия/PIN | WebFetch pages.nist.gov/800-63-3 и /800-63-4 (цитаты получены) |
| 5 | minor | «6 цифр ≈ 19,9 бит — нижняя граница» скрадывает несоответствие 63B-3 | 1.1 переписано: по 63B-3 6 цифр (19,93 бит) формально ниже 20 бит; по 63B-4 §3.1.3.2 «at least six decimal digits (or equivalent)» допустимы явно; проект опирается на 63B-4 | WebFetch pages.nist.gov (обе цитаты) |
| 6 | minor | «Закон № 95 от 19.05.2025» не подтверждён источниками | Упоминание удалено с пометкой [НЕ ПОДТВЕРЖДЕНО]; оставлена ссылка на ICNL (штрафы ст. 413-2…413-5 с 23.11.2025; новые составы 228-3/228-6/228-7 — одновременно с ЦК); расхождение 5 (ICNL) vs 6 (spinform) февраля зафиксировано явно; перечень редакций Закона № 58 приведён по карточке spinform | WebFetch base.spinform.ru (rgn=22274: редакции № 129, 142, 53, 61; «утратил силу с 6 февраля 2026»); текст PDF ICNL извлечён локально (pypdf) и процитирован |
| 7 | minor | Не упомянут OTP-сервис SMSPro и Swagger | В 1.2 добавлен абзац «Альтернатива: OTP-сервис SMSPro» со сравнением плюсов/минусов, статусом [НЕ ПОДТВЕРЖДЕНО — PDF не изучен] и отсылкой к агенту 2; 1.6 дополнен полным перечнем ссылок techno.html; открытый вопрос №14 | WebFetch smspro.nikita.kg/kg/techno.html (ссылки на OTP-API PDF и SwaggerHub присутствуют) |
| 8 | minor | Страницы Apple отдают только заголовок; «≥16 байт» не найдено | 1.5 (App Attest) и 3.2 (iOS) понижены до [ТИПОВО] с указанием способа/даты загрузки; размер challenge и поведение при переустановке из текста удалены как неподтверждённые; версия iOS 11.3+ помечена ТИПОВО; в 12 добавлена пометка о рендеринге | WebFetch developer.apple.com (обе страницы — только заголовок) |
| 9 | minor | Пересказ ASVS 16.2.5 и 8.1.4 неточен | 6: 16.2.5 изложено по тексту стандарта («enforces logging based on the data's protection level», L2) с пояснением, что хэш/маска — проектный выбор; 9: SEC-AUTHZ-004 ссылается на проектное требование 5.3, ASVS 8.1.4 оставлен как L3-требование к документированию, добавлена ссылка на ASVS 6.8.4 (recentness при внешнем IdP) | WebFetch raw.githubusercontent.com/OWASP/ASVS/master/5.0/en/0x25-V16…, 0x17-V8…, 0x15-V6… |
| 10 | minor | Драфт idempotency-key помечен как expired | 7.5 и 12: добавлен статус «expired Internet-Draft, no longer active (страница обновлена 18.04.2026), де-факто практика, не норматив» | WebFetch datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/ |
| 11 | minor | Редакторские дефекты: 15/15 мин; незавершённая фраза об `unlocked`; `wincred.h`; «без биометрической блокировки» на Windows не подтверждено | 0 и 2.2: access 15 мин (сотрудники) / 30 мин (клиенты, предложение); 2.3: фраза про `unlocked` завершена с обоснованием; 3.2: по README — «Uses wincreds.h to store into read/write into credential store», «без биометрической блокировки» → [ТИПОВО, проверить в исходниках пакета] | WebFetch pub.dev/packages/biometric_storage |
| 12 | minor | Нет полных URL карточек cbd.minjust.gov.kg; нужна сверка статей ЦК | 4.2 и 12: добавлены полные URL карточек Кодекса № 178 (3-48/edition/35412), Закона № 179 (4-5604/edition/35394), Закона № 180, Закона № 58 (202269/edition/1448), КоП (3-36/edition/40617) с пометкой «текст при загрузке не отдан»; изложения статей помечены «по тексту реестра ГАЗПД»; открытый вопрос №13 | WebSearch site:cbd.minjust.gov.kg; WebFetch карточек (получены только шапки с номером/датой) |

Не изменено (обоснование): формулировки ст. 77–91 ЦК оставлены по тексту реестра ГАЗПД, т.к. официальная база cbd.minjust.gov.kg текст статей при программной загрузке не отдаёт (рендеринг скриптом) — сверка вынесена в открытый вопрос №13.

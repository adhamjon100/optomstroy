# Дорожка LF «Вход по лицу на всех платформах» — отчёт (LF-4-01)

Дата: 2026-11-18. Ветка `develop/stages-b-g`, база — коммит `37d92e0`. **Ничего не закоммичено и не выложено.**

Основание: 13 §3.14 (пакет LF-4-01, «Готово, когда»), 12 §3.24, 15 ADR-116. Источники: записи пакетов дорожки и
пакетов GAP-APP, GAP-WIN, GAP-DEMO (`.tmp/face/handoff.md`, `.tmp/own-server/handoff.md`), итоговый отчёт прогона
2026-11-18 (`.tmp/face/final-report.md`) — все вне git; прогоны пакета GAP-DEMO (§5.4). Метки: `[КОД]` — видно в коде;
`[ВЫВОД]` — вывод исполнителя; `[ОЦЕНКА]` — оценка, не подтверждена.

## 1. Итог

- Вход по лицу сделан в коде на трёх платформах (15 ADR-116):
  - **веб-демо** — passkey браузера: привязка PRF (браузеры вне Windows), ключ входа браузера на Windows без PIN
    приложения (RSA-2048 под ключом из PRF), без PRF — гейт «Windows Hello перед вводом PIN»; планшет магазина
    биометрию не предлагает;
  - **Android** — второй уровень «Лицо или отпечаток» (Class 2, `local_auth`) по выбору пользователя; PIN не реже раза
    в 24 ч; прежний уровень S не менялся; каталог `pos-app/android` не менялся (T-BIO-027);
  - **Windows** — гейт перед PIN (W1) и вход без PIN по ключу Windows Hello в TPM (W2, канал
    `kg.optomstroy/windows_hello`), сервер — challenge и проверка подписи.
- Все автоматические T-ID 12 §3.24 зелёные (§4; T-BIO-032 — на дереве 2026-11-18, §5.3). Без автотеста — только
  ручные T-BIO-026, T-BIO-031, T-SEC-074, T-DEMO-021 (LF-4-02) и условный T-BIO-030 (пакет LF-1-03 вне объёма дорожки).
- На настоящих устройствах не проверено ничего (LF-4-02; 13 O-36, O-37). До записи ручных проверок на рабочем
  контуре `AUTH_BIO_ALLOW_WEAK=off` и `AUTH_WINDOWS_HELLO_KEY=off` (`.env.example`, `infra/env/prod.env.example`).
- Сайт веб-демо пересобран из итогового дерева: **сборка `bbda8bd878fb2d49`, ключ эпохи `ed3bd646a9840642`** (не
  изменился — данные зрителей сохранятся). На основном адресе по-прежнему `52c710aee3125846`: выкладки не было.
- LF-4-01 выполнен, **кроме выкладки демо** (сервер и сайт одним деплоем — только по «да» пользователя).

## 2. «Готово, когда» LF-4-01 (13 §3.14)

| Условие | Статус |
|---|---|
| все автоматические T-ID 12 §3.24 зелёные | да (§4, §5; T-BIO-032 — на дереве 2026-11-18, §5.3) |
| причин `not_done` у них в `trace_test_ids.py` нет, кроме ручных | да: `not_done` в охвате дорожки — T-BIO-026, T-BIO-031 (ручные) и T-BIO-030 («условно»: LF-1-03 вне объёма, 13 §3.14); T-SEC-074, T-SEC-075 и T-DEMO-* скрипт не трассирует (не класс A этапа D) |
| сборки Windows и веб-демо | да: release Windows дерева GAP-WIN (2026-11-18), сайт `bbda8bd878fb2d49` (GAP-DEMO); дополнение 2026-11-19: итоговое дерево (после own-server:FIX-app, wave2:APP-POLISH и wave2:WIN-PACK) на Windows не собиралось — §5.3, §7 |
| проверки документов | да (§5.5); не выполнен только `redocly lint` (нет пакета офлайн) |
| отчёт `docs/stages/LF_face_login_report.md` | этот файл |
| одна выкладка демо (серверная часть и сайт вместе) | **нет** — ждёт «да» пользователя (README веб-демо «Выкладка») |

## 3. Пакеты дорожки

| Пакет | Статус |
|---|---|
| LF-G, LF-0-01…LF-0-05 (ТЗ) | выполнено 2026-11-08 |
| LF-1-01, LF-1-02 (Windows W1, SCR-08) | да: T-BIO-028, T-BIO-029 |
| LF-1-05 (сборка Windows, чек-лист) | сборка и чек-лист — да (GAP-WIN): release дерева GAP-WIN (2026-11-18) — код 0, T-BIO-032 (2) 1/1 (дополнение 2026-11-19: итоговое дерево на Windows не собиралось — §5.3, §7); чек-лист T-BIO-031 — `docs/customer/WINDOWS_HELLO_CHECKLIST.md`. **Передача владельцу — решение пользователя** |
| LF-1-06, LF-1-07 (Windows W2) | да: T-BIO-032, T-BIO-036 (шаг (8) «отказ по сессии ключ не удаляет» — GAP-APP) |
| LF-2-01…LF-2-06 (сервер, Android, Dart) | да: T-BIO-019…T-BIO-025, T-BIO-027, T-BIO-033…T-BIO-035, T-BIO-037, T-SEC-076 |
| LF-3-01…LF-3-06 (веб-демо) | да: T-DEMO-015…T-DEMO-020, T-DEMO-022…T-DEMO-024; полный смоук в Chrome и Edge на сборке `bbda8bd878fb2d49` (§5.4) |
| LF-4-01 (сквозная проверка) | этот отчёт; **выкладки нет** |
| LF-4-02 (ручные проверки) | **нет**: нужны ПК с ИК-камерой (O-36) и телефоны Android (O-37) |

Сверх плана дорожки (в итоговом дереве, в сборках выше): слой блокировки в сессии с входом по лицу, проверка подписи RSA
в шиме демо, исправления ревью; указание владельца 2026-11-18 — точки PIN, сетка товаров, адаптивность (пакеты
PIN-DOTS, RESP-GRID, RESP-AUDIT-FIX, GAP-APP); остатки «вставка и иконки» (PI-LEFTOVERS).

## 4. T-ID 12 §3.24

| T-ID | Вид | Статус и доказательство |
|---|---|---|
| T-BIO-019 | unit | зелёный — `android_biometric_authenticator_test.dart` (pos-app, §5.1) |
| T-BIO-020, T-BIO-021 | unit, widget | зелёные — `biometric_unlock_adapter_test`, `auth_usecases_test`, `unlock_screen_test`, `settings_repositories_test`, `weak_security_section_test` |
| T-BIO-022…T-BIO-025, T-BIO-034 | e2e, unit, contract | зелёные — `weak-biometrics.spec.ts`, `sessions.e2e-spec.ts`, `profile.profile-spec.ts`, `app-config.spec.ts` (pos-api, §5.2); `auth_dto_contract_test.dart` |
| T-BIO-026 | manual (B) | **не выполнен** — телефоны O-37, онлайн-сборка APK (LF-4-02) |
| T-BIO-027 | static | зелёный — `android_build_config_test.dart`; `pos-app/android` не менялся |
| T-BIO-028, T-BIO-029 | unit, widget, golden | зелёные — `hello_gate_users_test`, `profile_cache_test`, `session_flow_test`, `secure_storage_test`, `unlock_screen_test`, `auth_golden_test` |
| T-BIO-030 | widget | `not_done` «условно» — пакет LF-1-03 вне объёма дорожки |
| T-BIO-031 | manual | **не выполнен** — ПК с Windows Hello Face (O-36); чек-лист готов (LF-1-05) |
| T-BIO-032 | build | зелёный на дереве GAP-WIN 2026-11-18 — (1) release, код 0; (2) `windows_hello_channel_test.dart` 1/1 (`device_not_present`, Windows Hello на этой машине не настроен); дополнение 2026-11-19: на итоговом дереве (1) и (2) не повторялись — WIN-PACK остановился на предусловиях (код 2: нет архивов PDFium/SQLite, сеть запрещена) |
| T-BIO-033 | unit, widget, e2e | зелёный — `kiosk/access.spec.ts`, `lifecycle-reconnect.spec.ts`, `kiosk_biometrics_test.dart`, `biometric_unlock_adapter_test.dart` |
| T-BIO-035, T-BIO-037, T-SEC-076 | e2e, unit | зелёные — `hello-key.spec.ts`, `hello-key.e2e-spec.ts`, `lifecycle-reconnect.spec.ts` |
| T-BIO-036 | unit, widget, golden | зелёный — `windows_hello_key_test`, `hello_key_unlock_test`, `unlock_hello_key_*`, `hello_key_refusal_keeps_key_test` (шаг (8)), `auth_golden_test` |
| T-SEC-074 | security (B) | **не выполнен** — рутованное устройство (Q-037), LF-4-02 |
| T-SEC-075 | review | выполнен этим пакетом чтением кода (§5.6): (1) нет; (2) есть; (3) на Android нет |
| T-DEMO-015 | unit | зелёный — `demo-passkey.test.mjs` 37/37 |
| T-DEMO-016 | Dart, static | зелёный — `demo_passkey_test.dart`, `demo_root_wiring_test.dart` (в полном прогоне pos-app); `check_layers.py` 0 |
| T-DEMO-017…T-DEMO-019, T-DEMO-022…T-DEMO-024 | e2e CDP | зелёные в Chrome 157 и Edge 157 — `smoke.mjs` шаг `passkey` (§5.4) |
| T-DEMO-020 | static | зелёный — `check-site` 28/28 (п. 12) |
| T-DEMO-021 | manual | **не выполнен** — после выкладки, на устройствах владельца (LF-4-02) |

`trace_test_ids.py` (этап D): в охвате 198, с тестом 178, `not_done` с причиной 20, без теста и причины 0.

## 5. Проверки

### 5.1 pos-app (последний полный прогон 2026-11-18 — GAP-WIN, по дереву после GAP-APP; 2026-11-19 — APP-POLISH, ниже)

- `flutter analyze` — No issues found; `flutter test --concurrency=4` (весь pos-app, с golden) — 3489/3489; эталоны
  прогоном не переписаны (sha1 754 PNG до и после).
- `check_layers.py` — 722 файла, 0 нарушений; `check_no_double_money.sh` — OK.
- На 2026-11-18 после GAP-WIN pos-app не менялся: 1971 файл снимка GAP-WIN (`lib`, `test`, `windows`,
  `integration_test`, `pubspec`) побайтно те же (сверка sha1 в GAP-DEMO); `app_localizations*.dart` сборка веба
  перегенерировала теми же байтами.
- Дополнение 2026-11-19: после GAP-WIN pos-app меняли пакеты own-server:FIX-app (`cart_summary.dart`),
  wave2:APP-POLISH (`otp_field`, `app_text_field`, `search_bar`, `discount_input`, `app_dropdown`, `app_theme`,
  `windows_hello_gate`, `pubspec.yaml/lock`, тесты и эталоны) и wave2:WIN-PACK (`windows/CMakeLists.txt`,
  `windows/runner/CMakeLists.txt`). Последний полный прогон — APP-POLISH 2026-11-19: `flutter analyze --no-pub` — No
  issues found; `flutter test` — 3511/3511; `check_layers.py` — 722 файла, 0 нарушений (до него — own-server:regress:app,
  3497/3497).

### 5.2 pos-api (regress:api, 2026-11-18; код pos-api после него не менялся `[ВЫВОД]` по записям пакетов)

- `lint`, `madge` (653 файла, циклов нет), `check:permissions` (82 кода, 8 ролей) — код 0.
- `test:all` (в том числе `test:e2e`, `test:kiosk`) — 2065 тестов прошли, 8 пропущены (proxy), 0 красных;
  `test:e2e:pos` 1/1, `test:e2e:cashier` 1/1, kiosk-smoke 13/13.

### 5.3 Windows

- Release-сборка дерева GAP-WIN (2026-11-18; тогда — итоговое): код 0; пакет 54 220 989 байт, 31 файл. Находки
  сборки (устаревший `kernel_blob.bin` после debug-сборки, нет DLL Visual C++, `hello_channel.lib` в пакете, PDFium из
  сети) — в записи GAP-WIN, для 16 §10.7 и 13 RM-H-007.
- `windows_hello_channel_test.dart` — 1/1, `device_not_present`; `createKey` и `sign` не вызывались.
- Сквозные тесты Windows против локального стека (regress:integration, до GAP-APP): вход 3/3, планшет и касса 4/4.
- Настоящий диалог Windows Hello ни в одном прогоне не вызывался.
- Дополнение 2026-11-19: итоговое дерево на Windows не собиралось (ни Debug, ни Release). Правки CMake WIN-PACK
  проверены только конфигурацией с архивами-заглушками и `cmake -P` команд установки. `windows_hello_channel_test` 1/1 —
  последний на дереве GAP-WIN; `auth_flow` 3/3 и `kiosk_flow` 4/4 — последние в regress:integration, до GAP-APP и
  APP-POLISH.

### 5.4 Веб-демо (GAP-DEMO, 2026-11-18)

- `powershell -ExecutionPolicy Bypass -File demo/web/build-web-demo.ps1` — код 0: бэкенд 35 с (sha `bd2c294c7b67…` — тот же, что у
  `d8985fa569ed7f4a`), `flutter build web` (новый `main.dart.js`, sha `c53dca95853c…`: GAP-APP — точки PIN, сетка,
  адаптивность), страница (`demo-tokens.css` 1.4.0). **buildId `bbda8bd878fb2d49`, ключ эпохи `ed3bd646a9840642`.**
  `check-site` — 28/28 «можно выкладывать».
- `node --test demo/web/tools/test/demo-passkey.test.mjs` — 37/37.
- `smoke.mjs --port 8095 --cdp 9471 --only boot,paste,ui,f5,frozen,kiosk,kioskswitch,passkey` (OPFS,
  `http://localhost:8095`):
  - Chrome 157.0.8103.51 headless — **51/51**, падений вкладок 0, 708 с; повтор итоговым `smoke.mjs` (после
    последней правки `ev`) — **51/51**, падений 0, 1600 с (машина была нагружена: готовность демо 24 с против 6 с);
  - Edge 157.0.4341.60 headless — **51/51**, падений вкладок 0, 717 с;
  - в обоих: 0 нарушений CSP, 0 чужих хостов, 0 запросов к `/api/` сайта, 0 ответов 404, 0 исключений, 0 ошибок
    консоли.
- `node demo/web/backend/test/run-all.mjs` (полный, 36,2 мин) — **код 0, «ВСЁ ЗЕЛЁНОЕ»**: модульные 11 файлов 144/144;
  differential 8/8 (бандл, эталон, бандл — по 471 запросу, 138/138, 0 ответов 5xx, 0 расхождений шимов; контракт —
  15 групп «бандл и эталон», 0 «только бандл»; покрытие Dio 126/126); critic 29/29; PostgreSQL 17.10 — 0 отличий слоя
  БД, гонок 0, цепочка аудита цела; «медленный commit» 4/4; soak 20 мин — Node 5/5, браузер (Chrome, IndexedDB) 4/4.

Сбои прошлого прогона (regress:demo) классифицированы и исправлены — §6.

### 5.5 Документы и контракты (код 0)

`build_arb.py --check` (2178 ключей), `sync_contracts.py --check`, `trace_test_ids.py --summary` (198 / 178 / 20 / 0),
`--stage K --summary` (78 / 72 / 6 / 0), `check_secrets.py` (3291 файл, 0 находок), `check_repo_layout.py` (0 ошибок,
8 прежних предупреждений). Не выполнен `redocly lint` — пакета нет офлайн, проверяется в CI.

### 5.6 T-SEC-075 (ревью чтением)

1. Изображений лица, шаблонов и эмбеддингов нет ни в pos-api, ни в pos-app, ни в схеме (поиск по коду, миграциям,
   OpenAPI и `schema_v1.sql`): на сервере — признаки `user_profiles.biometrics_enabled` и
   `devices.biometric_enrolled_at`, сессии вида `biometric` (как у любой сессии — хэш токена) и открытый ключ Windows
   Hello (`hello_keys.public_key`, миграция `0024`) `[КОД]`.
2. Текст `biometrics_device` версии 2026-11-08 с абзацем об уровне W и ключе Windows Hello есть
   (`contracts/legal/consents_ru.md`); это проект до заключения юриста (Q-027), текущая версия — 2026-10-01.
3. В коде ветки Android «Face ID» нет. В ARB «Face ID» есть в двух ключах: `settings_bio_ios` (подпись только для iOS,
   `settings_texts.dart`) и `global_permission_biometrics` — в `pos-app/lib` не используется `[КОД]`.

## 6. Найдено и исправлено в LF-4-01 (GAP-DEMO)

1. **Смоук, шаг «замороженная вкладка», зависание 90 с.** Класс — WEB-KI-25 (падение процесса отрисовки вкладки
   Chrome на OPFS после «Продолжить здесь» и перезагрузки), не детерминировано: тот же шаг, та же строка
   (`appReady(B)` последней перезагрузки) и тот же признак (каждый `Runtime.evaluate` не отвечает), что в прогонах
   2026-10-30 с записанным `Inspector.targetCrashed`; 2026-10-30 — 5 из 12 полных прогонов, 2026-11-18 — 1 из 2. Код
   демо не причастен. Исправление `demo/web/tools/smoke.mjs`:
   - смоук слушает `Inspector.targetCrashed` и `Target.targetCrashed` (`Target.setDiscoverTargets`), пишет падения в
     `smoke.json` (`crashes`) и в строку итога («падений вкладок N»);
   - `ev` и `waitFor` в упавшей вкладке заканчиваются сразу понятной ошибкой «вкладка … упала (…, WEB-KI-25)», а не
     через 90 с;
   - в шаге frozen перезагрузка B при падении один раз повторяется в новой вкладке (как сделал бы пользователь;
     WEB-KI-25 «обновить страницу — данные сохраняются»), проверка «заказ B на месте» идёт в ней; второе падение подряд и
     падение в других шагах — провал.
   Проверено подменой (копия смоука с `Page.crash`, `--only boot,frozen`, вне git): одно падение — 11/11, падение
   замечено через 0,9 с, заказ B на месте во вкладке B2; два падения подряд — провал за 2 с (6/7).
2. **Сверка с PostgreSQL (`realpg`), «аудит за период» `$.items.length` 189 ≠ 188.** Класс — темп фоновой задачи
   «1С», не слой БД: страница `limit=200` полная (проба на бандле: 200 строк, курсор, 11 фоновых `sync.*` по
   расписанию), фоновые строки вытесняют с конца столько же строк сценария, и после их удаления остаётся 200 − 11 = 189
   на бандле и 188 на PostgreSQL (фоновых на одну больше). Исправление `demo/web/backend/test/lib/normalize.mjs`
   (`alignBackgroundPages`): если обе страницы полные и разница длин равна разнице убранных фоновых строк — строки
   сценария сравниваются по общей части; пропавшая или лишняя строка внутри общей части остаётся расхождением.
   Выравнивание видно в отчётах (`alignedAR` в `realpg`, `alignedAB` в `differential.json`, строка «фон на полной
   странице» в `realpg.md`). Проверка синтетикой — 6/6 (вне git). В полном `run-all` этого пакета выравнивание не
   понадобилось (фоновых строк на странице оказалось поровну): сбой не повторился, исправление проверено пробой и
   синтетикой.

## 7. Не проверено

- **Android** — APK здесь не собирается (Gradle из сети запрещён, O-13), телефонов нет: «слабое» лицо на прошивках, вид
  диалога, временная недоступность датчика (T-BIO-026, T-SEC-074).
- **Настоящий Windows Hello** — ИК-камеры нет, Windows Hello не настроен: ключ и подпись в TPM, окно Windows Hello
  поверх приложения (T-BIO-031).
- **PRF у Windows Hello в браузере** — только виртуальный аутентификатор CDP; без PRF работает гейт с PIN (T-DEMO-021).
- **Сборка Windows и сквозные тесты Windows на итоговом дереве** (дополнение 2026-11-19; T-BIO-032 (1)–(2),
  integration_test `auth_flow`, `kiosk_flow`). Причина — чистая сборка берёт из сети PDFium и SQLite (16 §10.7). Нужен
  кэш архивов: `scripts/package_windows.ps1 … -AllowDownload` с разрешения пользователя или два архива, переданные
  вручную. Затем прогон по командам записи wave2:DEMO-E2E; после него удалить `build/windows` и
  `.dart_tool/flutter_build`.
- **Вставка и меню браузера руками** в Chrome, Edge, Firefox, Safari и на телефоне; масштаб браузера клавишами;
  экранный диктор и TalkBack.
- **Сверка с прототипом T-UI-116** после новых пределов сетки (GAP-APP) — дополнение 2026-11-19: выполнена. Пакет
  own-server:FIX-demo поправил ожидания под 5 / 5 / 5 / 6 и прогнал сверку (сборка `bbda8bd878fb2d49`, код 0,
  33 сравнения); пакет wave2:DEMO-E2E повторил её на сборке `67c20b520903831e` (код 0, смещения те же; выросла
  только «шапка» в состоянии поиска — обводка фокуса поля `textPrimary`, 14 Q-357). Подробности — 12 T-UI-116.

## 8. Открыто

1. **Выкладка демо** (LF-4-01) — `netlify deploy` сборки `bbda8bd878fb2d49` (дополнение 2026-11-19: актуальная
   локальная сборка — `67c20b520903831e`, T-DEMO-011 для неё выполнен пакетом wave2:DEMO-E2E) делает пользователь
   (README веб-демо «Выкладка»). После неё — убрать временную пометку в начале `docs/customer/WEB_DEMO_INSTRUCTION.md`, вписать номер
   сборки в WEB-KI-14, WEB-KI-38 и README; до выкладки пометка остаётся.
2. **LF-4-02** — ручные T-BIO-026, T-BIO-031, T-SEC-074, T-DEMO-021 (O-36, O-37); решение о `AUTH_BIO_ALLOW_WEAK` и
   `AUTH_WINDOWS_HELLO_KEY` на рабочем контуре — после них.
3. **Чек-лист T-BIO-031** — передать владельцу (решение пользователя).
4. **Согласие** — текст `biometrics_device` 2026-11-08 юристу (Q-027); до него лицо и ключ Windows Hello на рабочем
   контуре не включать.
5. **ТЗ после пакетов FIX-pos-app и GAP-APP** — дополнение 2026-11-19: дописано пакетами own-server:GAP-DOCS,
   FIX-docs и wave2:SPEC-TAIL; было «не дописано» (список — записи GAP-APP и итоговый отчёт: 02, 03, 09, 12,
   13, 14, 15 ADR-116 п. 8, 17, `known_issues.md` WEB-KI-39 «только PIN»). Цвет точек PIN (с 2026-11-19 — и
   активной клетки кода, полей в фокусе) и предел колонок сетки решены в коде постановкой пакетов own-server:GAP-APP
   и wave2:APP-POLISH, а не ответом владельца `[ВЫВОД]`; в 14 Q-357 и Q-366 — «открыт — решено постановкой пакета,
   ждёт подтверждения владельца»; показать владельцу.
6. **Коммит** — по «да» пользователя; порядок и состав — итоговый отчёт прогона, раздел «Перед коммитом».

## 9. Оценка `[ОЦЕНКА]`

| Часть | План, у.е. | Сделано | Осталось |
|---|---|---|---|
| LF-0 | 11 | 11 | — |
| LF-1 | 14 | 14 | передача чек-листа (действие пользователя) |
| LF-2 | 33 | 33 | — |
| LF-3 | 23 | 23 | — |
| LF-4 | 5 | ≈ 2,5 (LF-4-01 без выкладки) | выкладка ≈ 0,5; LF-4-02 — 2 |
| **Итого по плану** | **≈ 86** | **≈ 83,5** | **≈ 2,5** |

Сверх плана: ≈ 8 у.е. (слой блокировки с лицом, RSA в шиме демо, исправления ревью) и ≈ 1 у.е. GAP-DEMO (устойчивость
смоука и сверки). Указание владельца 2026-11-18 (точки PIN, сетка, адаптивность) — вне 86, в записях GAP-APP.

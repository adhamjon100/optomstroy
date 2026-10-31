# Веб-демо «Оптомстрой POS» (Netlify, только статика)

Заказчик открывает настоящее приложение в браузере: Flutter (web) + настоящий pos-api, который работает **в браузере**
(module Web Worker `backend/backend.js` на PGlite 0.3.16), с имитатором «1С» вместо 1С. Все данные — тестовые и
хранятся только в браузере заказчика. Сайт: `optomstroy-demo-4fhvb` (решение владельца от 2026-10-29), noindex.

## Каталоги

| Путь | Что это |
|---|---|
| `backend/` | сборка браузерного бэкенда (`build-backend.mjs`), шимы, подмены, тесты — см. `backend/README.md` |
| `site-src/` | страница: загрузка, мост `__posDemo`, панель «ДЕМО», одна вкладка, сброс (`build-site.mjs`, `dev/`) |
| `tools/` | сборка сайта (`assemble-site.mjs`), проверки (`check-site.mjs`), статика как на Netlify (`serve-site.mjs`), headless-проверка собранного сайта (`smoke.mjs`), заголовки и перенаправления (`site-headers.mjs`) |
| `build-web-demo.ps1` | всё по порядку (PowerShell) |
| `netlify.toml` | каталог публикации `site` (правила — в `site/_headers`, `site/_redirects`) |
| `site/` | собранный сайт (в git не попадает) |
| `.build/` | промежуточные результаты: pos-api dist, сборка Flutter, снимок, отчёты (в git не попадает) |

## Сборка

`TEMP`/`TMP` — на `D:\optomstroy\.tmp`. Нужны Node 24, `pos-api/node_modules`, Flutter SDK (для шага Flutter) и
Python (проверка секретов). Ничего не скачивается.

```
powershell -ExecutionPolicy Bypass -File demo/web/build-web-demo.ps1            # всё
powershell -ExecutionPolicy Bypass -File demo/web/build-web-demo.ps1 -SkipFlutter   # Flutter уже собран в .build/flutter
```

По шагам:

```
node demo/web/backend/build-backend.mjs        # pos-api → backend.js, PGlite, снимок, фото, лицензии (≈ 45 с)
#   flutter build web … -o demo/web/.build/flutter; dart compile js → .build/drift_worker.js; sqlite3.wasm → .build
node demo/web/tools/assemble-site.mjs          # site/: Flutter + страница + бэкенд, demo/build.json, _headers, _redirects
node demo/web/tools/check-site.mjs             # проверки публикации; код 0 — можно выкладывать
```

После любой пересборки бэкенда сайт собирается заново (`assemble-site.mjs`): `demo/build.json` берёт ключ эпохи из
`backend/build.json` (один источник), а `check-site.mjs` сверяет sha бандла.

## Проверки

```
node demo/web/backend/test/run-all.mjs                         # бэкенд: модульные, дифференциальный, критик, PostgreSQL, soak (≈ 40 мин)
node demo/web/site-src/dev/cdp-test.mjs                        # страница с имитацией воркера (≈ 1 мин)
node demo/web/tools/smoke.mjs --storage opfs                   # собранный сайт: загрузка, вход 906 в интерфейсе, F5 (экран PIN), замороженная вкладка
node demo/web/tools/smoke.mjs --storage idb                    # [--port 8095…8099] [--cdp N] [--only boot,ui,f5,frozen]
node demo/web/tools/pdf-smoke.mjs --storage idb                # предпросмотр и печать PDF под CSP, pdf.js с сайта [--port 8097] [--cdp 9417]
node demo/web/tools/serve-site.mjs --port 8095                 # открыть сайт локально: http://127.0.0.1:8095/
```

Коды `run-all.mjs`: 0 — всё зелёное; 1 — провалы демо; 3 — провалы есть, но все — известные открытые дефекты pos-api
(`backend/test/pos-api-defects.json`, поле `tests`). Открытых дефектов сейчас нет: POSAPI-T1-01 (`/sync/status`
«Есть задержки» через час после последнего изменения плана обмена) исправлен в pos-api 2026-10-30 (05 §7.6.1
уточнение (4); `docs/known_issues.md` WEB-KI-22) и остаётся в файле для истории (`status: "исправлен"`,
`tests_history`); провал critic C4.3b/C4.10b теперь — провал демо (код 1), отчёт считает открытые и исправленные
дефекты отдельно.

Последние прогоны (2026-10-30, сборка `232b127e2352d11c`): `check-site` 26/26; `smoke.mjs` 15/15 на OPFS и на
IndexedDB; `pdf-smoke.mjs` 9/9 (сборка `a4b231dc44c76999`); `run-all.mjs --no-browser --soak-min 5` — модульные
133/133, дифференциальный 8/8 (0 отличий шима), critic 29/29 (C4.3b и C4.10b — `overall=ok`), PostgreSQL 17 — 0
расхождений слоя БД, код 1 только из-за двух критериев soak, рассчитанных на 20 мин; отдельный
`scenarios/soak.mjs --minutes 20` — 5/5. Браузерные шаги `run-all` (порты 8095–8099, CDP 9481/9482) и
`cdp-test.mjs` на последней сборке не запускались. Сценарии инструкции заказчика в интерфейсе — 12 §3.22
«Прогоны 2026-10-30».

Порты: статика 8095–8099 (`serve-site.mjs` другие не принимает); 3000, 8080, 8091, 8092 не занимать (local-stack
другого workflow). Свои процессы скрипты завершают по PID, профили Chrome удаляют.

## Выкладка (делает пользователь)

Выкладку выполняет пользователь сам (ADR-113 п. 10): вход в Netlify, превью, проверка превью, затем основной адрес.
Сайт — `optomstroy-demo-4fhvb` (решение владельца (в) от 2026-10-29). Вопрос Q-336 (марки и номера тестовых
клиентов) владелец закрыл 2026-10-31: «как есть». Перед основной выкладкой — сверка T-DEMO-011. Замечания ревью сайта
(`docs/known_issues.md` WEB-KI-33) исправлены 2026-10-30.

1. Собрать и проверить сайт (раздел «Сборка»): `check-site.mjs` — код 0. В `site/demo/build.json` — `buildId`
   выкладки; тот же номер потом виден в «ДЕМО» → «Сервис» → «Сборка».
2. Войти в Netlify (откроется браузер; делает пользователь):
   ```
   netlify login
   ```
3. Превью — из каталога `demo/web`:
   ```
   cd demo/web
   netlify deploy --no-build --dir site
   ```
   В первый раз каталог ещё не связан с сайтом, и CLI спросит, что сделать: если сайта ещё нет — создать новый
   (имя `optomstroy-demo-4fhvb`), если он уже есть в аккаунте — связать каталог с существующим `optomstroy-demo-4fhvb`.
   Связь сохраняется в `demo/web/.netlify/` (в git не попадает), дальше CLI не спрашивает. Если имя занято, нужно
   новое имя от владельца (ADR-113 п. 11 (в)). Netlify напечатает адрес превью (draft URL).
4. Проверить превью (ниже). Если что-то не так — исправить, пересобрать, повторить шаг 3.
5. Основной адрес:
   ```
   netlify deploy --no-build --dir site --prod
   ```
   Адрес сайта из вывода (Website URL / Production URL) вставить вместо `<ССЫЛКА>` в
   `docs/customer/WEB_DEMO_INSTRUCTION.md` (в начале и в «Тексте для сообщения со ссылкой») и отправить заказчику
   инструкцию и текст сообщения.

### Как проверить превью

`smoke.mjs` и `pdf-smoke.mjs` работают только с локальной статикой `serve-site.mjs` (параметра `--url` нет), поэтому
превью проверяется вручную (12 T-DEMO-004, T-DEMO-013 «повтор на превью»):

1. **Заголовки** (подставьте адрес превью вместо `<ПРЕВЬЮ>`):
   ```
   curl -sI <ПРЕВЬЮ>/                                                         # X-Robots-Tag: noindex…, Content-Security-Policy без внешних хостов
   curl -sI -H "Accept-Encoding: br, gzip" <ПРЕВЬЮ>/backend/pglite/pglite.wasm  # Content-Type: application/wasm и Content-Encoding
   curl -sI -H "Accept-Encoding: br, gzip" <ПРЕВЬЮ>/backend/pglite/pglite.data  # Content-Encoding
   curl -sI -H "Accept-Encoding: br, gzip" <ПРЕВЬЮ>/canvaskit/canvaskit.wasm    # Content-Encoding
   curl -sI -H "Accept-Encoding: br, gzip" <ПРЕВЬЮ>/main.dart.js                # Content-Encoding
   curl -sI <ПРЕВЬЮ>/backend/pglite/pgcrypto.tar.gz                           # application/gzip, без Content-Encoding (нет двойной распаковки)
   curl -s -o /dev/null -w "%{http_code}\n" <ПРЕВЬЮ>/api/v1/health            # 404
   ```
2. **Браузер.** Открыть превью в Chrome или Edge на компьютере, обычное окно, DevTools → Network и Console:
   - загрузка до экрана входа, «ДЕМО» → «Как войти»;
   - сценарии 1–7 `docs/customer/WEB_DEMO_INSTRUCTION.md` «Что попробовать»: в журнале сети нет запросов к другим
     хостам и к `/api/` Netlify, в консоли нет ошибок (кроме известного предупреждения `dio_web_adapter`);
   - «Товарный чек» → «Просмотр» показывает PDF, «Печать» открывает **диалог печати браузера** (не новую вкладку);
     автопечать «Счёта на оплату» после номера «1С» — тоже диалог (WEB-KI-26: headless-прогоны этого не видели);
   - F5 на внутреннем экране → «Введите PIN-код приложения» → тот же экран; вторая вкладка → «Продолжить здесь»;
     «ДЕМО» → «Сервис»: «Сборка» = `buildId` из шага 1, «Хранилище», «Запись на диск: работает»;
   - в конце — «Сбросить демо» (данные превью и основного адреса — разные origin, они не смешиваются).
3. Результат записать в 12 §3.22 «Прогоны 2026-10-30» (строки T-DEMO-004, T-DEMO-013: «превью Netlify»).

# Разбор 94 расхождений контракт ↔ 18 ↔ 05 ↔ реализация (2026-10-24)

Внутреннее, не для передачи программисту 1С. Источник пунктов — `99_discrepancies_internal.md`.

**Правило решения.** Целевое поведение — ТЗ для программиста 1С `docs/integration/1C_API_requirements.md` (передано заказчику). Ядро R0 v1.9 и бизнес-правила 10 не меняются.
- Контракт расходится с ТЗ — правится контракт (`CONTRACT`).
- Сервер не делает того, что ТЗ или 05 обещают от имени POS, — правится код (`SYNC` / `ORDERS` / `CUSTRET`).
- Устарели только тексты 05, 18, 13 или 14 — `DOC`.
- `NONE` — расхождения по сути нет или оно оставлено осознанно; обоснование указано в строке.

Где ТЗ пишет «к сведению: сейчас POS…» и задаёт вопрос из раздела 10, реализация остаётся до ответа заказчика. Исключение — пп. 8, 14, 15 и 89, где 05 или контракт требуют большего.

**Как проверено.** Места кода и контракта прочитаны напрямую (grep и чтение): `onec-order-payload.ts`, `onec-extension.gateway.ts`, `sync-worker.wiring.ts`, `onec-changes.service.ts` (`applyForeign`), `order-projection.ts`, `order-onec-link.service.ts`, `qr-issuer.service.ts`, `qr-status.service.ts`, `payments-jobs.ts`, `customer-create.service.ts`, `customer-matching.port.ts`, `returns-onec.service.ts`, `return-onec-payload.ts`, `onec-check.service.ts`, `onec-error.ts`, `sync-job.processor.ts`, `fake-exchange-plan.ts`, а также фикстуры `contracts/onec/fixtures/*`.
- Контрольная цифра EAN-13 для `460000000001?` пересчитана: 5.
- Этап G ни одного пункта не закрыл: всё описанное в 99 в коде подтверждено.

Сокращения в колонке «Файлы»:
- K — `contracts/onec/onec-http-service.v1.yaml`;
- F — `contracts/onec/fixtures/`;
- A — `contracts/onec/odata-allowlist.yaml`;
- ТЗ — `docs/integration/1C_API_requirements.md`;
- 05, 18, 14, 13 — `docs/specification/…`.

## Итог по владельцам

| Кто | Пункты |
|---|---|
| CONTRACT (48) | 1, 2, 3, 5, 6, 7, 10, 11, 12, 13, 16, 17, 18, 19, 20, 21, 24, 26, 27, 29, 30, 32, 33, 34, 35, 36, 37, 39, 43, 44, 45, 46, 48, 50, 52, 53, 55, 57, 60, 62, 63, 72, 73, 76, 77, 79, 82, 92 |
| SYNC (9) | 8, 14, 15, 28, 31, 40, 68, 69, 89 |
| ORDERS (2) | 49, 75 |
| CUSTRET (3) | 58, 71, 74 |
| DOC (21) | 9, 22, 23, 38, 47, 54, 59, 61, 65, 66, 70, 78, 80, 81, 83, 84, 85, 86, 87, 88, 90 |
| NONE (11) | 4, 25, 41, 42, 51, 56, 64, 67, 91, 93, 94 |

Всего 94. Часть пунктов — дубли из разных частей ТЗ, они решаются одной правкой.

## Таблица

| № | Суть | Решение | Кто | Файлы |
|---|---|---|---|---|
| 1 | `OrderCustomer.ref` в контракте обязателен и без `null`; POS шлёт `null` для «Розничного покупателя» | По ТЗ 1.2 п.4 и 6.6 («исключение из контракта v1») сделать `OrderCustomer.ref` `nullable: true` с описанием Q-026. Добавить фикстуру заказа розничного покупателя. Код не меняется | CONTRACT | K (OrderCustomer), F/orders-create.request.retail.json (новая) |
| 2 | `createdByUserCode` и `cashierUserCode` — логины в 18 и фикстурах, в коде — UUID; допущение Q-129 «код в Комментарий» не выполнено | Целевое по ТЗ (6.6, 6.13, 6.14, Г.3): UUID `users.id` (в QR допускается `system`), в комментарий код не пишется. Описания полей в K, значения в фикстурах — UUID. Допущение Q-129 в 14 переписать: «UUID пользователя POS — в `createdByUserCode`, в Комментарий не дублируется» | CONTRACT | K (OrderCreateRequest, QrCreateRequest, PaymentCreateRequest), F/orders-create.request.json, F/payments-qr.request.json, F/payments-create.request.json, 14 (Q-129), 18 §4.5/§4.12 |
| 3 | Формат `comment`: в K и 18 — `POS <uuid>`, в фикстуре — усечённый UUID с именем, в коде — полный | По ТЗ 6.6: `x-comment-format` = `POS <полный externalId> · <номер заказа POS>[ · заявка клиента][ · комментарий]`, `maxLength: 1000`. Фикстуру привести к этому формату | CONTRACT | K (OrderCreateRequest.comment), F/orders-create.request.json, 18 §3.7/§4.5 |
| 4 | `clientChecks` и `organizationRef` всегда `null` в коде, в фикстуре заполнены | Схема K допускает `null`; ТЗ 6.6 прямо говорит «сейчас POS передаёт `null`». Фикстура с датами — допустимый пример. Расхождения в поведении нет | NONE | — |
| 5 | `OrderLine.discountPercent` и `amount`: в 18 — скидка на документ и строки; в коде — ручной процент и `amount` после обеих скидок | По ТЗ 1.2 п.5 и 6.6: описать в K, что `discountPercent` — только ручная скидка (та же, что у заказа), а `amount` — итог строки после скидки клиента 1С и ручной (может не равняться цена×кол-во×(1−%)) | CONTRACT | K (OrderLine, OrderCreateRequest.discountPercent), 18 §4.5 |
| 6 | `/external-ids`: `since` обязателен, а ручная привязка вызывает метод без `since` | По ТЗ 6.20 (рекомендованный вариант): `since` — `required: false`, `x-status: proposed`; без `since` — все записи; порядок — по убыванию `ДатаСоздания`, затем `ВнешнийИд`. Предложение `GET /orders?number=` записать как `x-status: proposed`. Код не меняется | CONTRACT | K (/external-ids), 05 §6.3/§6.4 п.4, 18 §4.17 |
| 7 | Таймаут `POST /orders`: в 18 — 30 с, в коде — 6 с | Целевое по ТЗ 4.9 — 6 с (как в коде). Внести в K таблицу таймаутов POS из ТЗ 4.9 (в `info` или `x-timeout` у методов). 18 §3.9 исправить | CONTRACT | K (info, /orders), 18 §3.9 |
| 8 | Элементы `/changes` `Document_ЗаказКлиента`, ПКО, поступления и `QrPaymentStatus` без обработчика: ack снимает их регистрацию | По 05 §6.2 п.3 до `ONEC_MODE=extension` на проде нужны обработчики всех типов состава; иначе нарушается ядро §22.8 (ack только после применения). Подключить `ChangeItemHandler`:<br>• `QrPaymentStatus` — публикация в существующую очередь `payments.onec-qr-status` в транзакции сообщения; применяется `applyOnecQrStatus` по правилам статуса QR, что ТЗ 6.15 уже допускает: «когда обработка будет подключена, побеждает первое»;<br>• `Document_ЗаказКлиента` — `OrderProjector.apply` (source sync) только для элементов с известным `externalId`, идемпотентно с опросом.<br>ПКО и поступления остаются без применения до Q-012: разовая перерегистрация после ответа (п. 31). Пометки ТЗ «пока не применяет» для заказов и QR обновить | SYNC | pos-api/src/jobs/sync/sync-worker.wiring.ts, pos-api/src/sync/apply/ (новые handlers), pos-api/src/orders/order-projection.ts, pos-api/src/jobs/payments/payments-jobs.ts, ТЗ 5.1/5.3 п.11/5.7/6.15, 05 §6.2 п.3 |
| 9 | `POST /payments`: 18 и допущение 14 по Q-012 предполагают вызов через outbox; код его не ставит | Целевое по ТЗ 1.2 п.2 и 6.13: в первой версии метод не вызывается; это совпадает с 05 §6.7.3 п.5 и 14 §3.12. Исправить 18 §4.11, §5.2–§5.5 и формулировку допущения в основной таблице 14 по Q-012 | DOC | 18 §4.11/§5.2–§5.5, 14 (Q-012) |
| 10 | x-retry `getQrPaymentStatus`: «без ответа до expiresAt+60 с → manual_confirm (no_webhook)»; в коде такого перехода нет | По ТЗ 6.15 и 7, FQ-PAY-03: автоматического перевода нет. Переписать x-retry: опрос каждые `QR_ONEC_POLL_SECONDS`, пока платёж в `qr_shown`, не дольше expiresAt+60 с; по сроку — `qr_expired` таймером POS; поздняя оплата — `manual_confirm` (late_payment) | CONTRACT | K (/payments/{externalId}/status x-retry) |
| 11 | Отмена QR при перевыпуске: K и 18 — повторы 1/2/5 мин; в коде — одна синхронная попытка до 6 с | По ТЗ 4.7 и 6.16: перед перевыпуском — одна синхронная попытка до 6 с, без повторов. После аннулирования — через 1 мин, 2 мин, далее каждые 5 мин до срока QR (без срока — не дольше часа). Код этому соответствует (`cancelVoided`). Поле `reference` в `QrCancelRequest` не добавлять: это вопрос 66 ТЗ | CONTRACT | K (/qr/cancel x-retry), 18 §4.14, 05 §6.7.3 |
| 12 | Фикстуры QR: `expiresAt` 2026-10-21T14:20 уже в прошлом | Перенести `expiresAt` (и связанные `createdAt`/`paidAt`) в будущее, например на 2099 год. В `QrCreateResponse.expiresAt` описать по ТЗ 6.14: должен быть в будущем, иначе POS берёт «выдача + QR_TTL_MINUTES» | CONTRACT | F/payments-qr.201.json, F/payments-qr.200.json, F/payments-status.*.200.json, K (QrCreateResponse) |
| 13 | Штрихкод 4600000000017 с неверной контрольной цифрой (верно …015); в catalog-card.200 склад и вид цены …0002 не описаны в `/changes` | Заменить на 4600000000015 (пересчёт: 5) в обеих фикстурах. Добавить в changes.catalog.page1 элементы `Catalog_Склады` и `Catalog_ВидыЦен` с ref …0002 или заменить ref в catalog-card на описанные | CONTRACT | F/changes.catalog.page1.200.json, F/catalog-card.200.json |
| 14 | `imageFileRef` в K — главная картинка, код поле не сохраняет и выбирает по `sort_order` | Контракт для 1С — источник истины (ТЗ, преамбула): если 1С заполнит `imageFileRef`, POS должен его учесть. Главной делать картинку `imageFileRef`, если файл принадлежит этому товару, иначе — по `sort_order`. Учитывать предложение `isMain`, если пришло. В K добавить `ImageFileChange.isMain` с `x-status: proposed`. Пометку в ТЗ 5.4 обновить | SYNC | pos-api/src/sync/apply/ (catalog applier), pos-api/src/sync/images/image-files.handler.ts, K (ImageFileChange), ТЗ 5.4 |
| 15 | Бренд: в 05 §5.3 есть `products.brand`, в K поля нет, код не заполняет | Как и другие предложения (kind, discountPercent), читать необязательное поле `brand` (строка), если пришло. В K добавить `NomenclatureChange.brand` с `x-status: proposed` (ТЗ 5.4, вопрос 31) | SYNC | pos-api/src/sync/apply/ (catalog applier), pos-api/src/sync/apply/odata-catalog.source.ts, K (NomenclatureChange) |
| 16 | `PriceListChange.currency`: `null` = KGS, другая валюта — VALIDATION; в allow-list нет `Catalog_Валюты` и `$orderby` | По ТЗ 5.4 и Г.7: в описании `currency` записать «`null` — KGS, другая — вид цены не загружается». В A добавить `Catalog_Валюты` и `$orderby=Ref_Key` с пометкой proposed (вопрос 18 ТЗ) | CONTRACT | K (PriceListChange), A |
| 17 | Вид клиента `kind` есть только в `CustomerCreateRequest`; код читает предложение у `Catalog_Контрагенты`, по умолчанию legal | По ТЗ 5.6 и 6.10: добавить `kind` (enum individual / entrepreneur / legal, `x-status: proposed`) в `CounterpartyChange` и `CustomerCandidate`. Без поля — legal | CONTRACT | K (CounterpartyChange, CustomerCandidate) |
| 18 | Скидки: в K нет `AgreementChange.discountPercent` и параметров `DiscountChange`; код читает поля-предложения | По ТЗ 5.6: добавить с `x-status: proposed` `AgreementChange.discountPercent` и `DiscountChange` kind / value / isActive / appliesAutomatically / validFrom / validTo / conditions{minTotal, partnerRefs}. Без полей — kind=percent, value=0 (как в коде) | CONTRACT | K (AgreementChange, DiscountChange) |
| 19 | `ReceivableDocument` без вида и статуса; правила парсера (snapshotAt +5 мин, overdueAmount и др.) есть только в коде | По ТЗ 6.12: в описании `ReceivableDocument.documentType` дать таблицу «тип → вид строки», включая `Document_ОплатаПлатежнойКартой`, правило статуса due/posted и требование «только проведённые». В `CustomerReceivables` — перечень условий, при которых POS отклоняет ответ 200 | CONTRACT | K (ReceivableDocument, CustomerReceivables) |
| 20 | `ReturnDocumentChange` без ссылки на заявку; сопоставление — по `shipmentRef` и товару; в `ReturnCreateRequest` — последняя проведённая реализация | По ТЗ 5.7 и 6.17: добавить `ReturnDocumentChange.returnRequestExternalId` (`x-status: proposed`, вопрос 79). В описаниях `ReturnDocumentChange.lines[].lineNumber` (номер строки возврата) и `ReturnCreateRequest.shipmentRef` (последняя проведённая реализация заказа с этим товаром, вопрос 80) — по ТЗ | CONTRACT | K (ReturnDocumentChange, ReturnCreateRequest) |
| 21 | `failOnDuplicate=false` при «всё равно создать» — поведение 1С не описано; в 05 ONEC-045 «карточка не создаётся» | Целевое по ТЗ 6.11 и допущению Q-025: `true` — 409 при другом клиенте с тем же телефоном; `false` — проверка дублей не выполняется, карточка создаётся (`x-status: proposed`, вопрос 42). Описать в K; уточнить 05 ONEC-045 и 18 §4.9 | CONTRACT | K (CustomerCreateRequest.dedupe, /customers), 05 ONEC-045, 18 §4.9 |
| 22 | Опрос статуса заявок на возврат: 18 и 05 — 5 мин, код — 30 мин (cron master) | Целевое по ТЗ 4.9 и Г.6 — 30 мин (как в коде). Исправить 05 §7.3 и 18 §4.15 | DOC | 05 §7.3, 18 §4.15 |
| 23 | `/check`: код шлёт `calculateDiscounts=false` и использует только исход; по 18 и 05 SYNC-052/053 ответ разбирается | По ТЗ 6.5 («к сведению… метод реализовать полностью»): в R1 — только исход ok / rejected / unavailable, решение о долге — по снимку receivables. В 05 SYNC-052/053 и 18 §4.4 отметить, что разбор `lines`/`issues`/`receivables` отложен | DOC | 05 SYNC-052/053, 18 §4.4 |
| 24 | Пустое сообщение `/changes` в K не описано | По ТЗ 5.2 п.5 и 6.2: в описании `/changes` записать: `items=[]`, `hasMore=false`, `cursor=null`; POS такое сообщение не подтверждает и номер не сдвигает | CONTRACT | K (/changes) |
| 25 | Имя параметра пути `{uuid}` в K и `{externalId}` в 05 | Различие только в имени. Источник истины — K; уже отмечено в NOTES §4 п.2 | NONE | — |
| 26 | `/health` 401: в x-access «без тела», а схема и фикстура — с телом Error | По ТЗ 6.1 и 4.6: 401 — без сведений о системе, допустимо тело в едином формате с `POS_E_UNAUTHORIZED`. Исправить x-access | CONTRACT | K (/health x-access) |
| 27 | Дубль п. 6 (since у `/external-ids`, cursor/hasMore proposed) | См. п. 6 | CONTRACT | K (/external-ids) |
| 28 | Дубль п. 8 (обработчики /changes, правило reregister) | См. пп. 8 и 31 | SYNC | см. п. 8 |
| 29 | Дубль п. 17 и п. 18 (поля-предложения kind, discountPercent, параметры скидок) | См. пп. 17 и 18 | CONTRACT | K |
| 30 | Срезы цен и остатков только через OData; `getCatalogCard` не вызывается; «404 → fallback на OData» в K не реализовано | По ТЗ 5.5 и 6.21 (метод по желанию; Q-319 открыт): x-retry `/catalog/{ref}` переписать — «в R1 backend метод не вызывает; при подключении 404 → данные из срезов». Код не меняется до ответа на Q-319 | CONTRACT | K (/catalog/{ref}) |
| 31 | `POST /changes/reregister` вызывает только раннер приёмки; у администратора нет способа | ТЗ 5.2 п.7 и 6.4 и 05 §6.2 п.3 требуют разовой перерегистрации при переводе в рабочий режим и после подключения новых типов (ПКО — после Q-012). Добавить запуск для администратора: CLI-скрипт в `pos-api/scripts` (`npm run onec:reregister`) с журналом и выводом ошибки. Шаг включить в план развёртывания | SYNC | pos-api/scripts/onec_reregister.ts (новый), pos-api/package.json, docs/specification/16_DEPLOYMENT_PLAN.md |
| 32 | Характеристики с `ownerType=Catalog_ВидыНоменклатуры` и упаковки без `unitRef` K допускает, POS отклоняет (VALIDATION) | Ограничения R1 (Q-021) прямо сказаны в ТЗ 5.4. В K добавить в описания `CharacteristicChange.ownerType` и `PackagingChange.unitRef`: «POS R1 не применяет (ошибка позиции)» | CONTRACT | K (характеристики, упаковки) |
| 33 | `Catalog_Контрагенты.taxId` в K без формата; POS принимает только 14 цифр | По ТЗ 5.6: в K добавить `pattern: "^\d{14}$"` или описание «иначе POS значение не записывает» | CONTRACT | K (CounterpartyChange.taxId) |
| 34 | `/images`: лимит 10 МБ и список расширений есть только в коде | По ТЗ 6.19 и 5.4: описать в K лимит 10 МБ на исходный файл и список расширений; прочие файлы — не фото, помечаются удалёнными | CONTRACT | K (/images/{ref}, ImageFileChange) |
| 35 | Сообщение с `messageNumber ≤ since`: POS не применяет данные, но отправляет ack; в K не описано | По ТЗ 5.2 п.4: описать в K (/changes, /changes/ack) | CONTRACT | K (/changes) |
| 36 | Дубль п. 24 (пустое сообщение) | См. п. 24 | CONTRACT | K (/changes) |
| 37 | `ChangesPage`: POS считает ответ не по контракту при `hasMore=true` без cursor и при разных `messageNumber` на страницах | По ТЗ 5.2 п.6 и 6.2: в K записать требование — при `hasMore=true` непустой `cursor` обязателен, `messageNumber` одинаков на всех страницах; иначе POS откатывает сообщение | CONTRACT | K (ChangesPage) |
| 38 | `POS_E_LOCKED` у `/changes`, ack и reregister — 503 (без 423); в 05 §6.3 для /changes только 200 и 400 | K совпадает с ТЗ (А.1, А.2): 423 обязательно только в /orders и /check, в остальных методах — 503. Исправить 05 §6.3 (коды /changes, ack, reregister) и 05 §6.5 (строка 423/503) | DOC | 05 §6.3, §6.5 |
| 39 | Повторы: x-retry ссылается только на SYNC-029; клиент дополнительно повторяет GET до 3 раз (0,5 и 1 с) | По ТЗ 4.7: добавить в K (info, раздел повторов) оба уровня. POST сразу не повторяются | CONTRACT | K (info) |
| 40 | Порядок типов: в фейке `TYPE_RANK` нет `Document_ЗаказКлиента` и `QrPaymentStatus` | С подключением обработчиков (п. 8) добавить им ранги по рекомендуемому порядку ТЗ 5.3 п.6 (заказы — перед реализациями, события QR — последними) | SYNC | pos-api/src/integrations/onec/fake-exchange-plan.ts |
| 41 | Тело ack и `status=warning` в /health — `x-status: proposed`; backend проверяет минимум полей | Поля помечены proposed; POS терпим к их отсутствию. Расхождения в поведении нет | NONE | — |
| 42 | Поля большинства элементов /changes — proposed, а ТЗ подаёт их как требования | ТЗ 1 и 8 оговаривают, что proposed-места согласуются со специалистом до реализации. Осознанно | NONE | — |
| 43 | Фикстуры с правдоподобными ПДн (Асанов Бакыт, +996700123456, 0700 123 456) | Заменить на синтетику ТЗ («ООО Пример», «Клиент Пример», +996700000001, «0700 000 001»), в том числе Айгуль, Достон, Абдулла. Проверить тесты pos-api, сверяющие эти значения | CONTRACT | F/customers-create.request.json, F/customers-create.409.json, F/customers-search.200.json, F/changes.documents.page2.200.json, F/orders-create.request.json, F/payments-*.request.json |
| 44 | Дубль п. 1 (customer.ref null) | См. п. 1 | CONTRACT | K (OrderCustomer) |
| 45 | Дубль п. 2 (createdByUserCode — UUID) | См. п. 2 | CONTRACT | K, F |
| 46 | Дубль п. 7 (таймаут /orders 6 с) | См. п. 7 | CONTRACT | K |
| 47 | Дубль п. 23 (/check: только исход, нет SYNC-052/053) | См. п. 23 | DOC | 05 SYNC-052/053 |
| 48 | `PRICE_CHANGED` в IssueCode, но в `CheckLineRequest` нет цены POS | По ТЗ 6.5: в описании IssueCode пометить `PRICE_CHANGED` как необязательный для 1С; цену сравнивает POS | CONTRACT | K (IssueCode), F/check.stock-prices.200.json (оставить пример, пометить) |
| 49 | `recalculated`: по 05 ONEC-039 и ТЗ 6.6 POS уведомляет продавца; код сохраняет `onec_total`, но уведомления нет | По ТЗ 6.6 («показывает… признак и уведомляет продавца»): в `OrderProjector.apply`, когда `onec_total` впервые становится ≠ `total`, создать уведомление автору заказа (dedupe по заказу). Признак `totals_differ` уже есть | ORDERS | pos-api/src/orders/order-projection.ts, pos-api/src/orders/worker/order-onec-results.handler.ts |
| 50 | Дубль п. 19 (вид и статус строк долга) | См. п. 19 | CONTRACT | K (ReceivableDocument) |
| 51 | `creditAvailable` не используется; `creditLimit=null` → в долг не продаём | Совпадает с ТЗ 6.12 и 10 PAY-031 (лимит считает POS). Осознанно | NONE | — |
| 52 | Дубль п. 19 (правила отклонения ответа о долге) | См. п. 19 | CONTRACT | K (CustomerReceivables) |
| 53 | `POST /orders/status` — в K есть 404, по 18 и коду — только 200 и `notFound` | По ТЗ 6.9 и А.2: убрать 404 из responses `/orders/status` | CONTRACT | K (/orders/status) |
| 54 | Статусы заказа: распознаются НеСогласован / НаСогласовании / КВыполнению / Согласован / Закрыт; M5 (ПричинаОтмены) неприменим | Код совпадает с ТЗ 6.6 (КОбеспечению и КОтгрузке ждут вопроса 50). В 05 §5.1b M5 записать: «в контракте v1 поля причины отмены нет; отмена — Закрыт без проведённых реализаций или deletionMark» | DOC | 05 §5.1b |
| 55 | `CustomerCreateRequest.kind` — в K только пример individual | Добавить `enum: [individual, entrepreneur, legal]` (ТЗ 6.11) | CONTRACT | K (CustomerCreateRequest.kind) |
| 56 | Классификатор outbox считает `POS_E_DUPLICATE` с `details.ref` успешной доставкой для любого маршрута, включая заказы | Для клиентов — отдельный маршрут (бизнес-отказ). Для остальных — терпимое чтение: «документ уже есть, ссылка дана». ТЗ требует для повтора 200; лишний 409 со ссылкой не вредит, без ссылки — transient. Осознанно | NONE | — |
| 57 | Не описано: `organizationRef`/`clientChecks` всегда `null`; `quantity` в базовой единице, `packQuantity` — в упаковках | По ТЗ 6.6: дописать описания в K (OrderLine.quantity, packQuantity; organizationRef и clientChecks «сейчас null») | CONTRACT | K (OrderLine, OrderCreateRequest) |
| 58 | Поиск клиента по телефону: POS обрывает через 5 с (`ONEC_MATCH_TIMEOUT_MS`), ТЗ 4.9 обещает 6 с | Привести к ТЗ: таймаут поиска = `ONEC_SYNC_CHECK_TIMEOUT_MS` (6 с); запасной путь через копию справочника остаётся | CUSTRET | pos-api/src/customers/matching/customer-matching.port.ts, pos-api/src/customers/matching/pg-customer-matching.ts |
| 59 | В 18 §4.5 итоги примера (16850.00/16007.50) не сходятся со строкой 4700.00 | Пример 18 исправить по фикстуре orders-create.request.json | DOC | 18 §4.5 |
| 60 | Дубль п. 43 (ПДн в фикстурах и 18) | См. п. 43; в 18 — та же замена | CONTRACT | F, 18 |
| 61 | Дубль п. 9 (POST /payments не вызывается) | См. п. 9 | DOC | 18 §4.11 |
| 62 | Дубль п. 2 (`cashierUserCode` — UUID или `system`) | См. п. 2 | CONTRACT | K (QrCreateRequest, PaymentCreateRequest), F |
| 63 | `purpose` в фикстуре — «Оплата заказа POS 0192f5a0», в коде — «Оплата заказа POS-2026-000123» | По ТЗ 6.14: описание `purpose` — «Оплата заказа <номер заказа POS>», фикстуру исправить | CONTRACT | K (QrCreateRequest.purpose), F/payments-qr.request.json |
| 64 | `PaymentCreateRequest.customerRef` обязателен, а у «Розничного покупателя» ссылки нет | ТЗ 6.13 совпадает с K (обязателен). Метод в R1 не вызывается (Q-012). Решать при включении `POST /payments` вместе с Q-026 | NONE | — |
| 65 | Нет автоматического manual_confirm (no_webhook) в коде, а 05 §6.7.3 и 18 его описывают | Целевое по ТЗ 6.15 и 7, FQ-PAY-03: перехода нет. Исправить последнюю строку 05 §6.7.3 и 18 (K — п. 10) | DOC | 05 §6.7.3, 18 §4.13/§5.x |
| 66 | Статус `expired` от 1С: по 05 — сразу `qr_expired`, в коде — по своему `qr_expires_at` | По ТЗ 6.15 («POS переводит в QR истёк по своему сроку»). Исправить 05 §6.7.3 | DOC | 05 §6.7.3 |
| 67 | Горизонт опроса: опрос прекращается при выходе из `qr_shown` (таймер раз в минуту) | Совпадает с ТЗ 6.15 и x-retry K («до перехода из qr_shown или до expiresAt+60 с»). Расхождения нет | NONE | — |
| 68 | `QrPaymentStatus`: у очереди `payments.onec-qr-status` есть потребитель, но нет публикатора | Подключить `ChangeItemHandler` `QrPaymentStatus` → публикация в очередь (см. п. 8) | SYNC | pos-api/src/sync/apply/ (новый handler), pos-api/src/jobs/sync/sync-worker.wiring.ts |
| 69 | `OnecQrStatusPayload` содержит `amount` и `documentType`, которых нет в `QrPaymentStatusChange` | В обработчике п. 68 отображать поля контракта; `amount` и `documentType` в payload сделать необязательными (`applyOnecQrStatus` их не требует) | SYNC | pos-api/src/jobs/payments/payments-jobs.ts, новый handler |
| 70 | Таймаут статуса QR: в 05 SYNC-077 — 30 с, в коде — 6 с | Целевое по ТЗ 4.9 — 6 с (как в коде). Исправить 05 SYNC-077; в K — таблица таймаутов (п. 7) | DOC | 05 SYNC-077 |
| 71 | `X-Request-Id` опроса заявок на возврат — `returns.poll:<uuid>`, не UUID | Контракт и ТЗ 4.4/4.8 требуют UUID. Генерировать новый UUID на вызов, контекст `returns.poll` и id заявки — в лог | CUSTRET | pos-api/src/returns/onec/returns-onec.service.ts |
| 72 | `POST /returns`: x-retry «409/422/404 → failed», а `POS_E_NOT_FOUND` в x-error-codes нет | По ТЗ 6.17 и А.2: в x-retry записать «404 расширение не возвращает (реализация не найдена — 422 POS_E_VALIDATION); 404 платформы → failed без повтора» | CONTRACT | K (/returns) |
| 73 | `POST /payments`: код для «заказ-основание не найден» не определён | По аналогии с /returns (ТЗ 6.17): 422 `POS_E_VALIDATION`. Описать в K и дописать строку в таблицу ошибок ТЗ 6.13. Риск низкий: метод в R1 не вызывается, есть зависимость SYNC-042 | CONTRACT | K (/payments), ТЗ 6.13 |
| 74 | `ReturnCreateRequest.lines[].productRef` обязателен, а payload может отправить `null` | По ТЗ 6.17 `productRef` обязателен. Не ставить заявку в outbox (или останавливать доставку как ошибку данных), если у строки реализации нет `product_ref`; сообщение кассиру и администратору | CUSTRET | pos-api/src/returns/return-onec-payload.ts, pos-api/src/returns/ (сервис отправки) |
| 75 | `QrCreateRequest.orderExternalId` обязателен (UUID), для платежа без заказа код шлёт пустую строку | ТЗ 6.14 — обязателен. Сейчас не проявляется (Q-152 выключен), но вместо `''` нужен явный отказ: QR без заказа не выпускать (`QR_UNAVAILABLE` или ошибка домена) до решения Q-152 | ORDERS | pos-api/src/payments/qr/qr-issuer.service.ts |
| 76 | История референсов QR: 18 и 05 не требуют от 1С хранить прежние референсы и сообщать `paid` с референсом прежнего QR | Требование уже в ТЗ 6.14 п.4 и 7.4. Внести в K: описание `QrPaymentStatus.reference` и `QrPaymentStatusChange.reference` («при paid — референс QR, по которому пришли деньги») и правило перевыпуска. Подтвердить в 05 §6.7 | CONTRACT | K (QrPaymentStatus, QrPaymentStatusChange, /payments/qr), 05 §6.7.3 |
| 77 | Отмена уже истёкшего QR: в `QrCancelResponse` только `cancelled` или `paid` | По ТЗ 6.16 п.4: описать в K — для `cancelled`/`expired` ответ 200 `cancelled` без действий; `pending` с истёкшим сроком — как `pending` | CONTRACT | K (QrCancelResponse, /qr/cancel) |
| 78 | 05 §6.3 и §6.4: статус заявки «и связанных документов», returned_qty; в `ReturnRequestState` только ref, number, status, onecStatus | Целевое — K и ТЗ 6.18: количества частичного возврата — из документов возврата в /changes. Исправить 05 §6.3/§6.4 | DOC | 05 §6.3, §6.4 |
| 79 | Связь «Возврат товаров от клиента» с заявкой в K не передаётся | См. п. 20: `returnRequestExternalId` (`x-status: proposed`). Рекомендация ТЗ 6.17 п.7 (ввод на основании заявки, комментарий `POS <uuid>`) — для 1С | CONTRACT | K (ReturnDocumentChange) |
| 80 | Таймауты 6 с в коде для /orders, статуса и отмены QR, поиска клиентов, долга против 30 с в 05 и 18 | Целевое — таблица ТЗ 4.9 (6 с). Исправить 05 (SYNC-077 и таблицы таймаутов) и 18 §3.9; в K — п. 7 | DOC | 05, 18 §3.9 |
| 81 | `POS_E_LOCKED`: в 05 §6.5 и 18 §3.6 «423 или 503» для всех методов | Целевое — ТЗ А.1 и А.2 (423 только /orders и /check), K совпадает. Исправить 05 §6.5 и 18 §3.6 | DOC | 05 §6.5, 18 §3.6 |
| 82 | Дубль п. 26 (401 у /health) | См. п. 26 | CONTRACT | K (/health) |
| 83 | Роль OData: в 18 — запасной путь, по 05 §6.2 п.5 — постоянное чтение срезов до Q-319 | Целевое — ТЗ 1.2 п.1 и 5.5 (= 05). Исправить 18 §0 п.8 и §4.3 | DOC | 18 §0 п.8, §4.3 |
| 84 | Режим «только OData, заказы вручную» в 18 описан как доступный; по 05 §9 не реализован | По ТЗ (= 05): режим не реализован. Исправить 18 §0 п.8 и §7.1 | DOC | 18 §0, §7.1 |
| 85 | Имя файла OpenAPI в 18 §8 и 05 ONEC-033/071 устарело | Заменить на `contracts/onec/onec-http-service.v1.yaml` | DOC | 18 §8, 05 ONEC-033, ONEC-071 |
| 86 | Временные коды: в 05 ONEC-055 три, в K и коде — четыре (+`POS_E_QR_UNAVAILABLE`) | Дописать `POS_E_QR_UNAVAILABLE` в 05 ONEC-055 (код `TRANSIENT` уже содержит его) | DOC | 05 ONEC-055 |
| 87 | Повтор ack: в 18 — «уже подтверждённого номера», в K — «того же или меньшего» | Целевое — K и ТЗ 4.7. Исправить 18 и 05 §6.2 п.2 / §6.3 | DOC | 18 §4.2, 05 §6.2 п.2 |
| 88 | Коды /check: в 18 §4.0 только 200, 422, 503; в K ещё 400 и 423 | Целевое — K и ТЗ 6.5. Исправить 18 §4.0 | DOC | 18 §4.0 |
| 89 | 401 при чтении: по 05 §6.5 и ТЗ А.1 — следующее чтение не раньше чем через 15 мин; в коде паузы нет (опрос по cron повторяет через 5 мин и через ретраи SYNC-029) | Ввести паузу чтения после 401/403: отметка в `sync_node_state` (`last_error_code` и время). Задания чтения (`onec.changes`, статусы, долги, возвраты) 15 мин после неё не обращаются к 1С. Без повторов SYNC-029 для 401/403, тревога администратору. 18 §3.6 — DOC | SYNC | pos-api/src/jobs/sync/sync-job.processor.ts, pos-api/src/sync/apply/onec-changes.service.ts, pos-api/src/integrations/onec/onec-error.ts, 18 §3.6 |
| 90 | Число шагов КП: 13 RM-E-016 — КП-1…КП-18, в 18 §7.2 и протоколе приёмки — 20 | Исправить 13 RM-E-016 на КП-1…КП-20 | DOC | 13 RM-E-016 |
| 91 | Журнал регистрации 1С подан в ТЗ как рекомендация | Источники требуют только `POS_ЖурналЗапросовPOS`; рекомендация не противоречит. Осознанно | NONE | — |
| 92 | Дубль п. 43 (ПДн в фикстурах) | См. п. 43 | CONTRACT | F |
| 93 | Синтетика кассира использует `Document_КорректировкаРеализации`, которого нет в источниках | По ТЗ 6.12 прочие типы → «корректировка»; синтетика проверяет именно эту ветку. Расхождения с контрактом нет (`documentType` — строка) | NONE | — |
| 94 | В K 28 мест с `x-status: proposed` | ТЗ 1 и 8 оговаривают согласование до реализации; новые предложения из этого разбора (пп. 6, 14–18, 20, 21) тоже помечаются proposed. Осознанно | NONE | — |

## Что нужно сделать

1. **CONTRACT.** Правки K, F и A. Версию контракта поднять до 1.1.0: изменения аддитивные или ослабляющие — `nullable`, необязательный `since`, удалённый 404 у пакетного статуса, proposed-поля, описания. После правки прогнать контрактные тесты pos-api (фикстуры, allow-list, валидация схем) и проверить тесты, которые сверяют значения фикстур (ПДн, EAN, `expiresAt`, `comment`).
2. **SYNC.** Отдельные пункты:
   - п. 8 — обработчики `QrPaymentStatus` и `Document_ЗаказКлиента` с ранжированием в фейке (п. 40);
   - п. 31 — CLI перерегистрации;
   - п. 14 — главная картинка по `imageFileRef`;
   - п. 15 — `brand`;
   - п. 89 — пауза 15 мин после 401/403.
3. **ORDERS:**
   - п. 49 — уведомление продавцу при `recalculated`;
   - п. 75 — QR без заказа не выпускать.
4. **CUSTRET:**
   - п. 58 — таймаут поиска 6 с;
   - п. 71 — UUID в `X-Request-Id`;
   - п. 74 — `productRef` не `null`.
5. **DOC.** Правки 05, 18, 13, 14. В ТЗ (md) изменятся только пометки «пока не применяет» (п. 8), «imageFileRef не сохраняет» (п. 14) и строка ошибки 6.13 (п. 73). Для программиста 1С это не меняет объём работ; при следующей выгрузке Word — перечислить их в приложении Г.

Новых вопросов заказчику не нужно: все развилки уже стоят в 14 и в разделе 10 ТЗ (Q-012, Q-014, Q-017, Q-018, Q-025, Q-026, Q-129, Q-152, Q-319).

// Каталог проверок: ID, группа, заголовок, вид, R/W, источники, зависимости (design §1).
// Источники: contract — контракт onec-http-service 1.2.0; ref — «Требования к API 1С» 1.2.1 (требования — как в 1.2), раздел;
// kp — контрольный пример (18 §7.2 = Требования §8.3); ac — AC-ONEC (18 §7.3).
// required — метод обязателен по Требованиям (x-priority: must): «метода нет» у такого метода — ОШИБКА.

const D = [];
function def(id, group, kind, rw, title, sources = {}, extra = {}) {
  D.push({ id, group, kind, write: rw === 'W', rw, title, sources, deps: extra.deps || [], optional: !!extra.optional, expected: extra.expected || null });
}

// S — связь и защита канала
def('S1', 'S', 'auto', 'R', 'Адрес публикации (HTTPS, сегмент /hs)', { contract: ['servers', 'info'], ref: ['§4.2'], ac: ['AC-ONEC-081'] });
def('S2', 'S', 'auto', 'R', 'Сертификат и TLS', { ref: ['§4.2 «Всегда HTTPS, TLS 1.2 и выше»'], ac: ['AC-ONEC-081'] });
def('S3', 'S', 'auto', 'R', 'Публикация отвечает (GET /health)', { ref: ['§4.6 «Ошибки платформы»', '§8.2 этап 2'], kp: ['КП-1'] });
// A — доступ
def('A1', 'A', 'auto', 'R', '/health с пользователем и ключом → 200', { contract: ['paths./pos/v1/health'], ref: ['§6.1'], kp: ['КП-1'], ac: ['AC-ONEC-051'] });
def('A2', 'A', 'auto', 'R', '/health без X-POS-Client-Key → 401 POS_E_UNAUTHORIZED', { contract: ['security', 'Unauthorized'], ref: ['§4.4', '§8.4 «аутентификация»'], kp: ['КП-1'], ac: ['AC-ONEC-032'] });
def('A3', 'A', 'auto', 'R', '/health с неверным ключом → 401 POS_E_UNAUTHORIZED', { contract: ['security', 'Unauthorized'], ref: ['§4.4'], ac: ['AC-ONEC-032'] });
def('A4', 'A', 'auto', 'R', 'Неверный пароль (или JWT), одна попытка → 401', { ref: ['§4.4', '§8.4 «аутентификация»'], ac: ['AC-ONEC-032'] });
def('A5', 'A', 'auto', 'R', 'Без Authorization, с ключом → 401', { ref: ['§4.6 «Ошибки платформы»'] });
def('A6', 'A', 'auto', 'R', 'Ключ проверяется в каждом методе (без ключа и с неверным ключом → 401)', { contract: ['security'], ref: ['§4.4 «Ключ клиента и вход» п. 3', '§8.4 «аутентификация»'], ac: ['AC-ONEC-032'] });
def('A7', 'A', 'auto', 'R', 'Ответы 401 без сведений о системе', { contract: ['paths./pos/v1/health'], ref: ['§8.3'], kp: ['КП-1'] }, { deps: ['A2', 'A3'] });
def('A8', 'A', 'auto', 'R', 'Пароль и ключ технического пользователя', { ref: ['§4.4 «Технические пользователи»'] });
def('M2', 'A', 'semi', 'R', 'С другого компьютера сети доступа нет (--expect-no-access)', { ref: ['§4.2 «Доступ только из локальной сети магазина с адреса сервера POS»'], ac: ['AC-ONEC-080'] });
def('M3', 'A', 'manual', '-', 'Публикация закрыта из интернета', { ref: ['§4.2 «Входящие порты из интернета не открываются»'], ac: ['AC-ONEC-080'] });
// H — /health
def('H1', 'H', 'auto', 'R', 'Ответ /health по схеме Health, apiVersion = 1', { contract: ['Health'], ref: ['§6.1'], kp: ['КП-1'], ac: ['AC-ONEC-051'] });
def('H2', 'H', 'auto', 'R', 'serverTime с +06:00 и сходится с часами', { contract: ['DateTime'], ref: ['§4.3'] });
def('H3', 'H', 'auto', 'R', 'status = ok', { contract: ['Health.status'], ref: ['§6.1'] });
// C — план обмена
def('C1', 'C', 'auto', 'R', 'Повтор /changes до ack — то же сообщение', { contract: ['paths./pos/v1/changes'], ref: ['§6.2', '§8.4'], kp: ['КП-2'], ac: ['AC-ONEC-035'] });
def('C2', 'C', 'auto', 'R', 'Все страницы сообщения по cursor', { contract: ['ChangesPage'], ref: ['§5.2', '§6.2'], kp: ['КП-2'], ac: ['AC-ONEC-036'] });
def('C3', 'C', 'auto', 'R', 'Элементы /changes по схемам своих типов', { contract: ['ChangeItem'], ref: ['§5.4–§5.7'], kp: ['КП-2'], ac: ['AC-ONEC-058'] }, { deps: ['C2'] });
def('C4', 'C', 'auto', 'R', 'limit=10000 → не больше 5000 элементов', { contract: ['paths./pos/v1/changes.limit'], ref: ['§4.9', '§8.4'], ac: ['AC-ONEC-036'] });
def('C5', 'C', 'auto', 'R', 'Неверный since → 400 POS_E_BAD_REQUEST', { contract: ['paths./pos/v1/changes'], ref: ['§6.2'] });
def('C6', 'C', 'auto', 'W', 'Перерегистрация (полная выгрузка) → 202', { contract: ['paths./pos/v1/changes/reregister'], ref: ['§6.4', '§8.4'], kp: ['КП-2'] });
def('C7', 'C', 'auto', 'W', 'Подтверждение (ack) сообщения', { contract: ['paths./pos/v1/changes/ack'], ref: ['§6.3'], kp: ['КП-2'], ac: ['AC-ONEC-035', 'AC-ONEC-036'] }, { deps: ['C2'] });
def('C8', 'C', 'auto', 'W', 'Повтор ack → 200 без действий', { contract: ['x-idempotency'], ref: ['§4.7 «Повторы и отмены»'], kp: ['КП-2'], ac: ['AC-ONEC-035'] }, { deps: ['C7'] });
def('C9', 'C', 'auto', 'W', 'ack невыданного номера → 409 POS_E_ACK_OUT_OF_ORDER', { contract: ['paths./pos/v1/changes/ack'], ref: ['§6.3'] }, { deps: ['C7'] });
def('C10', 'C', 'auto', 'W', 'После ack повтор ничего не выдаёт', { ref: ['§8.4'], kp: ['КП-2'], ac: ['AC-ONEC-036'] }, { deps: ['C7'] });
def('C11', 'C', 'semi', 'R', 'Изменённый в 1С товар приходит в следующем /changes', { ref: ['§8.3'], kp: ['КП-4'], ac: ['AC-ONEC-034'] }, { deps: ['C2'] });
def('C12', 'C', 'manual', 'R', 'Удаление приходит как ObjectDeletion (необязательно)', { ref: ['§8.4 «состав плана обмена»'], kp: ['КП-3'], ac: ['AC-ONEC-034'] }, { deps: ['C2'], optional: true });
def('C13', 'C', 'manual', '-', 'Числа товаров и клиентов совпадают с 1С', { ref: ['§8.2 этап 3'] }, { deps: ['C2', 'C3', 'C6', 'C7'] });
def('C14', 'C', 'auto', 'W', 'Клиент, заказ и QR из POS приходят в /changes с externalId', { contract: ['PartnerChange.externalId', 'OrderChange.externalId', 'QrPaymentStatusChange'], ref: ['§5.1', '§5.6', '§5.7', '§6.2 правило 8', '§6.6 «Регистрация изменений»', '§6.14 п. 9', '§7.10', '§8.4 «событие QR в /changes»'] }, { deps: ['K1', 'O1', 'Q1'] });
// I — картинки (обязательный метод)
def('I1', 'I', 'auto', 'R', 'Файл картинки: ETag = SHA-256, Content-Length, размер', { contract: ['paths./pos/v1/images/{ref}'], ref: ['§6.19'], kp: ['КП-18'], ac: ['AC-ONEC-049'] }, { deps: ['C2', 'I3'] });
def('I2', 'I', 'auto', 'R', 'If-None-Match → 304 без тела, тот же ETag', { contract: ['paths./pos/v1/images/{ref}.304'], ref: ['§6.19'], kp: ['КП-18'], ac: ['AC-ONEC-049'] }, { deps: ['I1'] });
def('I3', 'I', 'auto', 'R', 'Несуществующая картинка → 404 POS_E_NOT_FOUND', { contract: ['paths./pos/v1/images/{ref}.404'], ref: ['§6.19'] });
// X — сверка (метод желательный)
def('X1', 'X', 'auto', 'R', '/external-ids за 7 дней: схема, страницы', { contract: ['ExternalIdsPage'], ref: ['§6.20'], kp: ['КП-19'] }, { optional: true });
def('X2', 'X', 'auto', 'R', '/external-ids без since', { contract: ['paths./pos/v1/external-ids.since'], ref: ['§6.20'] }, { deps: ['X1'], optional: true });
def('X3', 'X', 'auto', 'R', '/external-ids?type=Клиент — только клиенты', { contract: ['paths./pos/v1/external-ids.type'], ref: ['§6.20'], kp: ['КП-19'] }, { deps: ['X1'], optional: true });
def('X4', 'X', 'auto', 'W', 'Созданные программой объекты есть в /external-ids (отменённый пометкой заказ — deletionMark = true)', { ref: ['§4.7', '§6.20', '§8.4'], kp: ['КП-19'] }, { deps: ['X1', 'K1', 'PAY1'], optional: true });
def('X5', 'X', 'auto', 'W', 'Заказы без since (type=Заказ, limit=500): новые первыми', { contract: ['paths./pos/v1/external-ids'], ref: ['§6.20', '§8.3'], kp: ['КП-19'] }, { deps: ['X1', 'O1'], optional: true });
// K — клиенты
def('K1', 'K', 'auto', 'W', 'Новый клиент «ПРОВЕРКА POS» → 201', { contract: ['paths./pos/v1/customers.post'], ref: ['§6.11'], kp: ['КП-6'], ac: ['AC-ONEC-045', 'AC-ONEC-046'] });
def('K2', 'K', 'auto', 'W', 'Повтор того же клиента → 200, тот же клиент', { ref: ['§4.7', '§6.11'], kp: ['КП-6'] }, { deps: ['K1'] });
def('K3', 'K', 'auto', 'W', '10 одновременных запросов → один клиент', { ref: ['§4.7 п. 2', '§6.11'] });
def('K4', 'K', 'auto', 'W', 'Дубль по телефону → 409 POS_E_DUPLICATE с кандидатом', { contract: ['DuplicateCandidate'], ref: ['§6.11'], kp: ['КП-6'], ac: ['AC-ONEC-045'] }, { deps: ['K1'] });
def('K5', 'K', 'auto', 'W', 'Дубль по телефону, failOnDuplicate=false → 201, новая карточка', { contract: ['CustomerDedupe.failOnDuplicate'], ref: ['§6.11'], ac: ['AC-ONEC-045'] }, { deps: ['K1'] });
def('K6', 'K', 'auto', 'W', 'Телефон не E.164 → 400/422, объект не создан', { contract: ['PhoneE164'], ref: ['§4.3', '§6.11'] });
def('K7', 'K', 'auto', 'R', 'Поиск клиента по телефону', { contract: ['paths./pos/v1/customers.get'], ref: ['§6.10'], kp: ['КП-5'], ac: ['AC-ONEC-044'] }, { deps: ['C2'] });
def('K8', 'K', 'auto', 'R', 'Долг клиента: схема и правила приёма POS', { contract: ['CustomerReceivables'], ref: ['§6.12'], ac: ['AC-ONEC-047'] }, { deps: ['C2', 'K9'] });
def('K9', 'K', 'auto', 'R', 'Долг несуществующего клиента → 404', { contract: ['paths./pos/v1/customers/{ref}/receivables.404'], ref: ['§6.12'] }, { deps: ['C2'] });
def('K10', 'K', 'manual', '-', 'Сальдо клиента совпадает с отчётом 1С', { ref: ['§8.4'], ac: ['AC-ONEC-047'] }, { deps: ['K8'] });
// PAY — оплаты
def('PAY1', 'PAY', 'auto', 'W', 'Оплата наличными 1.00 KGS без заказа → 201, ПКО', { contract: ['paths./pos/v1/payments'], ref: ['§6.13'] }, { deps: ['K1'] });
def('PAY2', 'PAY', 'auto', 'W', 'Повтор оплаты → 200, тот же документ', { contract: ['x-idempotency'], ref: ['§4.7', '§6.13'], kp: ['КП-14'], ac: ['AC-ONEC-043'] }, { deps: ['PAY1'] });
def('PAY3', 'PAY', 'auto', 'W', '10 одновременных оплат → один документ', { ref: ['§4.7 п. 2', '§6.13'] }, { deps: ['K1'] });
def('PAY4', 'PAY', 'auto', 'W', 'Оплата несуществующего заказа → 422, не 404', { contract: ['paths./pos/v1/payments'], ref: ['§6.13', 'приложение А.2'] }, { deps: ['K1'] });
def('PAY5', 'PAY', 'auto', 'W', 'Распределение больше суммы → 422', { contract: ['paths./pos/v1/payments'], ref: ['§6.13', '§8.4'], ac: ['AC-ONEC-043'] }, { deps: ['K1'] });
def('PAY6', 'PAY', 'auto', 'W', 'Неверный JSON → 400, не 500', { ref: ['§4.6', '§6.13'], kp: ['КП-20'] });
// O — заказы (обязательный метод)
def('O0', 'O', 'auto', 'R', 'Статус заказа: неизвестный externalId → 404 (есть ли метод)', { contract: ['paths./pos/v1/orders/{uuid}/status'], ref: ['§6.8', '§8.4'] });
def('O1', 'O', 'auto', 'W', 'Заказ розничного покупателя (customer.ref = null) → 201, проведён, не согласован', { contract: ['paths./pos/v1/orders'], ref: ['§6.6', '§1.2 п. 4'], kp: ['КП-8'], ac: ['AC-ONEC-037', 'AC-ONEC-040'] }, { deps: ['O0', 'C2'] });
def('O2', 'O', 'auto', 'W', 'Повтор заказа → 200, тот же документ', { ref: ['§4.7'], kp: ['КП-8'] }, { deps: ['O1'] });
def('O3', 'O', 'auto', 'W', '10 одновременных заказов → один документ', { ref: ['§4.7 п. 2', '§8.4'], kp: ['КП-8'], ac: ['AC-ONEC-037'] }, { deps: ['O0', 'C2'] });
def('O4', 'O', 'auto', 'R', 'Статус нашего заказа', { contract: ['OrderStatus'], ref: ['§6.8'], kp: ['КП-10'], ac: ['AC-ONEC-041'] }, { deps: ['O1'] });
def('O5', 'O', 'auto', 'W', 'Пакетный статус: наш — items, случайный — notFound', { contract: ['paths./pos/v1/orders/status'], ref: ['§6.9', '§8.4'] }, { deps: ['O1'] });
def('O6', 'O', 'auto', 'W', 'Отмена нашего заказа → 200, заказ отменён, статусы после отмены те же', { contract: ['paths./pos/v1/orders/{uuid}/cancel'], ref: ['§6.7', '§6.8 «без кэширования»', '§6.9'], kp: ['КП-15'], ac: ['AC-ONEC-042'] }, { deps: ['O1'] });
def('O7', 'O', 'auto', 'W', 'Повтор отмены → 200, то же состояние', { contract: ['x-idempotency'], ref: ['§4.7 «Повторы и отмены»'] }, { deps: ['O6'] });
def('O8', 'O', 'auto', 'W', 'Отмена случайного заказа → 404', { ref: ['§6.7', 'приложение А.2'] }, { deps: ['O0'] });
def('O9', 'O', 'auto', 'W', 'Заказ: неверный JSON → 400', { ref: ['§6.6'], kp: ['КП-20'] }, { deps: ['O0'] });
// R — заявки на возврат (обязательны, если 1С принимает заявки извне — Q-018, вопрос 77)
def('R0', 'R', 'auto', 'R', 'Статус заявки: неизвестный externalId → 404 (есть ли метод)', { contract: ['paths./pos/v1/returns/{uuid}/status'], ref: ['§6 таблица (Q-018)', '§6.18', '§8.4'] });
def('R1', 'R', 'auto', 'W', 'Заявка на возврат по несуществующей реализации → 422', { contract: ['paths./pos/v1/returns'], ref: ['§6.17', 'приложение А.2'] }, { deps: ['R0', 'K1', 'C2'] });
// Q — QR-оплаты через 1С (только если интеграция с банком умеет — Требования §7.13)
def('Q0', 'Q', 'auto', 'R', 'Статус QR: неизвестный externalId → 404 (есть ли метод)', { contract: ['paths./pos/v1/payments/{externalId}/status'], ref: ['§6.15', '§7.13'] }, { optional: true });
def('Q1', 'Q', 'auto', 'W', 'Пробный QR 1.00 KGS → 201, сумма 1.00, есть QR', { contract: ['paths./pos/v1/payments/qr'], ref: ['§6.14'], kp: ['КП-11'], ac: ['AC-ONEC-075'] }, { deps: ['Q0'], optional: true });
def('Q2', 'Q', 'auto', 'W', 'Повтор QR → 200, тот же QR (reference, строка, срок, сумма)', { contract: ['x-idempotency'], ref: ['§4.7 «Повторы и отмены»', '§6.14 п. 2'], kp: ['КП-11'] }, { deps: ['Q1'], optional: true });
def('Q3', 'Q', 'auto', 'R', 'Статус QR = pending, тот же reference, сумма и срок', { contract: ['QrPaymentStatus'], ref: ['§6.15', '§7.3 п. 7'], ac: ['AC-ONEC-076'] }, { deps: ['Q1'], optional: true });
def('Q4', 'Q', 'auto', 'W', 'Отмена QR → cancelled', { contract: ['paths./pos/v1/payments/{externalId}/qr/cancel'], ref: ['§6.16'], kp: ['КП-13'], ac: ['AC-ONEC-078'] }, { deps: ['Q1'], optional: true });
def('Q5', 'Q', 'auto', 'W', 'Повтор отмены QR → 200 cancelled', { contract: ['x-idempotency'], ref: ['§4.7 «Повторы и отмены»'], kp: ['КП-13'] }, { deps: ['Q4'], optional: true });
def('Q6', 'Q', 'auto', 'R', 'Статус после отмены = cancelled', { ref: ['§6.15'], kp: ['КП-13'] }, { deps: ['Q4'], optional: true });
def('Q7', 'Q', 'auto', 'W', 'Отмена случайного QR → 404', { ref: ['§6.16', 'приложение А.2'] }, { deps: ['Q0'], optional: true });
def('Q8', 'Q', 'auto', 'R', 'Статус QR 20 раз: p95 ≤ 1 с', { ref: ['§4.9', '§8.5'], ac: ['AC-ONEC-076'] }, { deps: ['Q1'], optional: true });
// CK — проверка корзины (обязательный метод); CC — карточка товара (по желанию)
def('CK1', 'CK', 'auto', 'W', 'Проверка корзины (2 строки) → 200', { contract: ['CheckResponse'], ref: ['§6.5'], kp: ['КП-7'], ac: ['AC-ONEC-050'] }, { deps: ['C2'] });
def('CK2', 'CK', 'auto', 'W', 'Корзина с 999999.000 → STOCK_INSUFFICIENT', { ref: ['§6.5', '§8.4'], kp: ['КП-7'], ac: ['AC-ONEC-050'] }, { deps: ['CK1'] });
def('CK3', 'CK', 'auto', 'W', 'Корзина из 101 строки → 400', { contract: ['CheckRequest.maxItems'], ref: ['§6.5'] }, { deps: ['CK1'] });
def('CK4', 'CK', 'auto', 'W', 'Корзина в долг клиента → блок receivables', { contract: ['CheckResponse.receivables'], ref: ['§6.5'], kp: ['КП-7'], ac: ['AC-ONEC-050'] }, { deps: ['CK1'] });
def('CC1', 'CC', 'auto', 'R', 'Карточка товара (если метод есть)', { contract: ['CatalogCard'], ref: ['§6.21'] }, { deps: ['C2'], optional: true });
// M — ручные и полуавтоматические
def('M1', 'M', 'semi', 'R', 'Константа ОбменПриостановлен → 503 POS_E_MAINTENANCE', { contract: ['Unavailable'], ref: ['§4.6 «Выбор кода при недоступности»', '§8.6'] });
def('M8', 'M', 'manual', 'W', 'Созданные объекты найдены в 1С, дублей нет', { ref: ['§4.7'], kp: ['КП-6', 'КП-8', 'КП-14'] }, { deps: ['K1', 'PAY1'] });
def('M9', 'M', 'manual', 'R', 'Запрос виден в журнале POS_ЖурналЗапросовPOS (необязательно)', { ref: ['§4.8'], ac: ['AC-ONEC-054'] }, { optional: true });
def('M10', 'M', 'manual', 'R', 'Во время полного чтения пользователи 1С работали без замедления', { ref: ['§8.5'] }, { deps: ['C2'] });
def('M11', 'M', 'manual', 'R', 'Блокировка объекта → 503 (423) POS_E_LOCKED (программа не выполняет)', { ref: ['§4.6', 'приложение А.2'], kp: ['КП-20'] }, { deps: ['O0'], optional: true });
// E — сквозные правила
def('E1', 'E', 'auto', 'R', 'X-POS-API-Version: 1 в каждом ответе 2xx', { contract: ['headers.XPosApiVersion'], ref: ['§4.4', '§4.5'] });
def('E2', 'E', 'auto', 'R', 'X-Request-Id ответа = запроса; requestId ошибки', { contract: ['XRequestIdEcho', 'Error.requestId'], ref: ['§4.8'] });
def('E3', 'E', 'auto', 'R', 'JSON в UTF-8 без BOM, Content-Type', { ref: ['§4.3'] });
def('E4', 'E', 'auto', 'R', 'Правило GUID (36 символов, нижний регистр)', { contract: ['OnecRef', 'Uuid'], ref: ['§4.3'], ac: ['AC-ONEC-058'] });
def('E5', 'E', 'auto', 'R', 'Форматы: деньги, количество, дата +06:00, телефон, валюта', { contract: ['Money', 'Quantity', 'DateTime', 'PhoneE164', 'Currency'], ref: ['§4.3'], ac: ['AC-ONEC-058'] });
def('E6', 'E', 'auto', 'R', 'Обязательные ключи и null, пустой список — []', { contract: ['required'], ref: ['§4.3'], ac: ['AC-ONEC-058'] });
def('E7', 'E', 'auto', 'R', 'Тело ошибки и код ↔ HTTP-статус', { contract: ['Error', 'ErrorCode', 'x-error-codes'], ref: ['§4.6', 'приложение А'], ac: ['AC-ONEC-055'] });
def('E8', 'E', 'auto', 'R', 'Текст ошибки — понятный текст для журнала', { contract: ['Error.message'], ref: ['§4.6'] });
def('E9', 'E', 'auto', 'R', 'В тексте ошибки нет персональных данных', { contract: ['Error.message'], ref: ['§4.6', '§4.8'] });
def('E10', 'E', 'auto', 'R', 'Время ответа (x-timeout-ms, цели Требований §4.9)', { contract: ['x-timeout-ms'], ref: ['§4.9'] });
def('E11', 'E', 'auto', 'R', 'Ошибка данных — не 5xx / POS_E_INTERNAL', { ref: ['§4.6 «Коды ошибок»'], ac: ['AC-ONEC-055'] });
def('E12', 'E', 'auto', 'R', 'HTTP-статус есть среди ответов операции', { contract: ['responses'], ref: ['приложение А.2'] });
// L — время и объём
def('L1', 'L', 'auto', 'R', 'Время ответа по операциям', { contract: ['x-timeout-ms'], ref: ['§4.9'] });
def('L2', 'L', 'auto', 'R', 'Полное чтение сообщения: объём и скорость', { ref: ['§4.9', '§8.5'] }, { deps: ['C2'] });

export const CATALOG = D;
export const CATALOG_BY_ID = new Map(D.map((d) => [d.id, d]));
export const GROUPS = {
  S: 'Связь и защита канала', A: 'Доступ', H: 'GET /health', C: 'План обмена: /changes, ack, reregister', I: 'Картинки',
  X: 'Сверка /external-ids (желательный метод)', K: 'Клиенты и долги', PAY: 'Оплаты', O: 'Заказы',
  R: 'Заявки на возврат (если 1С принимает их извне — Q-018)', Q: 'QR-оплаты через 1С (если интеграция с банком умеет)',
  CK: 'Проверка корзины', CC: 'Карточка товара (по желанию)',
  M: 'Ручные и полуавтоматические', E: 'Сквозные правила', L: 'Время и объём',
};

/** Выбор по --checks: ID или группы; зависимости добавляются сами. requested — то, что выбрал человек (без зависимостей). */
export function resolveSelection(list) {
  if (!list || !list.length) return null;
  const sel = new Set();
  const unknown = [];
  for (const x of list) {
    if (GROUPS[x]) { for (const d of D) if (d.group === x) sel.add(d.id); continue; }
    if (CATALOG_BY_ID.has(x)) { sel.add(x); continue; }
    unknown.push(x);
  }
  const requested = new Set(sel);
  let grew = true;
  while (grew) {
    grew = false;
    for (const id of [...sel]) for (const dep of CATALOG_BY_ID.get(id).deps) if (!sel.has(dep)) { sel.add(dep); grew = true; }
  }
  for (const base of ['S1', 'S2', 'S3', 'A1', 'H1']) sel.add(base);
  return { sel, unknown, requested };
}

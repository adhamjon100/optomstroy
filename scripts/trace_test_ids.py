#!/usr/bin/env python3
"""Матрица «ID 12_TEST_PLAN → тест/файл или not_done с причиной» по этапам дорожной карты 13.

Этап D (RM-D-011 п. 1, ревью D-MJ-02): все T-AUTH, T-REG, T-SESS, T-SMS, T-BIO и T-SEC класса A (колонка «Авто?»
содержит A), плюс T-ADMIN-010 (аварийный код, RM-D-016).

Этап E (RM-E-012 п. 1, 13 §7 строка 7.10; ревью E-trace-1): охват по 12 §2.15, строка «E — Catalog» —
T-CAT, T-INV, T-FAV (все), T-SYNC-001…030, T-SYNC-043…046, T-ONEC-001…019, T-PERF-001, T-PERF-002;
плюс приёмочные наборы экранов этапа T-UI-010…017, T-UI-042, T-UI-043, T-UI-045, T-UI-050 и T-SEC класса A,
относящиеся к каталогу и фото: T-SEC-017 (field-level), T-SEC-027 (инъекции в поиске), T-SEC-046 (фото из 1С).

Этап F (RM-F-009 «T-CART/T-ORD/T-PAY/T-PRINT из 12 запущены»; ревью F-trace-1): охват по 12 §2.15, строка
«F — Cart and POS» — T-CART, T-ORD, T-MNY, T-PAY, T-DISC (все), T-SYNC-031…042, T-SYNC-F01…F18, T-FAIL-003…013;
плюс T-NOTIF, T-PRINT (RM-F-004, RM-F-008), T-TXN-001/005/008/011 (журнал операций заказа/платежа), T-SEC класса A
этапа F (IDOR, field-level, step-up, mass assignment, скидки, идемпотентность финансовых POST, логи, QR, финансовая
история, долг fail-closed, привязка клиента, аудит долга, файлы документов), приёмочные наборы экранов
T-UI-020…026, T-UI-044 и компоненты дизайн-системы T-DS-015/040/046/055/082/085.

Ссылка на ID ищется в тестах backend (pos-api/test, pos-api/src/**/*.spec.ts, бенчмарки pos-api/test/**/bench)
и Flutter (pos-app/test, pos-app/integration_test) — полным написанием `T-XXX-NNN` (в имени теста или комментарии).
Статусы строки:
  тест          — ID найден в тексте теста;
  тест (трасса) — тест есть, но ID в его тексте не записан (тесты pos-app этапов E и F: правка pos-app не входила
                  в исправления E-trace-1 и F-trace-1); ссылка «файл::подстрока названия теста» в TRACE проверяется —
                  нет файла или подстроки → ошибка (код 1);
  not_done      — автотеста нет, причина в NOT_DONE (ручной/устройство/этап F–H/условно/не реализовано);
  НЕТ           — ни теста, ни причины → ошибка (код 1).
К статусу «тест» добавляется «частично: …», если в NOT_DONE/PARTIAL записано, какая часть сценария не проверена.
Для T-UI-0xx дополнительно считается доля AC-UI экрана (02), упомянутых в тестах pos-app; набор считается
выполненным только при 100 % (по одному исполняемому кейсу на AC — 12 §3.9), иначе — not_done с долей.

Запуск (из корня репозитория):
  python -I -X utf8 scripts/trace_test_ids.py [--stage D|E|F|G]          # матрица в stdout, код 0/1
  python -I -X utf8 scripts/trace_test_ids.py [--stage D|E|F|G] --summary # только итоги
По умолчанию --stage D (совместимость с D_test_run.log).
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

PLAN = 'docs/specification/12_TEST_PLAN.md'
SCREENS = 'docs/specification/02_SCREEN_SPECIFICATION.md'
TEST_ROOTS = ('pos-api/test', 'pos-api/src', 'pos-app/test', 'pos-app/integration_test')
APP_TEST_ROOTS = ('pos-app/test', 'pos-app/integration_test')

# ======================================================================================== этап D
D_GROUPS = ('AUTH', 'REG', 'SESS', 'SMS', 'BIO')
D_EXTRA = ('T-ADMIN-010',)

# Причины «не выполнено на этапе D» (ID без автотеста). Ключ — ID; значение — категория и пояснение.
NOT_DONE_D: dict[str, str] = {
    # --- устройства / вручную (ревью D-MJ-03; эмулятор не стартовал — D_test_run.log) ---
    'T-AUTH-009': 'устройство: widget-часть — unlock_screen_test; Android-эмулятор не стартовал (нет места на C:, D-MJ-03)',
    'T-AUTH-030': 'integration_test: два пользователя на одном устройстве не автоматизированы; widget — «Сменить аккаунт»',
    'T-AUTH-033': 'integration_test: убийство процесса на SCR-02 не автоматизировано (данные SCR-02 — только память '
    'AuthFlowNotifier; secure storage/drift не содержат challengeId — registration_draft_dao_test)',
    'T-BIO-001': 'устройство: системный BiometricPrompt не проверен (эмулятор не стартовал, D-MJ-03); widget-часть — '
    'registration_security_screen_test',
    'T-BIO-003': 'manual (класс B): смена отпечатка на устройстве не выполнена — эмулятор не стартовал (D-MJ-03)',
    'T-BIO-005': 'manual: Android без Class 3 / API 24–27 — нет устройства; логика API < 30 — biometric_port_test',
    'T-BIO-006': 'manual (класс B): криптопривязка на устройстве не проверена (D-MJ-03); код — static-тест T-BIO-018',
    'T-BIO-007': 'условно (Q-008): iOS — нет macOS/Xcode; код AppDelegate.swift не собирался',
    'T-BIO-017': 'manual (P3): рутованное устройство — нет устройства',
    'T-SESS-021': 'integration_test холодного старта без сети на устройстве не автоматизирован; widget/DAO-части есть',
    'T-SMS-018': 'стенд: нет тестового аккаунта SMSPro (Q-029, RM-A-004)',
    'T-SMS-019': 'manual: нет аккаунта SMSPro и разрешения заказчика на реальные SMS (RM-A-004)',
    'T-SMS-015': 'скан (не тест): scripts/check_secrets.py и scripts/check_env_example.py — прогон в D_test_run.log',
    # --- условные / не принятые в R1 ---
    'T-REG-014': 'условно (P3): режим «форма → OTP» в R1 не принят (09 §7.1 — OTP → форма)',
    'T-SESS-012': 'P3: уведомление о новом устройстве (SESS-017) не реализовано на этапе D — D_spec_questions',
    'T-AUTH-025': 'P3: ссылка «Изменить номер» на SCR-02 без отдельного widget-теста (возврат с тем же номером — '
    'phone_screen_test AC-UI-01-013)',
    'T-REG-008': 'P3: типы клавиатур формы регистрации без отдельного widget-теста',
    # --- последующие этапы (маршрутов/модулей ещё нет) ---
    'T-REG-019': 'этап E/F: финансовые маршруты клиента (GET /customers/{id}, /receivables) не реализованы (D-MN-07); '
    'часть D — customer-links.e2e (customer-match без финансов)',
    'T-SEC-011': '',
    'T-SEC-017': 'долг/дашборд/клиенты — этапы F/G; часть D — customer-match без финансов; часть E — остатки customer '
    '(catalog-api.e2e, матрица --stage E)',
    'T-SEC-022': 'этап F: скидки (лимит роли) не реализованы',
    'T-SEC-023': 'этап F: финансовые POST не реализованы',
    'T-SEC-027': 'sqlmap (класс B) не запускался — этап H; класс A — search.e2e, search-text (этап E)',
    'T-SEC-036': 'сборки: strings/MobSF по APK/EXE — этап H (release); http:// в конфигурации — T-SMS-014',
    'T-SEC-037': 'скан: scripts/check_secrets.py (прогон в D_test_run.log); gitleaks/docker — CI (Q-233)',
    'T-SEC-038': '',
    'T-SEC-039': 'этап F: подтверждение QR-оплаты не реализовано',
    'T-SEC-040': 'P2: CORS/cookie без отдельного теста этапа D (CORS_ALLOWED_ORIGINS — каркас C); push-DLR — '
    'sms-dlr-push.spec',
    'T-SEC-041': 'этап F: финансовая история не реализована',
    'T-SEC-042': 'этап F: продажа в долг не реализована',
    'T-SEC-047': 'инфраструктура/юридически (трансграничная передача) — вне кода этапа D',
    'T-SEC-054': 'CI: зависимости и образы — CI-раннер (Q-233), не локальный прогон',
    'T-SEC-055': 'часть D — customer-links.e2e; остальное (integration/orders/sync) — этапы E–G',
    'T-SEC-067': 'этап E/F: ответы с суммами долга не реализованы',
}

# ======================================================================================== этап E
E_SEC = ('T-SEC-017', 'T-SEC-027', 'T-SEC-046')
E_UI = (10, 11, 12, 13, 14, 15, 16, 17, 42, 43, 45, 50)

_APP = 'pos-app/test/'
_CAT = _APP + 'features/catalog/'
_PD = _APP + 'features/product_details/'
_SCAN = _APP + 'features/scan/'

# Тесты pos-app без T-ID в тексте: «файл::подстрока названия теста». Проверяется наличие файла и подстроки.
TRACE_E: dict[str, list[str]] = {
    'T-CAT-001': [_CAT + 'presentation/catalog_screen_test.dart::скелетон первой загрузки, затем карточки',
                  _CAT + 'presentation/catalog_providers_test.dart::подгрузка: курсор, без дублей'],
    'T-CAT-003': [_CAT + 'presentation/catalog_screen_test.dart::профиль, колокольчик; сайдбар',
                  _APP + 'design_system/catalog_components_test.dart::CategorySidebarItem: выбранный не реагирует'],
    'T-CAT-004': [_CAT + 'presentation/category_screen_test.dart::категория с подкатегориями: лента «Все» + дети',
                  _CAT + 'presentation/category_screen_test.dart::крошки при глубине ≥ 2 ведут к уровню'],
    'T-CAT-005': [_PD + 'product_details_screen_test.dart::несколько вариантов: селектор, смена варианта',
                  _PD + 'product_details_screen_test.dart::товар с одним вариантом не показывает VariantSelector'],
    'T-CAT-006': [_APP + 'design_system/product_components_test.dart::путь файла по sha256 и размеру',
                  _APP + 'design_system/product_components_test.dart::несколько фото — индикатор'],
    'T-CAT-007': [_PD + 'product_details_screen_test.dart::seller на expanded: таблица складов',
                  _APP + 'design_system/product_components_test.dart::seller: Склад · Доступно'],
    'T-CAT-008': [_APP + 'design_system/product_components_test.dart::нет фото — заглушка «Нет фото» (INV-050)'],
    'T-CAT-009': [_CAT + 'presentation/catalog_search_screen_test.dart::пустой результат: «Ничего не найдено по',
                  _CAT + 'presentation/catalog_screen_test.dart::карточка: нет в наличии / нет цены / остаток неизвестен',
                  _PD + 'product_details_screen_test.dart::404 без кэша'],
    'T-CAT-011': [_CAT + 'presentation/catalog_search_screen_test.dart::1 буква — «Введите ещё 1 символ»',
                  _CAT + 'presentation/catalog_search_screen_test.dart::6 символов с интервалом 100 мс',
                  _CAT + 'presentation/catalog_search_screen_test.dart::строка из 1 цифры запускает поиск',
                  _CAT + 'presentation/catalog_providers_test.dart::debounce 300 мс; < 2 букв — нет запроса'],
    'T-CAT-012': [_APP + 'core/hardware/hid_wedge_detector_test.dart::символы через 10 мс + Enter через 10 мс',
                  _APP + 'core/hardware/scanner_wedge_service_test.dart::фокус вне полей: быстрая серия + Enter',
                  _SCAN + 'hid_scan_scope_test.dart::HID-скан существующего кода → SCR-14',
                  _APP + 'app/scan_cart_wiring_test.dart::cashier (умолчание): строка в cart_items_draft',
                  _APP + 'app/scan_cart_wiring_test.dart::seller (умолчание): открывается карточка SCR-14'],
    'T-CAT-013': [_SCAN + 'scan_screen_test.dart::нет разрешения камеры → EmptyState',
                  _SCAN + 'scan_screen_test.dart::найдено (серия выкл.)',
                  _SCAN + 'scan_domain_test.dart::код принимается во 2-м кадре подряд'],
    'T-CAT-016': [_CAT + 'presentation/catalog_screen_test.dart::сортировка: «По артикулу» → новый запрос'],
    'T-CAT-017': [_CAT + 'presentation/catalog_filters_screen_test.dart::счётчик «Показать N товаров»',
                  _CAT + 'presentation/catalog_screen_test.dart::compact: «Фильтры» открывает лист SCR-13'],
    'T-CAT-018': [_CAT + 'presentation/catalog_screen_test.dart::вид «Сетка/Список/Компакт» — без сетевых запросов',
                  _APP + 'design_system/catalog_components_test.dart::ViewModeSegmented: три сегмента'],
    'T-CAT-020': [_CAT + 'presentation/catalog_screen_test.dart::«Недавние» в панели управления: подборка + «Очистить»',
                  _CAT + 'presentation/category_screen_test.dart::подборки «Недавние» и «Избранное» видимы'],
    'T-CAT-021': [_CAT + 'presentation/catalog_screen_test.dart::шапка expanded: логотип, поиск, часы и дата (UI-10-005, UI-10-032), профиль'],
    'T-CAT-022': [_APP + 'core/database/catalog_dao_test.dart::избранное: favoriteOnly и признак isFavorite'],
    'T-CAT-023': [_CAT + 'data/local/offline_first_repositories_test.dart::офлайн: каталог и карточка из кэша',
                  _CAT + 'presentation/catalog_screen_test.dart::нет сети: кэш + OfflineBanner',
                  _CAT + 'presentation/catalog_search_screen_test.dart::офлайн: «Поиск по сохранённому каталогу',
                  'pos-app/integration_test/catalog_flow_test.dart::офлайн — каталог и карточка из кэша с баннером'],
    'T-CAT-024': [_SCAN + 'scan_domain_test.dart::нет сети → поиск по кэшу barcodes',
                  _SCAN + 'scan_screen_test.dart::офлайн → найдено по кэшу'],
    'T-CAT-025': [_APP + 'core/sync/catalog_sync_engine_test.dart::все сущности страницами до hasMore=false',
                  _APP + 'core/sync/catalog_sync_engine_test.dart::обрыв на середине products → курсор сохранён',
                  _CAT + 'data/local/bulk_load_perf_test.dart::конвейер первичной загрузки: 50 000 SKU'],
    'T-CAT-026': [_APP + 'design_system/catalog_components_test.dart::название 2 строки с многоточием'],
    'T-CAT-027': [_CAT + 'presentation/catalog_providers_test.dart::артикул не указан'],
    'T-CAT-029': [_PD + 'golden/product_details_golden_test.dart::SCR-14 карточка товара'],
    'T-CAT-030': [_PD + 'customer_mode_product_test.dart::customer: чип «Ваш вид цены'],
    'T-CAT-032': [_CAT + 'presentation/customer_mode_catalog_test.dart::SCR-11 customer: status — «В наличии» без чисел',
                  _APP + 'features/home/customer_home_screen_test.dart::status: StockBadge без чисел'],
    'T-CAT-034': [_CAT + 'data/catalog_repositories_test.dart::409 VERSION_CONFLICT cursor_expired'],
    'T-CAT-036': [_PD + 'customer_mode_product_test.dart::привязка корня: сервер `status`',
                  _PD + 'customer_mode_product_test.dart::привязка корня: сервер `quantity`'],
    'T-INV-001': [_APP + 'core/utils/qty_test.dart::MV-24: «2.3333», precision 3 → ошибка'],
    'T-INV-002': [_APP + 'core/utils/qty_test.dart::MV-05: 5 кор × 12 = 60 шт',
                  _APP + 'design_system/product_components_test.dart::одна единица — readonly',
                  _PD + 'product_details_screen_test.dart::упаковка «кор (6 шт)»'],
    'T-INV-003': [_PD + 'product_details_screen_test.dart::кратность 12: шаг степпера 12',
                  _PD + 'qty_rules_test.dart::QTY_NOT_MULTIPLE с предложением округлить вверх'],
    'T-INV-004': [_PD + 'product_details_screen_test.dart::минимальная партия 5',
                  _PD + 'qty_rules_test.dart::QTY_BELOW_MIN'],
    'T-INV-005': [_APP + 'core/utils/qty_test.dart::MV-07: 2,5 кор × 12'],
    'T-INV-008': [_APP + 'core/utils/qty_test.dart::MV-06: 43 шт, factor 12 → 3 кор + 7 шт',
                  _PD + 'qty_rules_test.dart::пересчёт в упаковки: 12 шт → 2 кор'],
    'T-INV-009': [_APP + 'core/utils/qty_test.dart::MV-23: «1 200,5», precision 1'],
    'T-INV-010': [_APP + 'design_system/product_components_test.dart::первая цифра заменяет значение',
                  _PD + 'product_details_screen_test.dart::двойной клик в пределах 300 мс'],
    'T-INV-012': [_CAT + 'presentation/catalog_providers_test.dart::устаревание > 30 мин'],
    'T-INV-014': [_PD + 'product_details_screen_test.dart::INV-052: неизвестный остаток'],
    'T-FAV-002': [_CAT + 'presentation/catalog_screen_test.dart::избранное: мгновенное переключение; ошибка сервера'],
    'T-SYNC-024': [_APP + 'features/sync_status/sync_status_screen_test.dart::краткий статус, без кнопок запуска'],
    'T-SYNC-025': [_APP + 'features/sync_status/sync_status_screen_test.dart::вкладка «Прогоны»'],
    'T-SYNC-028': [_APP + 'core/sync/sync_scheduler_test.dart::возраст — самая старая метка products/prices/stock',
                   _APP + 'features/sync_status/sync_widgets_test.dart::ConnectedSyncIndicator: устаревшие цены'],
}

# Что из сценария ID не проверено, хотя тест есть (выводится как «частично: …»).
PARTIAL_E: dict[str, str] = {
    'T-CAT-001': 'golden SCR-10 «Загружаем ещё товары…» — только в составе T-UI-010',
    'T-CAT-002': 'widget SCR-11 с вариантом из артикула — без отдельного теста',
    'T-CAT-006': 'curl -I на запущенном Caddy не выполнялся (Docker/Caddy нет) — проверена конфигурация Caddyfile',
    'T-CAT-009': 'VARIANT_UNAVAILABLE при добавлении в серверную корзину — этап F',
    'T-CAT-012': 'integration_test на Windows с реальным HID-сканером и ручной протокол RM-E-010 п. 3 не выполнены '
    '(сканера RM-A-008 нет)',
    'T-CAT-013': 'integration_test на Android и ручная часть — нет устройства/камеры (эмулятор не стартует)',
    'T-CAT-016': 'golden подписи сортировки на SCR-10; восстановление сортировки после перезапуска — только prefs',
    'T-CAT-022': 'раздел SCR-40 — этап G',
    'T-CAT-023': 'integration_test на Android не выполнялся; Windows — catalog_flow_test',
    'T-CAT-024': 'integration_test (устройство) не выполнялся — unit/widget',
    'T-CAT-025': '≤ 3 мин на целевом устройстве по Wi-Fi (NFR-PERF-006) не замерено — нет устройства',
    'T-CAT-026': 'golden 180 символов в корзине/компакте — не отдельным тестом',
    'T-CAT-027': 'скрытие блоков описания/характеристик SCR-14 — без отдельного теста',
    'T-CAT-030': 'выбор клиента в корзине — этап F',
    'T-CAT-031': 'is_sellable=false и «товар без цены не добавляется» — проверка корзины на этапе F',
    'T-CAT-035': 'POST /cart/checkout-preview и скидка клиента 1С — этап F',
    'T-CAT-036': 'корзина/checkout-preview с conflicts[] — этап F; смена ключа через PUT /admin/settings — RM-G-014',
    'T-INV-001': 'серверная часть PUT /cart/items (400 VALIDATION_FAILED) — этап F',
    'T-INV-003': 'серверный 422 QTY_NOT_MULTIPLE — этап F (PUT /cart/items)',
    'T-INV-004': 'серверный 422 QTY_BELOW_MIN — этап F',
    'T-INV-008': 'отображение в строке корзины — этап F',
    'T-INV-009': '« 007 » и значение сверх максимума — без отдельного кейса',
    'T-INV-010': 'один PUT /cart/items через 500 мс — этап F (серверная корзина)',
    'T-INV-012': '«добавление в корзину не меняет reserved» — этап F',
    'T-FAV-007': 'загрузка из 1С проверена статически (конвейер sync не пишет favorites_products)',
    'T-SYNC-001': 'сущности вне каталога (customers, receivables, история) — этапы F/G; прогресс на SCR-43 — widget',
    'T-SYNC-003': 'сбой страницы 3 из 10 при full фазы 0 (500 после повторов → partial, остальные страницы '
    'применены, 0 пометок удаления) — без отдельного теста; проверены ошибки позиций (partial) и сбой страницы '
    '/changes (откат сообщения, 05 §6.2); уведомление sync_error — sync.int',
    'T-SYNC-004': 'повтор outbox-сообщения с externalId (200 от 1С) — этап F',
    'T-SYNC-006': 'заказ cash/credit при недоступной 1С — этап F; /health/ready=degraded — без теста этапа E',
    'T-SYNC-008': 'продолжение фазы 0 с cursor_to — нет (в режиме расширения повтор сообщения целиком)',
    'T-SYNC-012': '',
    'T-SYNC-024': 'pending_manual_orders и финансовая метка — этапы F/G',
    'T-SYNC-025': 'фильтр по сущности/коду в UI журнала — без отдельного теста',
    'T-SYNC-026': 'ping/fail Healthchecks — не реализовано в тестах (нет стенда)',
    'T-SYNC-028': 'индикатор в корзине — этап F',
    'T-SYNC-045': 'PUT /cart/items → 422 VARIANT_UNAVAILABLE — этап F; товар без цены/остатка/артикула без '
    'sync_errors — по коду, без отдельного кейса',
    'T-ONEC-001': 'OData-часть FakeOnecGateway — синтетический источник (ODataCatalogSource), не фикстуры $metadata',
    'T-ONEC-002': 'анализ трафика сборок — вручную, не выполнялся',
    'T-ONEC-003': 'L3 (тестовая копия) не выполнялся — API 1С не получен (RM-E-016); «несовместимость → paused» '
    'без теста этапа E',
    'T-ONEC-004': 'L3 и сообщения 1 000/2 500/5 000 элементов на копии — нет копии 1С',
    'T-ONEC-012': 'L3 — нет копии 1С',
    'T-ONEC-014': 'полная таблица 05 §6.5 по каждому POS_E_* — частично (401, 503, 404, временные/постоянные)',
    'T-ONEC-016': 'запись в POS_ЖурналЗапросовPOS — L3, нет копии 1С',
    'T-ONEC-017': 'сверка ответов реального расширения — L3',
    'T-ONEC-019': 'поля без подтверждения $metadata не сверены с копией — нет копии 1С',
    'T-SEC-017': 'долг, дашборд, клиенты — этапы F/G; costPrice в DTO каталога отсутствует по схеме (OpenAPI-валидация)',
    'T-SEC-027': 'sqlmap (класс B) не запускался — этап H',
    'T-SEC-046': '`GET /images/../secrets/x` — по конфигурации Caddyfile, живой Caddy не запускался',
}
PARTIAL_E = {k: v for k, v in PARTIAL_E.items() if v}

NOT_DONE_E: dict[str, str] = {
    # --- последующие этапы (маршрутов/модулей ещё нет) ---
    'T-CAT-033': 'этап F: серверная корзина и price_snapshot не реализованы',
    'T-INV-006': 'этап F: строка корзины (ConfirmDialog при 0) — экран корзины не реализован',
    'T-INV-007': 'этап F: серверная валидация PUT /cart/items; клиентская часть — qty_rules_test, qty_test',
    'T-INV-011': 'этап F: GET /cart, checkout-preview не реализованы',
    'T-FAV-005': 'этап G: избранные клиенты (RM-G) не реализованы',
    'T-FAV-006': 'этап G: SCR-40 «Избранное» не реализован',
    'T-SYNC-011': 'этап G: sales_history не загружается на этапе E',
    'T-SYNC-015': 'этапы F/G: снимок долгов (receivables) не реализован',
    'T-SYNC-016': 'этап F: статусы заказов (order_status) — заказов ещё нет',
    'T-SYNC-017': 'этап G: документы истории (sales_history, payment_docs, return_docs)',
    'T-SYNC-018': 'этап G: инкремент customers и конфликт привязки (часть D — customer-links)',
    'T-SYNC-029': 'этап F: корзина и уведомления cart_price_changed/cart_stock_changed',
    'T-SYNC-030': 'L2: нет тестовой копии 1С (RM-A-006, RM-E-016 — API 1С не получен)',
    'T-SYNC-046': 'этап F: синхронная проверка при создании заказа (фаза 0)',
    'T-ONEC-005': 'этап F: POST /pos/v1/orders — HTTP-клиент проверен только на моке (onec-extension.gateway '
    '«прочие методы контракта»), L3 — нет копии 1С',
    'T-ONEC-006': 'этап F: статусы заказов в 1С (HTTP-клиент — мок)',
    'T-ONEC-007': 'этап F: отмена заказа в 1С (HTTP-клиент — мок)',
    'T-ONEC-008': 'этап F: регистрация оплаты (HTTP-клиент — мок)',
    'T-ONEC-009': 'этап G: клиенты в 1С (поиск по телефону — часть D customer-links на FakeOnecGateway)',
    'T-ONEC-010': 'этап G: долги клиента',
    'T-ONEC-011': 'этап G: заявка на возврат (P3)',
    'T-ONEC-013': 'этап F: синхронная проверка корзины POST /pos/v1/check',
    'T-ONEC-015': 'manual L2: разведение пользователей ИБ — нет тестовой копии 1С',
    'T-ONEC-018': 'условно: входящий обмен C-2 (RM-E-013) не выбран — действует ONEC_INBOUND_ENABLED=false; 422 '
    'inbound_mode — sync.int (T-SYNC-023)',
    'T-PERF-001': 'k6 50 VU 10 мин на D-CATALOG-L не запускался; замкнутый цикл autocannon (жёстче профиля) — '
    'T-PERF-002, docs/perf/E_search_benchmark.md',
    # --- не реализовано / без теста (известные проблемы этапа E, E_catalog_report §3) ---
    'T-SYNC-005': 'НЕ ПОКРЫТО: (а) «побеждает 1С» — косвенно catalog-apply; (б) BARCODE_CONFLICT без теста, правило '
    'выбора привязки в catalog-applier.ts («последняя запись пакета») расходится с 05 ONEC-017 п. 2 (текущая '
    'привязка, иначе наименьший ключ) — E-KI-03; (в) статусы заказов — этап F; (г) привязка клиента — этап G',
    'T-SYNC-009': 'НЕ РЕАЛИЗОВАНО: отчёт о дублях onec_code при full (код DUPLICATE_SUSPECTED есть в перечне '
    'sync_errors, обработки нет) — E-KI-04',
    'T-SYNC-019': 'НЕ ПОКРЫТО: BARCODE_CONFLICT и перечитка упаковок без отдельного теста; правило выбора — E-KI-03',
    'T-INV-013': 'P3: нет теста; клиент — product_details_notifier.dart (цена товара при отсутствии цены варианта); '
    'серверный подстановочный механизм в каталоге не найден — проверить на этапе F (корзина)',
    'T-CAT-028': 'P3: нет отдельного widget-теста «8 + Показать все» (реализация product_sections.dart, UI-14-016)',
    # --- приёмочные наборы T-UI (по кейсу на каждый AC-UI экрана, 12 §3.9) ---
    'T-UI-010': 'приёмочный набор не собран (pos-app; этап H — полный прогон)',
    'T-UI-011': 'приёмочный набор не собран (pos-app; этап H)',
    'T-UI-012': 'приёмочный набор не собран (pos-app; этап H)',
    'T-UI-013': 'приёмочный набор не собран (pos-app; этап H)',
    'T-UI-014': 'приёмочный набор не собран (pos-app; этап H)',
    'T-UI-015': 'приёмочный набор не собран (pos-app; этап H)',
    'T-UI-016': 'приёмочный набор не собран (pos-app; этап H)',
    'T-UI-017': 'приёмочный набор не собран; камера — нет устройства',
    'T-UI-042': 'приёмочный набор не собран (pos-app; этап H)',
    'T-UI-043': 'приёмочный набор не собран (pos-app; этап H)',
    'T-UI-045': 'приёмочный набор не собран (экран этапа D; pos-app; этап H)',
    'T-UI-050': 'приёмочный набор не собран (pos-app; этап H)',
}


# ======================================================================================== этап F
F_GROUPS = ('CART', 'ORD', 'MNY', 'PAY', 'DISC', 'NOTIF', 'PRINT')
F_TXN = (1, 5, 8, 11)
F_SEC = (15, 17, 20, 21, 22, 23, 29, 39, 41, 42, 55, 67, 68)
F_UI = (20, 21, 22, 23, 24, 25, 26, 44)
F_DS = (15, 40, 46, 55, 82, 85)

_FAPP = 'pos-app/test/'
_FCART = _FAPP + 'features/cart/'
_FCHK = _FAPP + 'features/checkout/'
_FORD = _FAPP + 'features/orders/'
_FNOT = _FAPP + 'features/notifications/'
_FDS = _FAPP + 'design_system/'
_FNET = _FAPP + 'core/network/'
_CS = _FCART + 'presentation/cart_screen_test.dart::'
_DCS = _FCART + 'data/drift_cart_sync_test.dart::'
_PK = _FCART + 'presentation/parked_carts_screen_test.dart::'
_CO = _FCHK + 'presentation/checkout_screen_test.dart::'
_OC = _FCHK + 'presentation/order_created_screen_test.dart::'
_OSR = _FCHK + 'presentation/order_submission_recovery_test.dart::'
_OD = _FORD + 'presentation/order_details_screen_test.dart::'
_DIO = _FNET + 'dio_client_test.dart::'
_API = 'pos-api/test/'
_PFT = 'pos-app/integration_test/pos_flow_test.dart::'
_PFT_LOST = _PFT + 'RM-F-013 п. 4, CART-022 (а): ответ POST /orders потерян → повтор тем же ключом, один заказ'

# Причины «не выполнено на этапе F» (ID без автотеста). Ключ — ID; значение — категория и пояснение. ID без теста и
# без причины — ошибка (код 1). Ревью F-trace-1 (раунд 2): разметка T-ID в тестах backend, трасса тестов pos-app
# (тесты pos-app — по подстроке имени), недостающие тесты backend
# (orders-trace-f.e2e, stage-f-static, health T-FAIL-012, ddl-behavior T-SYNC-040, outbox T-SYNC-035/T-MNY-032).
NOT_DONE_F: dict[str, str] = {
    # --- последующие этапы (владелец — задача 13) ---
    'T-PAY-021': 'этап G: снимок долга и CreditDecisionService (RM-G-002); на этапе F — fail-closed (T-SEC-042)',
    'T-PAY-023': 'этап G: разблокировка старшим при реальном решении по долгу; override проверен на fail-closed',
    'T-PAY-024': 'этап G: долг при недоступной 1С и свежем полном снимке — нужен снимок receivables (RM-G-002)',
    'T-PAY-026': 'условно (Q-152), should: оплата долга без заказа — не реализуется в R1/этапе F',
    'T-PAY-020': 'этап G (RM-G-006): отчёт GET /admin/reports/qr-reconciliation не реализован на F',
    'T-DISC-009': 'этап G (RM-G-007): экран SCR-35 «Скидки и условия» не реализован на F',
    'T-DISC-012': 'этап G (RM-G-003): PUT /admin/discount-limits не реализован на F (лимиты — seed Q-015)',
    'T-SEC-067': 'этап G (RM-G-002, RM-G-006): ответов с суммами долга на F нет (долг fail-closed, суммы не отдаются)',
    'T-SYNC-038': 'этап G (RM-G-001): создание клиента через outbox (T-CUST-005); на F — порядок «заказ после своего '
    'клиента» (depends_on) — orders-outbox-concurrency.e2e (T-SYNC-032)',
    'T-SYNC-039': 'этап G (RM-G-005): заявки на возврат и канал outbox return_request',
    'T-SYNC-F08': 'этап G (RM-G-001): дубликат клиента (POS_E_DUPLICATE клиента, перепривязка заказа)',
    'T-SYNC-F10': 'этап G (RM-G-001, SYNC-019): смена телефона привязанного клиента в 1С',
    'T-SYNC-F14': 'этап H (RM-H-003, RM-H-008): учение класса D — смена пароля pos_integration и ключа, ротация env',
    'T-SYNC-F15': 'этап H (RM-H-004, RM-H-008): восстановление ≤ RTO — учение на контуре; часть «API без БД → '
    'восстановление без ручных действий» — health.e2e T-FAIL-012',
    'T-SYNC-F16': 'этап H (T-SYNC-048): восстановление backend из бэкапа и reconcile по externalId — учение на контуре',
    'T-PAY-012': 'R2 (ядро §24.4): прямой провайдер QR bakai',
    'T-PAY-014': 'R2 (ядро §24.4): вебхук банка bakai',
    'T-PAY-015': 'R2 (ядро §24.4): вебхук банка bakai (расхождение суммы при onec — payments-qr-onec amount_mismatch)',
    # --- приёмочные наборы pos-app (счётчик AC-UI выводит этот скрипт; SCR-20…22 — полные наборы
    # cart_acceptance_test, checkout_acceptance_test, order_created_acceptance_test) ---
    'T-UI-023': 'приёмочный набор SCR-23 неполон (счётчик AC-UI — в этой строке): widget-кейсы presentation в '
    'прогоне данных и инфраструктуры этапа F не писались — закрыть до ворот G-F (F_cart_pos_report §4.1)',
    'T-UI-024': 'приёмочный набор SCR-24 неполон (счётчик AC-UI — в этой строке): widget-кейсы presentation в '
    'прогоне данных и инфраструктуры этапа F не писались — закрыть до ворот G-F (F_cart_pos_report §4.1)',
    'T-UI-025': 'приёмочный набор SCR-25 неполон (счётчик AC-UI — в этой строке): widget-кейсы presentation в '
    'прогоне данных и инфраструктуры этапа F не писались — закрыть до ворот G-F (F_cart_pos_report §4.1)',
    'T-UI-026': 'приёмочный набор SCR-26 неполон (счётчик AC-UI — в этой строке): widget-кейсы presentation в '
    'прогоне данных и инфраструктуры этапа F не писались — закрыть до ворот G-F (F_cart_pos_report §4.1)',
    'T-UI-044': 'приёмочный набор SCR-44 неполон (счётчик AC-UI — в этой строке): widget-кейсы presentation в '
    'прогоне данных и инфраструктуры этапа F не писались — закрыть до ворот G-F (F_cart_pos_report §4.1)',
    'T-SEC-068': 'класс B (12: «нет (B)» — перед релизом, вручную на Android и Windows с осмотром каталогов) — этап H; '
    'на F файлов PDF приложение не создаёт: документ — байты в памяти (OrderDocumentFile), «Скачать PDF» — системный '
    'диалог file_selector; ConfirmDialog order_doc_pdn_warning — widget SCR-24',
    # --- ручные / review / скан ---
    'T-MNY-030': 'скан (не тест): scripts/check_no_double_money.sh — прогон в F_test_run.log (FIX раунд 2)',
    'T-ORD-015': 'review/integration: фискальные реквизиты (ставка налога, признак аванса/постоплаты, ИНН) в order_items '
    'не хранятся — R1 без фискализации (10 ORD-…); позиции с ценой/количеством/единицей/способом — orders-create.e2e',
    'T-PRINT-005': 'manual: печать на принтерах 80 мм и A4 с Windows-POS — нет принтеров (RM-A-008)',
    'T-PRINT-009': 'review: Q-019 (принтеры, формы, НДС) — ответ заказчика не получен (FIX-FE-03)',
    'T-PAY-019': 'integration L3 (Q-012): один способ создания документа поступления — на F QR создаёт и проводит 1С '
    '(provider onec), outbox POS для QR нет (payments-qr-onec); проверка на копии 1С — RM-F-010',
    # --- 1С: L3 / известные проблемы этапа E ---
    'T-SYNC-F17': 'L3: нет тестовой копии 1С (RM-F-010, F_onec_e2e_report.md)',
    'T-SYNC-F18': 'L3: нет тестовой копии 1С (RM-F-010, F_onec_e2e_report.md)',
    'T-SYNC-F03': 'долг этапа E (backend, вне объёма F): продолжение полной загрузки с cursor_to не реализовано (в '
    'режиме расширения — повтор сообщения целиком; PARTIAL_E T-SYNC-008); «partial → полная перезагрузка» — sync.int',
    'T-SYNC-F09': 'долг этапа E (E-KI-03, backend, вне объёма F): BARCODE_CONFLICT и правило выбора привязки без '
    'теста (NOT_DONE_E T-SYNC-019)',
    'T-SYNC-F12': 'L3: рост регистраций плана обмена (registrationBacklog > 100 000) и reregister — FakeOnecGateway не '
    'моделирует backlog; нет копии 1С',
    'T-SYNC-F13': 'долг этапа E (backend, вне объёма F): несовместимая apiVersion расширения → paused — без теста '
    '(PARTIAL_E T-ONEC-003)',
    # --- не реализовано на F (вопросы владельцам — F_spec_questions, раздел FIX) ---
    'T-TXN-008': 'backend, открытый FIX-F-21 (решение владельца 10): при уточнении итога 1С хранятся оба итога '
    '(totals_differ — T-MNY-032), но запись '
    'transactions не обновляется и старое значение в аудит не пишется — FIX-F-21',
}

# Тесты без T-ID в тексте (pos-app): «файл::подстрока». Проверяется наличие подстроки.
TRACE_F: dict[str, list[str]] = {
    'T-CART-002': [_CS + 'крестик: «Позиция удалена · Отменить» — строка возвращается без запроса',
                   _CS + 'клавиатура Windows: ↓ → «+» → Delete → Ctrl+Z → F9 без мыши'],
    'T-CART-003': [_CS + 'серия «+» с интервалом < 500 мс → один PUT mode=set с итоговым количеством',
                   _CS + '«−» на минимальном количестве — ConfirmDialog'],
    'T-CART-005': [_DCS + 'перезапуск: новый объект над той же БД восстанавливает черновик',
                   _FCART + 'presentation/cart_wiring_test.dart::перезапуск: копия drift сразу с «предварительно»',
                   _CS + 'после восстановления: «Корзина обновлена с сервера',
                   _PFT + 'RM-F-005 п. 2: корзина из двух строк → перезапуск приложения → черновик drift на месте'],
    'T-CART-007': [_CS + 'нехватка остатка: «Доступно 1 шт», «Уменьшить до 1»'],
    'T-CART-009': [_CS + 'F-flutter-ui-1: результат POST /orders неизвестен',
                   _CO + 'AC-UI-21-010: 422 PRICE_CHANGED → возврат в корзину',
                   _OC + 'UI-22-014: submit_failed — «1С отклонила заказ»',
                   _PFT_LOST],
    'T-CART-010': [_CO + '«Назад» на первом шаге — диалог «Прервать оформление?»'],
    'T-CART-011': [_FCART + 'golden/cart_golden_test.dart::SCR-20 корзина · '],
    'T-CART-012': [_CS + 'режим клиента: нет «Отложить», «Отложенные», скидки и клиента',
                   _CS + 'скидка сверх лимита: 422 — итоги прежние'],
    'T-CART-016': [_CS + 'устаревшая копия: «Данные от HH:MM — обновляем…»'],
    'T-CART-018': [_DCS + 'офлайн: запись cart.sync set_item (07 §11.2) → после сети отправляется один раз',
                   _CS + 'офлайн: баннер, «Создать» и «Отложить» недоступны'],
    'T-CART-021': [_CS + 'пустая корзина — EmptyState, CTA скрыты'],
    'T-CART-025': [_CS + '«Отложить заказ»: POST /cart/park с ключом', _CS + 'F8 — диалог «Отложить заказ»'],
    'T-CART-026': [_PK + 'продавец: свои карточки без «Мои / Все»', _PK + 'senior_seller: вкладка «Все»'],
    'T-CART-027': [_PK + '409 active_not_empty → диалог UI-23-010'],
    'T-CART-030': [_PK + '«Удалить»: диалог с фокусом на «Отмена»'],
    'T-CART-031': [_CS + 'смена склада: меню складов → один PATCH /cart'],
    'T-CART-032': [_DCS + 'серия изменений → один PUT mode=set с итоговым количеством; цепочка rowVersion из ответа',
                   _DCS + 'новое изменение той же строки заменяет неотправленную запись',
                   _DCS + 'очередь останавливается, строка dead, событие конфликта',
                   _FAPP + 'core/sync/outbox_queue_test.dart::сбой без ответа сервера (исключение обработчика) попыткой '
                   'не считается'],
    'T-ORD-001': [_CO + 'степпер «Клиент · Получение · Оплата · Завершение»', _CO + '4 шага: «Далее» валидирует шаг'],
    'T-ORD-002': [_CO + 'RM-F-006 п. 2: CTA недоступна без способа оплаты', _CO + 'QR_PROVIDER=none — плитки QR нет',
                  _FCHK + 'data/checkout_dtos_contract_test.dart::ключи и обязательные поля == схемы OpenAPI'],
    'T-ORD-003': [_CO + 'клиент корзины: карточка с историей и скидкой',
                  _CO + 'выбор клиента из поиска → POST /cart/customer; «+ Новый клиент» → SCR-26',
                  _CO + 'AC-UI-21-003: «+ Новый клиент» → SCR-26; созданный клиент выбран автоматически',
                  _API + 'cart/cart-customer-port.e2e.spec.ts::GET /search/customers: seller'],
    'T-ORD-005': [_CO + 'RM-F-013 п. 3: доставка требует адрес, телефон, дату и интервал',
                  _CO + 'AC-UI-21-017: восстановление шага и выборов; ПДн получателя не восстанавливаются'],
    'T-ORD-006': [_CO + 'AC-UI-21-026: «Розничный покупатель» — 422 CUSTOMER_NOT_IDENTIFIED'],
    'T-ORD-008': [_FCHK + 'presentation/checkout_acceptance_test.dart::AC-UI-21-016: чекбоксы печати сохраняются между '
                  'заказами на устройстве',
                  _FAPP + 'app/di/stage_f_wiring_test.dart::запись в settings scope=device и чтение новым экземпляром'],
    'T-ORD-014': [_FCHK + 'data/checkout_repository_test.dart::после перезапуска: GET /orders?idempotencyKey= находит',
                  _OSR + 'заказ создан до перезапуска → найден по idempotencyKey',
                  _CO + 'F-flutter-ui-1: результат POST /orders неизвестен → окно закрывается',
                  _PFT_LOST],
    'T-ORD-021': [_API + 'sales-domain/order-status.spec.ts::с полученными платежами — только запрос any со step-up и '
                  'refundIntent',
                  _API + 'sales-domain/order-status.spec.ts::согласованный (awaiting_shipment) — только any'],
    'T-ORD-022': [_OD + 'AC-UI-24-006: shipped / closed — кнопки отмены нет'],
    'T-ORD-029': [_OD + 'AC-UI-24-001: № POS, № 1С, статус с текстом и история', _OD + 'AC-UI-24-007: «Принять оплату»',
                  _OD + 'AC-UI-24-008: документы в submitting'],
    'T-ORD-030': [_OC + 'AC-UI-22-003: истёк → «Перевыпустить QR»', _OC + 'AC-UI-22-004/005: ручное подтверждение',
                  _OC + '«Требует разбора»: manual_confirm с late_payment', _OC + 'AC-UI-22-002: 202 / submitting'],
    'T-MNY-031': [_FCART + 'data/cart_dtos_contract_test.dart::пример Cart разбирается: тыйыны, milli-units'],
    'T-MNY-033': [_CS + 'итоги — только с сервера: до ответа «предварительно» и прежний итог'],
    'T-PAY-005': [_OD + 'AC-UI-24-002: частично оплачен — «Оплачено X из Y»'],
    'T-PAY-007': [_FAPP + 'core/sync/outbox_queue_test.dart::тип вне CHECK outbox_actions.type не ставится (заказы и '
                  'платежи — только онлайн'],
    'T-PAY-017': ['pos-app/integration_test/pos_flow_test.dart::RM-F-016: QR_PROVIDER=none — старший продавец: QR → '
                  'ручное подтверждение со step-up'],
    'T-PAY-025': [_CO + 'AC-UI-21-012: продавцу при просрочке — «обратитесь к старшему продавцу» без сумм'],
    'T-PAY-032': [_OC + 'F-trace-4 (RM-F-013 п. 4): SCR-22 после перезапуска',
                  _DIO + 'приём денег не повторяется автоматически даже с ключом',
                  _PFT + 'перезапуск во время ожидания QR — ожидание возобновлено, оплата отражена, POST нет'],
    'T-PAY-042': [_OC + 'AC-UI-22-012: клиент — QR не сформирован'],
    'T-NOTIF-001': [_FNOT + 'notifications_screen_test.dart::AC-UI-44-001, AC-UI-44-004: бейдж = числу непрочитанных'],
    'T-NOTIF-005': [_FNOT + 'data/notification_read_outbox_test.dart::отметка офлайн: read_at в кэше, запись outbox',
                    _FNOT + 'data/notification_read_outbox_test.dart::после «перезапуска» записи отправляются',
                    _FNOT + 'data/notification_read_outbox_test.dart::«Прочитать все» до момента'],
    'T-SYNC-042': [_OC + 'AC-UI-22-002: 202 / submitting — «Ожидает отправки в 1С»',
                   _PFT + 'RM-F-007 п. 2: 1С недоступна → заказ создан в `submitting` (202)'],
    'T-DS-015': [_FDS + 'tokens_test.dart::ds.text.*: шкала DsTypography.inter = tokens.json'],
    'T-DS-040': [_FDS + 'components_test.dart::show → true при подтверждении, false при «Отмена»; фокус на «Отмена»',
                 _PK + '«Удалить»: диалог с фокусом на «Отмена»'],
    'T-DS-046': [_FDS + 'components_test.dart::смена класса окна сохраняет состояние тела (п. 8.7)'],
    'T-DS-055': [_FCART + 'golden/cart_golden_test.dart::SCR-20 корзина · ',
                 _FCART + 'golden/cart_golden_test.dart::SCR-23 отложенные · '],
    'T-DS-082': [_FDS + 'catalog_components_test.dart::формат сом: разряды U+202F, тыйыны при ненулевой дроби',
                 _API + 'documents/pdf-renderer.spec.ts::деньги: разделитель тысяч'],
    'T-DS-085': [_CS + 'серия «+» с интервалом < 500 мс', _CS + '«−» на минимальном количестве — ConfirmDialog',
                 _OC + 'AC-UI-22-003: истёк → «Перевыпустить QR»'],
    'T-FAIL-003': [_DIO + 'POST /orders с ключом — повтор с тем же ключом (DATA-263)',
                   _DIO + 'не повторяются: 4xx бизнес, 409 VERSION_CONFLICT',
                   _OSR + '2/4/8/16 с, затем раз в 30 с'],
    'T-FAIL-004': [_DIO + 'GET 503 без problem → повтор с backoff', _DIO + 'не повторяются: 4xx бизнес',
                   _FORD + 'presentation/orders_screen_test.dart::ошибка первой загрузки — ErrorState и «Повторить»'],
    'T-FAIL-005': [_FNET + 'backend_health_test.dart::недоступный backend → ok=false без исключения',
                   _DIO + 'нет соединения → connectionFailed', _CS + 'офлайн: баннер, «Создать» и «Отложить» недоступны'],
    'T-FAIL-006': [_DIO + '426 APP_UPDATE_REQUIRED → требуется обновление (блокирующий SCR-90)'],
}

# Что из сценария ID не проверено, хотя тест есть (выводится как «частично: …»).
PARTIAL_F: dict[str, str] = {
    'T-SEC-042': 'реальное решение по долгу — этап G; на F проверен fail-closed и аудит credit.sale_blocked',
    'T-PAY-022': 'на этапе F — fail-closed (CreditDecisionService этапа G не подключён)',
    'T-SYNC-032': 'проверено на заглушке доставки (RecordingDelivery), не на FakeOnecGateway',
    'T-CART-002': 'смахивание строки (compact) — без отдельного кейса',
    'T-CART-012': 'ограничение ввода лимитом — сервером (422 DISCOUNT_LIMIT_EXCEEDED); кейса «роль без права» нет',
    'T-CART-013': 'второе устройство того же пользователя не моделировалось (корзина по owner_user_id, не по устройству)',
    'T-CART-014': 'ConfirmDialog «Очистить корзину? Будет удалено N позиций» (pos-app) — без отдельного кейса',
    'T-CART-018': 'integration_test офлайн-редактирования не выполнялся (unit над drift + widget)',
    'T-CART-022': 'отказ в UI «Слишком много позиций…» — без widget-кейса',
    'T-CART-023': '12 ждёт 400 для DELETE без packagingId; 08 §4.7.3 / ядро §19.2 — удаление всех строк варианта '
    '(реализовано по 08) — FIX-F-18',
    'T-CART-028': 'срок 7 сут — expires_at при park; сдвиг часов на 7 д + 1 мин заменён правкой expires_at',
    'T-CART-032': 'integration_test (5 действий офлайн, 10 мин без сети, FIFO по id) не выполнялся; unit — серия, '
    'сжатие, цепочка rowVersion, 409',
    'T-ORD-001': 'integration_test мастера — путь без клиента (pos_flow_test RM-F-016); с клиентом — RM-G-001',
    'T-ORD-003': 'история и долг клиента по правам на карточке — этап G (RM-G-001, RM-G-002)',
    'T-ORD-006': 'credit_allowed / лимит / просрочка с реальным снимком — этап G; на F — fail-closed',
    'T-ORD-014': 'integration: потеря ответа POST /orders → повтор тем же ключом, один заказ (pos_flow_test); поиск '
    'GET /orders?idempotencyKey= после перезапуска с неизвестным результатом — unit/widget (order_submission_recovery)',
    'T-ORD-016': 'review «счёт / продажа — отдельные сущности» не выполнялся',
    'T-ORD-019': 'проверено применение reserved/available из среза 1С (этап E); связь с согласованием — L3',
    'T-ORD-021': '(в) refundIntent=refund по HTTP — без отдельного e2e (домен decideOrderCancel); (г) — этап G',
    'T-ORD-024': 'partially_returned и «отгружено/осталось» по строкам — этап G (возвраты); integration (fixtures) — '
    'разбор документа 1С (unit)',
    'T-ORD-027': 'сумма в теле документа 1С (fixtures) — не сверялась отдельно; SCR-21 — итоги из checkout-preview',
    'T-MNY-032': 'обновление записи transactions со старым значением в аудите — не реализовано (FIX-F-21)',
    'T-DISC-005': 'подсказка «Скидка клиента 3 % уже учтена» на SCR-21 — без widget-кейса',
    'T-DISC-006': 'см. T-MNY-032: старое значение в аудите — не реализовано (FIX-F-21)',
    'T-DISC-011': 'review «автоматические скидки 1С не воспроизводятся» — по коду CheckoutPolicy',
    'T-PAY-001': 'SCR-38 (ConfirmDialog с суммой и клиентом, integration_test) — этап G (экран-заглушка на F)',
    'T-PAY-004': 'ответ 409 ORDER_STATE_INVALID reason already_paid вместо PAYMENT_STATE_INVALID — FIX-F-22',
    'T-PAY-006': 'для credit — оплата долга (PAY-040) — условно (Q-152), этап G',
    'T-PAY-007': 'integration_test «Принять оплату» офлайн — SCR-38 этапа G',
    'T-PAY-009': 'включённое округление (to_som → 16 008,00, delta в 1С) — до решения Q-016 не применяется (FIX-F-04)',
    'T-PAY-010': 'manual: печать на принтере — нет принтера',
    'T-PAY-013': 'текст «оплата будет подтверждена кассиром» — widget SCR-22 (AC-UI-22-004/005)',
    'T-PAY-018': 'фраза макета «автоматически отмечен» в pos-app — без отдельного widget-кейса',
    'T-PAY-025': 'суммы долга — этап G; на F — fail-closed без сумм',
    'T-PAY-031': 'dedupe_key каждой записи — выборочно; связь с клиентом (оплата долга) — этап G',
    'T-PAY-032': 'integration — перезапуск во время ожидания QR (SCR-22 «Проверить», 13 §3.6); приём наличных и SCR-38 '
    '«Проверить статус» — этап G (RM-G-007)',
    'T-PAY-033': 'шаги 2–4 с реальным снимком долга — этап G (RM-G-002); на F — домен decideCredit и fail-closed',
    'T-PAY-035': 'qr_bakai в каждом из четырёх статусов и integration_test SCR-38 — этап G; QR — awaiting_payment',
    'T-PRINT-001': 'задание print_jobs с ошибкой и снекбар «не удалось напечатать, повторить» — без отдельного кейса',
    'T-PRINT-008': 'review «приложение нигде не названо ККМ» не выполнялся',
    'T-NOTIF-005': 'integration_test не выполнялся (unit + widget)',
    'T-SYNC-035': 'алерт (уведомление admin) при OUTBOX_UNCONFIRMED не проверяется; ночная сверка — этап G',
    'T-SYNC-041': 'кэш результата /check ≤ 60 с (ONEC_CHECK_REUSE_MS) — без отдельного кейса; L1 на копии 1С — RM-F-010',
    'T-SYNC-042': 'SCR-25 «Отправляется в 1С» — без отдельного кейса',
    'T-SYNC-F01': '«снимки обновляются» при восстановлении 1С — без кейса',
    'T-SYNC-F02': 'регресс расширения (ONEC-094) — L3',
    'T-SYNC-F07': 'снятие пометки удаления → возврат статуса — без кейса',
    'T-SYNC-F11': '«повтор ночью» и предел 5 неудач — без отдельного кейса (backoff и sync_errors — да)',
    'T-FAIL-003': 'integration_test через прокси с задержкой (таймауты 5/15/30 с) не выполнялся; unit dio + widget',
    'T-FAIL-004': 'requestId в ErrorState — без отдельного кейса',
    'T-FAIL-005': 'integration_test без backend не выполнялся (unit + widget)',
    'T-FAIL-007': 'UI режима «только чтение» в pos-app — без widget-кейса',
    'T-FAIL-011': 'нейтральный ответ клиенту при открытом breaker — T-FAIL-010 (этап D)',
    'T-FAIL-012': 'API при недоступной БД — 500 INTERNAL (закрытый перечень 08 §2.4), 12 ждёт 503 — FIX-F-19; '
    '«воркер приостанавливает задачи» — без кейса',
    'T-DS-015': 'golden таблиц и таймеров, зачёркнутая старая цена — без отдельного кейса',
    'T-DS-040': 'сплошная проверка «все danger-кнопки — только через ConfirmDialog.destructive» не выполнялась',
    'T-DS-055': 'бейдж корзины primary / onPrimary — без отдельного golden',
    'T-DS-085': 'StepUpDialog, AppBottomSheet.side 320/400/480, неизвестный остаток — в других наборах, не сводно',
    'T-TXN-001': 'заявка на возврат (return_requested) — этап G',
    'T-TXN-011': 'старое/новое значение и request_id по всем операциям 10 §4–§13 — выборочно',
    'T-SEC-041': 'поиск «фискальный чек» в UI pos-app (review) — не выполнялся',
}


def _select_f(tid: str, group: str, num: int, auto: str) -> bool:
    if group in F_GROUPS:
        return True
    if group == 'SYNC':
        return 31 <= num <= 42 or 1001 <= num <= 1018
    if group == 'FAIL':
        return 3 <= num <= 13
    if group == 'TXN':
        return num in F_TXN
    if group == 'SEC':
        return num in F_SEC
    if group == 'UI':
        return num in F_UI
    if group == 'DS':
        return num in F_DS
    return False


# ======================================================================================== общее
@dataclass
class Stage:
    title: str
    select: Callable[[str, str, int, str], bool]
    not_done: dict[str, str]
    trace: dict[str, list[str]] = field(default_factory=dict)
    partial: dict[str, str] = field(default_factory=dict)
    ui_screens: tuple[int, ...] = ()


def _select_d(tid: str, group: str, num: int, auto: str) -> bool:
    return group in D_GROUPS or tid in D_EXTRA or (group == 'SEC' and bool(re.search(r'\bA\b', auto)))


def _select_e(tid: str, group: str, num: int, auto: str) -> bool:
    if group in ('CAT', 'INV', 'FAV'):
        return True
    if group == 'SYNC':
        return 1 <= num <= 30 or 43 <= num <= 46
    if group == 'ONEC':
        return 1 <= num <= 19
    if group == 'PERF':
        return num in (1, 2)
    if group == 'UI':
        return num in E_UI
    return tid in E_SEC


# ======================================================================================== этап G
# Этап G (13 RM-G-009 п. 1: «T-CUST/T-DEBT/T-DISC/T-TXN/T-RET/T-CASH/T-SEC из 12 запущены»; интеграция backend G):
# охват по 12 §2.15, строка «G — Cashier» — T-CUST, T-DEBT, T-TXN, T-RET, T-CASH, T-ADMIN, T-AUD (все). T-DISC
# этапом F уже охвачен (матрица --stage F), здесь — повторно (лимиты ролей, RM-G-003).
G_GROUPS = ('CUST', 'DEBT', 'DISC', 'TXN', 'RET', 'CASH', 'ADMIN', 'AUD')
_RC = 'pos-api/test/receivables/receivables-credit.e2e.spec.ts'
_CD = 'pos-api/test/customers/customers-directory.e2e.spec.ts'
_CL = 'pos-api/test/customers/customers-lifecycle.e2e.spec.ts'
_TX = 'pos-api/test/transactions/transactions.e2e.spec.ts'
_RT = 'pos-api/test/returns/returns.e2e.spec.ts'
_DS = 'pos-api/test/discounts/discounts.e2e.spec.ts'
_RB = 'pos-api/test/e2e/rbac-matrix.e2e-spec.ts'
_CF = 'pos-api/test/e2e/cashier/cashier-flow.e2e-spec.ts'
_AU = 'pos-api/test/admin/admin-users.admin-spec.ts'
_UI_G = 'UI-часть (виджет/integration_test pos-app) — у Flutter-интегратора этапа G (не в путях backend-интеграции)'
_ACG = 'AC-UI без кейса с ID в тестах pos-app (поведение частично — widget-тесты без ссылки на AC); '
# Widget-тесты pos-app этапа G (интеграция Flutter G; ревью G-trace-14): трасса UI-части backend-сценариев.
_FCS = 'pos-app/test/features/customers/presentation/customers_screens_test.dart'
_FCD = 'pos-app/test/features/cashier/presentation/cashier_dashboard_screen_test.dart'
_FNC = 'pos-app/test/features/customers/presentation/new_customer_screen_test.dart'

# Трасса «ID → тест backend» (ID в тексте теста не записан; подстрока названия теста проверяется скриптом).
TRACE_G: dict[str, list[str]] = {
    'T-DEBT-003': [f'{_RC}::детализация: без step-up → 403 STEP_UP_REQUIRED', f'{_RC}::include=documents: без step-up → 403'],
    'T-DEBT-004': [f'{_RC}::роли: seller → 403 (только флаги, Q-017)', f'{_CD}::seller не получает поле долга'],
    'T-DEBT-006': [
        f'{_RC}::устаревший снимок → isStale=true',
        'pos-api/test/receivables/credit-decision.unit.spec.ts::порог устаревания — из порта',
        f'{_FCS}::AC-UI-32-003/004: устаревший снимок — предупреждение и «Обновить»',
    ],
    'T-DEBT-007': [f'{_RC}::cashier: только просрочка > 0, по убыванию суммы'],
    'T-DEBT-008': [
        f'{_RC}::без снимка → «Нет данных из 1С»',
        f'{_RC}::клиент source=pos до 1С и «Розничный покупатель»',
        f'{_FCS}::AC-UI-34-008/009: нет снимка — «Нет данных из 1С»',
    ],
    'T-CASH-001': [
        f'{_CD}::seller по 4 цифрам телефона',
        'pos-api/scripts/local-stack.mjs::GET /search/customers: кассир — по 4 цифрам телефона',
        f'{_FCS}::AC-UI-31-001/002/011 cashier: debounce 300 мс',
        f'{_FCS}::AC-UI-31-003/004/011/012 seller: имя не ищется',
    ],
    'T-CASH-002': [
        f'{_CD}::cashier: список своих, PUT/DELETE идемпотентны',
        f'{_TX}::сверка: суммы смены = Σ журнала за день по способам; избранны',
        f'{_FCS}::AC-UI-31-007: звезда — оптимистично',
        f'{_FCD}::избранное: удаление скрывает карточку и показывает «Отменить»',
    ],
    'T-CASH-003': [f'{_CL}::строится из shipments/shipment_items', f'{_FCS}::AC-UI-33-001/004: по умолчанию 90 дней'],
    'T-CASH-004': [
        f'{_RC}::cashier: сальдо, просрочка, лимит, остаток лимита',
        f'{_FCS}::AC-UI-34-001/002: сводка без step-up',
    ],
    'T-CASH-005': [f'{_DS}::корзина применяет лимиты seed'],
    'T-CASH-007': [f'{_RB}::HTTP: каждая реализованная операция этапов D, E, F и G'],
    'T-CASH-010': [f"{_TX}::stepUp: await t.stepUp(cashier, 'payment.qr.confirm_manual')", f'{_CF}::без step-up → 403 STEP_UP_REQUIRED; со step-up → заказ в долг'],
    'T-CASH-011': [f'{_RB}::owner/admin без кассовых операций'],
    'T-CASH-012': [f'{_DS}::senior_seller со step-up: 15 %', f'{_RC}::разблокировка просрочки senior_seller'],
    'T-CASH-015': [f'{_RB}::T-SEC-019 (статически, весь контракт)'],
    'T-CUST-002': [f'{_CL}::проверка тела: телефон, ИНН, тип, длина имени', f'{_FNC}::Widget-тесты SCR-26 «Новый клиент»'],
    'T-CUST-003': [f'{_CL}::телефон существующего клиента реплики → 409 CUSTOMER_DUPLICATE_SUSPEC'],
    'T-CUST-005': [f'{_CL}::новый клиент → outbox → 1С 201 → onec_ref заполняется', f'{_CF}::кассир создаёт клиента: 201 pending → outbox customer'],
    'T-CUST-006': [f'{_CL}::1С при создании нашла дубль → outbox failed, onecStatus=duplicate'],
    'T-CUST-007': [f'{_CL}::«Всё равно создать»: seller → 403'],
    'T-CUST-008': [f'{_RC}::клиент source=pos до 1С и «Розничный покупатель»', f'{_CD}::«Розничный покупатель» и помеченные на удаление не наход'],
    'T-CUST-009': ['pos-api/test/customers/customer-links.e2e.spec.ts::телефон не попадает в жур'],
    'T-CUST-010': [f'{_CL}::фильтры source/period, курсор', f'{_TX}::фильтры: вид, группа статуса, способ, клиент'],
    'T-CUST-011': [f'{_RB}::ROUTES_OUTSIDE_CONTRACT', 'pos-api/test/e2e/smoke.e2e-spec.ts::notServedByApi'],
    'T-CUST-012': ['pos-api/test/customers/customer-links.e2e.spec.ts::L1 verified → 200 confirmed без step-up'],
    'T-CUST-014': [f'{_CF}::confirmed — своя карточка, долг и история', 'pos-api/test/customer-mode/customer-mode.e2e.spec.ts::CUST-025 / AC-API-179'],
    'T-CUST-015': ['pos-api/test/customer-mode/customer-mode.e2e.spec.ts::заявки-заказы клиентов (created_via=customer)'],
    'T-CUST-016': [f'{_CF}::Продажа в долг в режиме клиента недоступна', 'pos-api/test/customer-mode/customer-mode.e2e.spec.ts::CUST-024: QR своего заказа'],
    'T-TXN-004': [f'{_TX}::seller видит только операции по своим заказам'],
    'T-TXN-007': [f'{_RT}::refund (source=onec)'],
    'T-CASH-013': [f'{_FCD}::sync.overall=failed — баннер с сущностью, временем и числом ошибок (AC-UI-30-012)'],
    'T-CASH-016': [
        f'{_FCD}::«Ожидают оплаты»: строки со статусом заказа, тап → SCR-38 ?orderId= (AC-UI-30-007, AC-UI-30-022)',
        f'{_FCD}::«Принять оплату» → лист поиска заказа',
    ],
    'T-RET-010': [f'{_RB}::маршрутов приложения вне контракта нет (кроме перечня ROUTES_OUTSIDE_CONTRACT)'],
    'T-TXN-010': ['pos-api/test/reports/admin-reports.e2e.spec.ts::format=csv → 403 FORBIDDEN (R2)'],
    'T-RET-002': [f'{_RT}::заказ не отгружен → 409 order_not_shipped'],
    'T-RET-004': [f'{_RT}::валидация: причина обязательна, excess недопустим'],
    'T-RET-005': [f'{_RT}::201 draft: сумма строки — доля суммы реализации с учётом скидки (MNY-006)'],
    'T-RET-009': [f'{_RT}::порог return_approval_threshold'],
    'T-RET-011': [f'{_RT}::список и карточка: return.read (owner — да, seller — 403)', f"{_CF}::auditRows('return.status_changed', id)"],
    'T-RET-014': [f'{_RT}::reject: draft → 409', f'{_RT}::отклонение в POS заявки с outbox pending'],
    'T-RET-015': [f'{_RT}::accept (RETURNS_FROM_POS_ENABLED=false): права, step-up, переходы', f'{_RT}::accept при включённом outbox → 409 already_in_onec'],
    'T-ADMIN-001': [f'{_AU}::T-SEC-020: смена роли и создание приглашения без step-up', f'{_AU}::T-SESS-018, T-SEC-012: block'],
    'T-ADMIN-002': [f'{_AU}::admin: назначить owner (в т. ч. себе) → 403 owner_role_reserved'],
    'T-ADMIN-003': [f'{_DS}::PUT: без step-up → 403 STEP_UP_REQUIRED; owner/seller → 403 FORBIDDEN'],
    'T-ADMIN-004': ['pos-api/test/admin/admin-settings.admin-spec.ts::RBAC и step-up: GET — admin/owner', 'pos-api/test/admin/admin-settings-g.admin-spec.ts::owner — только просмотр'],
    'T-ADMIN-007': [f'{_AU}::T-BIO-013 (сброс администратором)'],
    'T-ADMIN-008': ['pos-api/test/settings/public-settings.e2e.spec.ts::критерий 1: все интерактивные роли и pending_activation'],
    'T-ADMIN-009': [f'{_CD}::linkStatus — только admin (очередь SCR-45)'],
    'T-SEC-067': [
        f'{_RC}::аудит customer.debt_viewed (summary)',
        'pos-app/integration_test/cashier_flow_test.dart::customer.debt_viewed по карточке клиента виден',
    ],
}

# Что из сценария не проверено автотестом backend (строка — «тест (трасса), частично: …»).
PARTIAL_G: dict[str, str] = {
    'T-CASH-007': 'скрытие пунктов меню — ' + _UI_G,
    'T-CASH-010': 'ConfirmDialog с суммой и клиентом — ' + _UI_G,
    'T-CUST-006': 'перепривязка заказов и слияние карточек при дубле 1С не реализованы (GQ-CUS-02): только onec_status=duplicate',
    'T-CUST-008': 'неизменяемость строки «Розничный покупатель»: API изменения/удаления клиента в R1 нет; DDL-проверки нет',
    'T-CUST-009': 'журнал проверяется на поиске привязки при регистрации; grep логов при создании/просмотре карточки не выполнялся',
    'T-CUST-010': 'вкладки карточки — ' + _UI_G,
    'T-CUST-014': 'навигация SCR-50 на compact/medium — ' + _UI_G,
    'T-TXN-007': 'в журнал из 1С пишутся только refund по документам возврата (return_docs); реализации и ПКО — нет: '
    'вида transaction_kind для документа 1С вне приложения нет, проекции ПКО нет — нужно решение по ТЗ '
    '(G_spec_questions FIX-G-TXN-07)',
    'T-CASH-016': 'точки входа «из деталей заказа» и «из карточки клиента» (customerId) integration_test не проверены',
    'T-RET-002': 'поиск исходной продажи в SCR-39 — ' + _UI_G,
}

NOT_DONE_G: dict[str, str] = {
    'T-DEBT-013': 'integration_test pos-app (офлайн SCR-34) — ' + _UI_G + '; backend: финансов клиента нет в офлайн-API',
    'T-CASH-009': 'widget (fakeAsync) опроса GET /pos/dashboard каждые 60 с нет: в harness pos-app опрос выключен '
    '(cashierDashboardPollProvider.overrideWithValue(null)) — у исправителя Flutter (pos-app)',
    'T-CUST-013': 'integration_test pos-app (поиск офлайн) — ' + _UI_G,
    'T-TXN-006': 'widget — ' + _UI_G,
    'T-TXN-008': 'ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА Q-330 (12: до ответа — not_done, FIX-F-21)',
    'T-TXN-009': 'widget (последние 10 операций на SCR-30) — ' + _UI_G,
    # Приёмочные наборы экранов этапа G (Flutter): набор выполнен, только если каждый AC-UI экрана назван в тесте.
    'T-UI-030': _ACG + 'HID-скан номера заказа на SCR-30 (GQ-FECASH-02), «Подробнее» → SCR-35 последнего клиента и '
    'warehouseId дашборда не сделаны',
    'T-UI-031': _ACG + 'expanded: мастер-деталь без синхронизации URL и ↑/↓ (GQ-FECUST-08), HID-скан в поиске',
    'T-UI-032': _ACG + 'Z7 привязки у cashier/senior_seller (GQ-FECUST-09), пометка удаления (GQ-FECUST-05)',
    'T-UI-033': _ACG + 'раскрытие строки без позиций заказа (GQ-FECUST-10); период — не DS DateRangePicker',
    'T-UI-034': _ACG + 'переход документа в SCR-37 по onecRef (GQ-FECUST-04), «открыта до» — оценка (GQ-FECUST-03)',
    'T-UI-035': _ACG + 'golden только для роли cashier',
    'T-UI-036': _ACG + 'колонка «Способ» — нет paymentMethod в Transaction (GQ-FECASH-08), ↑/↓ по строкам с панелью',
    'T-UI-037': _ACG + 'боковая панель 480 поверх SCR-36 на expanded (GQ-FECASH-06) — страница',
    'T-UI-038': _ACG + 'модальный 560/640 (GQ-FECASH-05), F7/Ctrl+P; режим «по долгу» выключен (RM-G-013, Q-152)',
    'T-UI-039': _ACG + 'описание операции в StepUpDialog (GQ-FERET-03), комментарий при «Согласовать» (GQ-FERET-05), '
    'Space/+/− и HID-скан строки',
    'T-UI-041': _ACG + 'версия и «Доступно обновление», таймер повторной отправки кода (GQ-FEADM-12)',
    'T-UI-042': _ACG + 'секция «Принтер» не подключена (GQ-FEADM-07)',
    'T-UI-043': _ACG + 'вкладки «Ошибки» и «Outbox» (GQ-FEADM-08)',
    'T-UI-045': _ACG + 'набор SCR-45 — этап D/E, в G меняется только навигация (AdminNavMenu)',
    'T-UI-046': _ACG + 'поля вне AdminSettingsValues 1.2.0, подписи полей — ключи API (GQ-FEADM-05)',
    'T-UI-047': _ACG + 'фильтры expanded — кнопкой «Применить», без debounce',
    'T-UI-048': _ACG + 'счётчик «Отложенные заказы» (GQ-FEADM-10), числа клиентов с долгом/просрочкой (GQ-FEADM-11)',
}


# Этап G, Flutter-интеграция (RM-G-009 п. 1, RM-G-010): T-SEC класса A по разделам этапа G (IDOR, эскалация,
# field-level долга, права маршрутов, step-up, replay финансовых POST, аудит, история, долг fail-closed, аудит сумм
# долга) и приёмочные наборы экранов SCR-30…SCR-39, SCR-41…SCR-48 (02 ч. D, ч. E).
G_SEC = (15, 16, 17, 18, 20, 23, 24, 30, 38, 41, 42, 67)
G_UI = (30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 41, 42, 43, 44, 45, 46, 47, 48)


def _select_g(tid: str, group: str, num: int, auto: str) -> bool:
    if group == 'SEC':
        return num in G_SEC
    if group == 'UI':
        return num in G_UI
    return group in G_GROUPS


STAGES: dict[str, Stage] = {
    'D': Stage('D — Authentication (RM-D-011 п. 1)', _select_d, {k: v for k, v in NOT_DONE_D.items() if v}),
    'E': Stage('E — Catalog (RM-E-012 п. 1; 12 §2.15)', _select_e, NOT_DONE_E, TRACE_E, PARTIAL_E, E_UI),
    'F': Stage('F — Cart and POS (RM-F-009; 12 §2.15)', _select_f, NOT_DONE_F, TRACE_F, PARTIAL_F, F_UI),
    'G': Stage('G — Cashier (RM-G-009 п. 1; 12 §2.15)', _select_g, NOT_DONE_G, TRACE_G, PARTIAL_G, G_UI),
}


def plan_rows(root: Path, stage: Stage) -> list[list[str]]:
    rows: list[list[str]] = []
    seen: set[str] = set()
    for line in (root / PLAN).read_text(encoding='utf8').splitlines():
        # T-SYNC-F01…F18 (этап F): номер с префиксом F → 1001…1018 (не пересекается с T-SYNC-001…).
        m = re.match(r'^\| (T-([A-Z]+)-(F?\d+)) \|', line)
        if not m or m.group(1) in seen:
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        raw = m.group(3)
        num = 1000 + int(raw[1:]) if raw.startswith('F') else int(raw)
        if stage.select(m.group(1), m.group(2), num, cells[-1]):
            rows.append(cells)
            seen.add(m.group(1))
    return rows


def test_files(root: Path) -> dict[Path, str]:
    out: dict[Path, str] = {}
    for r in TEST_ROOTS:
        for p in (root / r).rglob('*'):
            if p.suffix not in ('.ts', '.dart') or 'node_modules' in p.parts:
                continue
            if r == 'pos-api/src' and not p.name.endswith('.spec.ts'):
                continue
            if not (p.name.endswith(('_test.dart', '.spec.ts', '-spec.ts')) or 'support' in p.parts or 'bench' in p.parts):
                continue
            out[p] = p.read_text(encoding='utf8', errors='ignore')
    return out


def ui_coverage(root: Path, files: dict[Path, str], screen: int) -> tuple[int, int]:
    """(найдено AC-UI экрана в тестах pos-app, всего AC-UI экрана в 02)."""
    rx = re.compile(rf'AC-UI-{screen:02d}-\d{{3}}')
    total = set(rx.findall((root / SCREENS).read_text(encoding='utf8')))
    app = [s for p, s in files.items() if str(p.relative_to(root)).replace('\\', '/').startswith(APP_TEST_ROOTS)]
    found = {x for s in app for x in rx.findall(s)} & total
    return len(found), len(total)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='.')
    ap.add_argument('--stage', default='D', choices=sorted(STAGES))
    ap.add_argument('--summary', action='store_true')
    args = ap.parse_args()
    root = Path(args.root).resolve()
    stage = STAGES[args.stage]
    rows = plan_rows(root, stage)
    files = test_files(root)
    total = len(rows)
    tested = traced = not_done = missing = partial = 0
    by_group: dict[str, list[int]] = {}
    lines: list[str] = []
    errors: list[str] = []
    for cells in rows:
        tid, name, prio = cells[0], cells[1], cells[-2]
        group = tid.split('-')[1]
        g = by_group.setdefault(group, [0, 0, 0, 0])  # охват, тест (в т. ч. трасса), not_done, нет
        g[0] += 1
        pat = re.compile(re.escape(tid) + r'(?![\d])')
        hits = sorted(str(p.relative_to(root)).replace('\\', '/') for p, s in files.items() if pat.search(s))
        links: list[str] = []
        # T-MNY-0NN «MV-NN» (12 §3.x, 10 MNY-004): трасса — вектор MV-NN в тестах backend/Flutter (общий файл
        # contracts/test-vectors/money.v1.json исполняется обеими сторонами).
        mv = re.fullmatch(r'MV-(\d{2})', name.strip())
        if group == 'MNY' and mv:
            mvx = re.compile(rf'MV-{mv.group(1)}(?![\d])')
            for p, src in files.items():
                if mvx.search(src):
                    links.append(p.relative_to(root).as_posix() + f' «MV-{mv.group(1)}»')
            links = sorted(links)[:3]
        for ref in stage.trace.get(tid, []):
            path, _, needle = ref.partition('::')
            f = root / path
            if not f.is_file() or needle not in f.read_text(encoding='utf8', errors='ignore'):
                errors.append(f'{tid}: трасса не найдена: {ref}')
                continue
            links.append(f'{path} «{needle}»')
        note = stage.partial.get(tid) or stage.not_done.get(tid)
        ui = None
        if group == 'UI' and tid.split('-')[2].isdigit() and int(tid.split('-')[2]) in stage.ui_screens:
            ui = ui_coverage(root, files, int(tid.split('-')[2]))
            if ui[0] == ui[1]:
                # Набор полон: причина not_done (написана для неполного набора) не выводится как «частично».
                note = stage.partial.get(tid)
        if ui is not None and ui[0] < ui[1]:
            # Приёмочный набор: выполнен только при одном кейсе на каждый AC-UI экрана.
            reason = stage.not_done.get(tid)
            status = 'not_done' if reason else 'НЕТ'
            where = f'AC-UI экрана в тестах pos-app: {ui[0]}/{ui[1]}; {reason or "—"}'
            if reason:
                not_done += 1
                g[2] += 1
            else:
                missing += 1
                g[3] += 1
                errors.append(f'{tid} ({prio}) {name[:60]}')
        elif hits or links:
            status = 'тест' if hits else 'тест (трасса)'
            tested += bool(hits)
            traced += not hits
            g[1] += 1
            where = ', '.join(hits + links)
            if note:
                partial += 1
                where += f' | частично: {note}'
        elif tid in stage.not_done:
            not_done += 1
            g[2] += 1
            status = 'not_done'
            where = stage.not_done[tid]
        else:
            missing += 1
            g[3] += 1
            status = 'НЕТ'
            where = '—'
            errors.append(f'{tid} ({prio}) {name[:60]}')
        lines.append(f'{tid} | {prio} | {status} | {where}')
    if not args.summary:
        print(f'Этап {stage.title}')
        print('ID | приоритет | статус | тест (файл) / причина not_done')
        for line in lines:
            print(line)
    if args.stage == 'D':
        print(
            f'ИТОГ: ID в охвате {total}; с тестом {tested}; not_done с причиной {not_done}; '
            f'без теста и причины {missing}'
        )
    else:
        print('По группам (охват / с тестом / not_done / без теста и причины):')
        for grp, (n, t, nd, mi) in by_group.items():
            print(f'  {grp}: {n} / {t} / {nd} / {mi}')
        print(
            f'ИТОГ этапа {args.stage}: ID в охвате {total}; с тестом {tested + traced} (T-ID в тесте {tested}, '
            f'трасса {traced}; из них частично {partial}); not_done с причиной {not_done}; '
            f'без теста и причины {missing}'
        )
    for e in errors:
        print(f'ERROR: нет теста и причины: {e}', file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

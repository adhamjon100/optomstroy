/// Синтетические номера стека `pos-api/scripts/local-stack.mjs` для integration_test (только dev, не секреты).
///
/// Сверку с контрактом держит `test/integration_support/fixture_phones_test.dart`: при смене телефона в фикстуре
/// 1С или в `AUTH_FIXTURES` юнит-тест падает раньше, чем сценарий SCR-06 на живом стеке.
library;

/// Последние 9 цифр `AUTH_FIXTURES.customerLinked` = телефон карточки фикстуры 1С
/// `contracts/onec/fixtures/customers-search.200.json` (`+996700000001`; сравнение 1С — по последним 9 цифрам,
/// ONEC-044). Регистрация с этим номером даёт `customerMatch=proposed` (SCR-06).
const String kLinkedPhoneDigits = '700000001';

// ---------------------------------------------------------------------------
// Планшет магазина (P-002, ADR-115; integration_test/kiosk_flow_test.dart, 12 T-KIOSK-027, T-KIOSK-035).
// Стек `serve --cashier-fixtures` с `LOCAL_STACK_KIOSK_MODE=true`; код `kiosk_order` — тестовый `AUTH_FIXTURES.otpCode`
// только для номеров `AUTH_FIXTURES` (`AUTH_OTP_TEST_PHONES`). Национальные номера (9 цифр после «+996»).
// ---------------------------------------------------------------------------

/// `AUTH_FIXTURES.cashierCustomerLinked` = `CASHIER_SCENARIO_PHONES.debtWithinLimit` синтетики кассира: основной
/// телефон карточки 1С из полной синхронизации. Покупатель регистрируется и подтверждает привязку («Это я»), заявка с
/// планшета на этот номер — `kioskCustomerMatch=single` (заявка на карточку, видна в «Мои заказы» покупателя).
const String kKioskCardPhoneDigits = '700123456';

/// `AUTH_FIXTURES.customer`: карточки 1С нет; администратор стенда создаёт карточку POS с этим номером
/// (`POST /customers`, не из синхронизации 1С) — заявка с планшета на номер даёт `kioskCustomerMatch=ambiguous`
/// (номер карточки не подтверждён синхронизацией 1С, 10 KIOSK-014, Р-23 (а)).
const String kKioskPosCardPhoneDigits = '777000903';

/// `AUTH_FIXTURES.customerSmoke`: карточек нет — `kioskCustomerMatch=none`, «Розничный покупатель».
const String kKioskNoCardPhoneDigits = '777000905';

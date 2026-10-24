/// Синтетические номера стека `pos-api/scripts/local-stack.mjs` для integration_test (только dev, не секреты).
///
/// Сверку с контрактом держит `test/integration_support/fixture_phones_test.dart`: при смене телефона в фикстуре
/// 1С или в `AUTH_FIXTURES` юнит-тест падает раньше, чем сценарий SCR-06 на живом стеке.
library;

/// Последние 9 цифр `AUTH_FIXTURES.customerLinked` = телефон карточки фикстуры 1С
/// `contracts/onec/fixtures/customers-search.200.json` (`+996700000001`; сравнение 1С — по последним 9 цифрам,
/// ONEC-044). Регистрация с этим номером даёт `customerMatch=proposed` (SCR-06).
const String kLinkedPhoneDigits = '700000001';

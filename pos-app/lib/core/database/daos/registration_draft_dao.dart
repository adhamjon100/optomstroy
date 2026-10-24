// `registration_draft` — черновик регистрации: ТОЛЬКО состояние шагов (07 §11.2, DATA-299; ядро §18.2 п.1).
// ФИО и год рождения черновика — в flutter_secure_storage (`registration.full_name`, `registration.birth_year`),
// PIN на устройстве не хранится. Таблица — `key TEXT PK, value_json TEXT`, поэтому отсутствие ПДн обеспечивает
// белый список ключей и форм значений этого DAO (ревью C-MN-07): прочие ключи и значения отклоняются до записи.
import 'dart:convert';

import 'package:optomstroy/core/database/app_database.dart';

/// Ключ/значение вне белого списка `registration_draft`.
final class RegistrationDraftViolation implements Exception {
  const RegistrationDraftViolation(this.key, this.reason);

  /// Ключ черновика (значение в сообщение не попадает — оно может содержать ПДн).
  final String key;
  final String reason;

  @override
  String toString() => 'RegistrationDraftViolation($key): $reason';
}

/// Доступ к `registration_draft` только через белый список ключей.
final class RegistrationDraftDao {
  RegistrationDraftDao(this._db);

  final AppDatabase _db;

  /// Текущий шаг мастера регистрации (код шага SCR-06…SCR-08, например `phone`, `otp`, `profile`, `consents`).
  static const String stepKey = 'step';

  /// Отметки согласий: `{ "<код согласия>": true|false }` (коды — `consents.kind`, 11 §8).
  static const String consentsKey = 'consents';

  /// Выбранная сфера деятельности клиента — код справочника (не свободный текст).
  static const String sphereKey = 'sphere';

  /// Белый список ключей (07 §11.2: «текущий шаг, отметки согласий, выбранная сфера»).
  static const Set<String> allowedKeys = {stepKey, consentsKey, sphereKey};

  /// Код: латиница в нижнем регистре, `_`, до 40 символов — без цифр (телефон, год, код OTP не пройдут).
  static final RegExp _code = RegExp(r'^[a-z][a-z_]{0,39}$');

  /// Проверка пары ключ — значение; бросает [RegistrationDraftViolation].
  static void validate(String key, Object? value) {
    if (!allowedKeys.contains(key)) {
      throw RegistrationDraftViolation(key, 'ключ вне белого списка registration_draft');
    }
    switch (key) {
      case stepKey || sphereKey:
        if (value is! String || !_code.hasMatch(value)) {
          throw RegistrationDraftViolation(key, 'ожидается код [a-z_] до 40 символов');
        }
      case consentsKey:
        if (value is! Map<String, Object?> ||
            value.length > 20 ||
            value.entries.any((e) => !_code.hasMatch(e.key) || e.value is! bool)) {
          throw RegistrationDraftViolation(key, 'ожидается {код согласия: bool}');
        }
    }
  }

  /// Записать значение (после проверки белого списка).
  Future<void> write(String key, Object value) async {
    validate(key, value);
    await _db
        .into(_db.registrationDraft)
        .insertOnConflictUpdate(RegistrationDraftCompanion.insert(key: key, valueJson: jsonEncode(value)));
  }

  /// Прочитать значение; ключ вне белого списка — исключение.
  Future<Object?> read(String key) async {
    if (!allowedKeys.contains(key)) throw RegistrationDraftViolation(key, 'ключ вне белого списка registration_draft');
    final row = await (_db.select(_db.registrationDraft)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row == null ? null : jsonDecode(row.valueJson);
  }

  /// Очистить черновик (после `registration/complete`, при выходе, истечении `registration_token`; 07 §11.5).
  Future<void> clear() => _db.delete(_db.registrationDraft).go();
}

// Аварийный одноразовый код входа сотрудника (RM-D-016; ядро §22.13 п.2, §23 п.8; 08 §4.18.10;
// 09 SMS-035; 11 SEC-131). Код — секрет: показывается администратору ОДИН раз, не пишется в логи,
// drift, аналитику и снекбары; `toString` значения не содержит. Чистый Dart (FL-01).

/// Причина выдачи (`AdminUsersEmergencyLoginCodeRequest.reason`).
enum EmergencyCodeReason {
  smsUnavailable('sms_unavailable'),
  simLost('sim_lost'),
  other('other');

  const EmergencyCodeReason(this.value);

  final String value;
}

/// Ответ `201 {code, expiresAt, phoneMasked}` (`Cache-Control: no-store`).
final class EmergencyLoginCode {
  const EmergencyLoginCode({required this.code, required this.expiresAt, required this.phoneMasked});

  /// 6 цифр.
  final String code;
  final DateTime expiresAt;
  final String phoneMasked;

  @override
  String toString() => 'EmergencyLoginCode(***)';
}

/// Правила шага «причина» (UI-45-024; комментарий 5…200 обязателен при `other`).
abstract final class EmergencyCodeRules {
  static const int commentMin = 5;
  static const int commentMax = 200;

  static bool isValid(EmergencyCodeReason? reason, String comment) {
    if (reason == null) return false;
    final text = comment.trim();
    if (text.isEmpty) return reason != EmergencyCodeReason.other;
    return text.length >= commentMin && text.length <= commentMax;
  }
}

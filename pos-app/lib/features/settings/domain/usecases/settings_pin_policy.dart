// Предпроверка нового PIN на SCR-42 (09 §9.6; 02 SCR-42.8, AC-UI-42-003). Окончательно решает сервер
// (`VALIDATION_FAILED rule=pin_weak`); клиент лишь не отправляет заведомо слабый PIN. Значение PIN нигде
// не сохраняется и не логируется.

/// Причина отклонения нового PIN.
enum NewPinIssue {
  /// Длина не по политике роли или не только цифры.
  format,

  /// Одинаковые цифры, последовательность (по возрастанию/убыванию) или год рождения.
  weak,

  /// Повтор не совпал с первым вводом.
  mismatch,
}

abstract final class SettingsPinPolicy {
  /// Проверка первого ввода нового PIN длиной [length]; [birthYear] — из профиля (если известен).
  static NewPinIssue? check(String pin, {required int length, int? birthYear}) {
    if (pin.length != length || !RegExp(r'^\d+$').hasMatch(pin)) return NewPinIssue.format;
    if (pin.split('').toSet().length == 1) return NewPinIssue.weak;
    bool ascending = true;
    bool descending = true;
    for (int i = 1; i < pin.length; i++) {
      final int prev = pin.codeUnitAt(i - 1);
      final int cur = pin.codeUnitAt(i);
      if (cur != prev + 1) ascending = false;
      if (cur != prev - 1) descending = false;
    }
    if (ascending || descending) return NewPinIssue.weak;
    if (birthYear != null && pin.contains('$birthYear')) return NewPinIssue.weak;
    return null;
  }

  /// Проверка повтора.
  static NewPinIssue? confirm(String first, String repeat) => first == repeat ? null : NewPinIssue.mismatch;
}

// Единый presenter наименования карточки клиента 1С на клиенте (D PR-09).
//
// Сервер отдаёт наименование в двух местах: `GET /registration/customer-match` (`customer.displayNameMasked`,
// после `confirmed` — `customer.displayName`; 08 §4.2.2) и `GET /me` (`customerLink.displayNameMasked` /
// `displayName`). До `confirmed` клиенту показывается только маска (09 REG-032; полное наименование в ответе
// не приходит), после — полное наименование. Экраны SCR-06 и SCR-50 берут строку только отсюда, чтобы одно и то же
// наименование не выглядело по-разному. Форму собственности и маску строит сервер; клиент лишь нормализует
// пробелы. ПДн: значение не логируется.
abstract final class CustomerDisplayName {
  /// Строка для показа: привязка подтверждена ([confirmed]) — [displayName] (если пришло), иначе —
  /// [displayNameMasked]; пустое — `null`.
  static String? of({required bool confirmed, String? displayName, String? displayNameMasked}) {
    final String? full = _clean(displayName);
    if (confirmed && full != null) return full;
    return _clean(displayNameMasked);
  }

  static String? _clean(String? raw) {
    if (raw == null) return null;
    final String v = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return v.isEmpty ? null : v;
  }
}

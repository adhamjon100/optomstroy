// Модель формы SCR-46 (02 SCR-46.2, SCR-46.4, SCR-46.8; 08 §4.18.5–§4.18.6): каталог полей по секциям, черновики
// (строки ввода), клиентская предвалидация (окончательная — сервер), список изменений для диалога diff и сборка
// частичного `AdminSettingsValues` (`PUT /admin/settings` — только изменённые ключи) или `AdminDiscountLimits`.
// Интервалы синхронизации: в UI — минуты 2…1440 (SYNC-021), в API — секунды (`syncInterval.<entity>`, 60…86400).
// `CUSTOMER_SELF_SERVICE` в форму не входит — только чтение (ядро §19.2, AC-UI-46-011). Чистая логика без виджетов.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';

/// Секции SCR-46 (`?section=`, порядок 02 SCR-46.2).
enum AdminSettingsSection {
  discountLimits('discount_limits'),
  receivables('receivables'),
  stock('stock'),
  paymentsReturns('payments_returns'),
  carts('carts'),
  printing('printing'),
  sync('sync'),
  authSessions('auth_sessions'),
  appVersions('app_versions'),
  registration('registration'),
  textsContacts('texts_contacts');

  const AdminSettingsSection(this.value);

  final String value;

  /// Неизвестное значение — первая секция без ошибки.
  static AdminSettingsSection parse(String? v) =>
      values.where((AdminSettingsSection s) => s.value == v).firstOrNull ?? discountLimits;

  /// Префикс `action` для ссылки «История изменений» (SCR-46 → SCR-47).
  String get auditPrefix => this == discountLimits ? 'discount.' : 'settings.';
}

/// Ошибка поля (ключи 02 SCR-46.8).
enum SettingsFieldError { limit, receivables, lowStock, interval, otpTtl, idle, version, versionOrder, invalid, server }

/// Вид поля.
enum SettingsFieldKind { integer, boolean, choice, text, money, version }

/// Поле `app_settings` (имя — ключ `AdminSettingsValues` API).
final class SettingsField {
  const SettingsField({
    required this.key,
    required this.section,
    required this.kind,
    this.min,
    this.max,
    this.choices = const <String>[],
    this.error = SettingsFieldError.invalid,
    this.unit,
    this.adminOnly = false,
  });

  final String key;
  final AdminSettingsSection section;
  final SettingsFieldKind kind;
  final int? min;
  final int? max;
  final List<String> choices;
  final SettingsFieldError error;

  /// Единица в подписи (`мин`, `с`, `дн`) — код единицы, не текст.
  final String? unit;

  /// Только `admin` со step-up (RM-G-014: «Показ остатков клиенту»).
  final bool adminOnly;

  /// Значение поля в текущих настройках как строка ввода (`''` — не задано).
  String read(AdminSettingsValues v) {
    final Object? raw = switch (key) {
      'receivables.maxAgeMinutes' => v.receivablesMaxAgeMinutes,
      'lowStockThreshold' => v.lowStockThreshold,
      'cashRounding' => v.cashRounding,
      'overpayAllowed' => v.overpayAllowed,
      'returnsEnabled' => v.returnsEnabled,
      'returnApprovalThreshold' => v.returnApprovalThreshold?.toApiString(),
      'qr.enabled' => v.qrEnabled,
      'parkedCartTtlDays' => v.parkedCartTtlDays,
      'cartStaleMinutes' => v.cartStaleMinutes,
      'print.defaultPaper' => v.printDefaultPaper?.value,
      'otp.ttlSeconds' => v.otpTtlSeconds,
      'otp.maxAttempts' => v.otpMaxAttempts,
      'session.staffRefreshDays' => v.sessionStaffRefreshDays,
      'minAppVersion' => v.minAppVersion,
      'recommendedAppVersion' => v.recommendedAppVersion,
      'customerStockDisplay' => v.customerStockDisplay?.value,
      'privacyContact' => v.privacyContact,
      _ when key.startsWith(syncPrefix) => switch (v.syncIntervals[key.substring(syncPrefix.length)]) {
        final int sec => sec ~/ 60,
        null => null,
      },
      _ => null,
    };
    return raw == null ? '' : '$raw';
  }

  /// Ошибка ввода или `null`.
  SettingsFieldError? validate(String text) {
    final String t = text.trim();
    switch (kind) {
      case SettingsFieldKind.integer:
        if (t.isEmpty) return null;
        final int? n = int.tryParse(t);
        if (n == null || (min != null && n < min!) || (max != null && n > max!)) return error;
        return null;
      case SettingsFieldKind.money:
        if (t.isEmpty) return null;
        try {
          final Money m = Money.parseInput(t);
          return m.isNegative ? error : null;
        } on Object {
          return error;
        }
      case SettingsFieldKind.version:
        if (t.isEmpty) return null;
        return SettingsVersions.parse(t) == null ? SettingsFieldError.version : null;
      case SettingsFieldKind.text:
        return max != null && t.length > max! ? error : null;
      case SettingsFieldKind.boolean:
      case SettingsFieldKind.choice:
        return null;
    }
  }

  static const String syncPrefix = 'syncInterval.';
}

/// `SemVerByPlatform` (`android=1.2.0,windows=1.2.0`).
abstract final class SettingsVersions {
  static final RegExp _semver = RegExp(r'^(\d+)\.(\d+)\.(\d+)$');

  /// Платформа → [major, minor, patch]; `null` — формат нарушен.
  static Map<String, List<int>>? parse(String text) {
    final Map<String, List<int>> out = <String, List<int>>{};
    for (final String part in text.split(',')) {
      final List<String> kv = part.trim().split('=');
      if (kv.length != 2 || kv[0].trim().isEmpty) return null;
      final RegExpMatch? m = _semver.firstMatch(kv[1].trim());
      if (m == null) return null;
      out[kv[0].trim()] = <int>[int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)];
    }
    return out.isEmpty ? null : out;
  }

  static int compare(List<int> a, List<int> b) {
    for (int i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  }

  /// Рекомендуемая версия ниже минимальной хотя бы на одной платформе.
  static bool recommendedBelowMin(String min, String recommended) {
    final Map<String, List<int>>? a = parse(min);
    final Map<String, List<int>>? b = parse(recommended);
    if (a == null || b == null) return false;
    return b.entries.any((MapEntry<String, List<int>> e) => a[e.key] != null && compare(e.value, a[e.key]!) < 0);
  }

  /// Минимальная версия повышена (дополнительное подтверждение, AC-UI-46-005).
  static bool raised(String before, String after) {
    final Map<String, List<int>>? a = parse(before);
    final Map<String, List<int>>? b = parse(after);
    if (b == null) return false;
    if (a == null) return true;
    return b.entries.any((MapEntry<String, List<int>> e) => a[e.key] == null || compare(e.value, a[e.key]!) > 0);
  }
}

/// Каталог полей SCR-46.
abstract final class AdminSettingsCatalog {
  /// Сущности обмена (`sync_entity`, порядок важности 02 SCR-43.2).
  static const List<String> syncEntities = <String>[
    'stock',
    'prices',
    'order_status',
    'products',
    'variants',
    'categories',
    'barcodes',
    'units',
    'warehouses',
    'customers',
    'receivables',
    'discounts',
    'sales_history',
    'payment_docs',
    'return_docs',
    'attributes',
    'images',
  ];

  static final List<SettingsField> fields = <SettingsField>[
    const SettingsField(
      key: 'receivables.maxAgeMinutes',
      section: AdminSettingsSection.receivables,
      kind: SettingsFieldKind.integer,
      min: 5,
      max: 1440,
      error: SettingsFieldError.receivables,
      unit: 'min',
    ),
    const SettingsField(
      key: 'lowStockThreshold',
      section: AdminSettingsSection.stock,
      kind: SettingsFieldKind.integer,
      min: 0,
      error: SettingsFieldError.lowStock,
    ),
    const SettingsField(
      key: 'cashRounding',
      section: AdminSettingsSection.paymentsReturns,
      kind: SettingsFieldKind.choice,
      choices: <String>['none', 'to_som'],
    ),
    const SettingsField(
      key: 'overpayAllowed',
      section: AdminSettingsSection.paymentsReturns,
      kind: SettingsFieldKind.boolean,
    ),
    const SettingsField(
      key: 'qr.enabled',
      section: AdminSettingsSection.paymentsReturns,
      kind: SettingsFieldKind.boolean,
    ),
    const SettingsField(
      key: 'returnsEnabled',
      section: AdminSettingsSection.paymentsReturns,
      kind: SettingsFieldKind.boolean,
    ),
    const SettingsField(
      key: 'returnApprovalThreshold',
      section: AdminSettingsSection.paymentsReturns,
      kind: SettingsFieldKind.money,
    ),
    const SettingsField(
      key: 'parkedCartTtlDays',
      section: AdminSettingsSection.carts,
      kind: SettingsFieldKind.integer,
      min: 1,
      max: 30,
      unit: 'd',
    ),
    const SettingsField(
      key: 'cartStaleMinutes',
      section: AdminSettingsSection.carts,
      kind: SettingsFieldKind.integer,
      min: 0,
      unit: 'min',
    ),
    SettingsField(
      key: 'print.defaultPaper',
      section: AdminSettingsSection.printing,
      kind: SettingsFieldKind.choice,
      choices: <String>[for (final PrintPaper p in PrintPaper.values) p.value],
    ),
    for (final String e in syncEntities)
      SettingsField(
        key: '${SettingsField.syncPrefix}$e',
        section: AdminSettingsSection.sync,
        kind: SettingsFieldKind.integer,
        min: 2,
        max: 1440,
        error: SettingsFieldError.interval,
        unit: 'min',
      ),
    const SettingsField(
      key: 'otp.ttlSeconds',
      section: AdminSettingsSection.authSessions,
      kind: SettingsFieldKind.integer,
      min: 180,
      max: 600,
      error: SettingsFieldError.otpTtl,
      unit: 's',
    ),
    const SettingsField(
      key: 'otp.maxAttempts',
      section: AdminSettingsSection.authSessions,
      kind: SettingsFieldKind.integer,
      min: 1,
      max: 10,
    ),
    const SettingsField(
      key: 'session.staffRefreshDays',
      section: AdminSettingsSection.authSessions,
      kind: SettingsFieldKind.integer,
      min: 1,
      max: 30,
      unit: 'd',
    ),
    const SettingsField(
      key: 'minAppVersion',
      section: AdminSettingsSection.appVersions,
      kind: SettingsFieldKind.version,
    ),
    const SettingsField(
      key: 'recommendedAppVersion',
      section: AdminSettingsSection.appVersions,
      kind: SettingsFieldKind.version,
    ),
    SettingsField(
      key: 'customerStockDisplay',
      section: AdminSettingsSection.registration,
      kind: SettingsFieldKind.choice,
      choices: <String>[for (final CustomerStockDisplay d in CustomerStockDisplay.values) d.value],
      adminOnly: true,
    ),
    const SettingsField(
      key: 'privacyContact',
      section: AdminSettingsSection.textsContacts,
      kind: SettingsFieldKind.text,
      max: 200,
    ),
  ];

  static List<SettingsField> of(AdminSettingsSection s) =>
      fields.where((SettingsField f) => f.section == s).toList(growable: false);

  static SettingsField? byKey(String key) => fields.where((SettingsField f) => f.key == key).firstOrNull;
}

/// Изменение для диалога diff («ключ: было → стало»).
final class SettingsChange {
  const SettingsChange({required this.key, required this.before, required this.after});

  final String key;
  final String before;
  final String after;
}

/// Ключи черновика лимитов: `limit.<role>`, `override.<role>`.
abstract final class LimitsDraft {
  static String limitKey(RoleCode r) => 'limit.${r.value}';
  static String overrideKey(RoleCode r) => 'override.${r.value}';

  /// «7,5» для 750 сотых.
  static String format(Percent p) {
    final int h = p.hundredths;
    final int frac = h % 100;
    if (frac == 0) return '${h ~/ 100}';
    final String f = frac % 10 == 0 ? '${frac ~/ 10}' : frac.toString().padLeft(2, '0');
    return '${h ~/ 100},$f';
  }

  /// Значение лимита из ввода: 0…100, шаг 0,5 (`null` — ошибка).
  static Percent? parse(String text) {
    try {
      final Percent p = Percent.fromString(text);
      return p.hundredths % 50 == 0 ? p : null;
    } on Object {
      return null;
    }
  }

  /// Строки черновика лимитов из ответа сервера.
  static Map<String, String> initial(AdminDiscountLimits l) => <String, String>{
    for (final RoleCode r in discountLimitRoles) ...<String, String>{
      limitKey(r): format(l.limits[r] ?? Percent.zero),
      overrideKey(r): '${l.overrideRoles.contains(r)}',
    },
  };

  /// Предупреждение SEC-034: лимит подтверждающей роли ниже лимита подтверждаемой (любой роли без права подтверждения).
  static bool overrideWarning(Map<String, String> values) {
    final List<(Percent, bool)> rows = <(Percent, bool)>[
      for (final RoleCode r in discountLimitRoles)
        (parse(values[limitKey(r)] ?? '') ?? Percent.zero, values[overrideKey(r)] == 'true'),
    ];
    for (final (Percent approver, bool can) in rows) {
      if (!can) continue;
      for (final (Percent other, bool otherCan) in rows) {
        if (!otherCan && other.hundredths > approver.hundredths) return true;
      }
    }
    return false;
  }

  /// Лимиты из черновика (`null` — есть ошибка ввода).
  static AdminDiscountLimits? build(AdminDiscountLimits base, Map<String, String> values) {
    final Map<RoleCode, Percent> limits = <RoleCode, Percent>{};
    for (final RoleCode r in discountLimitRoles) {
      final Percent? p = parse(values[limitKey(r)] ?? '');
      if (p == null) return null;
      limits[r] = p;
    }
    return AdminDiscountLimits(
      limits: limits,
      overrideRoles: <RoleCode>[
        for (final RoleCode r in discountLimitRoles)
          if (values[overrideKey(r)] == 'true') r,
      ],
      rowVersion: base.rowVersion,
      updatedAt: base.updatedAt,
      updatedBy: base.updatedBy,
    );
  }
}

/// Сборка частичного `AdminSettingsValues` из изменённых полей.
abstract final class SettingsValuesBuilder {
  static int? _int(Map<String, String> c, String k) => c.containsKey(k) ? int.tryParse(c[k]!.trim()) : null;

  static bool? _bool(Map<String, String> c, String k) => c.containsKey(k) ? c[k] == 'true' : null;

  static String? _str(Map<String, String> c, String k) {
    if (!c.containsKey(k)) return null;
    final String t = c[k]!.trim();
    return t.isEmpty ? null : t;
  }

  /// [changes] — ключ поля → новая строка ввода (только изменённые и валидные поля).
  static AdminSettingsValues build(Map<String, String> changes) {
    final String? threshold = _str(changes, 'returnApprovalThreshold');
    final String? paper = _str(changes, 'print.defaultPaper');
    final String? stock = _str(changes, 'customerStockDisplay');
    return AdminSettingsValues(
      receivablesMaxAgeMinutes: _int(changes, 'receivables.maxAgeMinutes'),
      lowStockThreshold: _int(changes, 'lowStockThreshold'),
      cashRounding: _str(changes, 'cashRounding'),
      overpayAllowed: _bool(changes, 'overpayAllowed'),
      qrEnabled: _bool(changes, 'qr.enabled'),
      returnsEnabled: _bool(changes, 'returnsEnabled'),
      returnApprovalThreshold: threshold == null ? null : Money.parseInput(threshold),
      parkedCartTtlDays: _int(changes, 'parkedCartTtlDays'),
      cartStaleMinutes: _int(changes, 'cartStaleMinutes'),
      printDefaultPaper: paper == null ? null : PrintPaper.values.where((PrintPaper p) => p.value == paper).firstOrNull,
      syncIntervals: <String, int>{
        for (final MapEntry<String, String> e in changes.entries)
          if (e.key.startsWith(SettingsField.syncPrefix) && int.tryParse(e.value.trim()) != null)
            e.key.substring(SettingsField.syncPrefix.length): int.parse(e.value.trim()) * 60,
      },
      otpTtlSeconds: _int(changes, 'otp.ttlSeconds'),
      otpMaxAttempts: _int(changes, 'otp.maxAttempts'),
      sessionStaffRefreshDays: _int(changes, 'session.staffRefreshDays'),
      minAppVersion: _str(changes, 'minAppVersion'),
      recommendedAppVersion: _str(changes, 'recommendedAppVersion'),
      customerStockDisplay: stock == null
          ? null
          : CustomerStockDisplay.values.where((CustomerStockDisplay d) => d.value == stock).firstOrNull,
      privacyContact: _str(changes, 'privacyContact'),
    );
  }
}

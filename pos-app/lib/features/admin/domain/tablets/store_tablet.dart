// Планшеты магазина SCR-54 (02 ч. F SCR-54; 08 §3.17 `StoreTablet`, `KioskTokens`, §4.18.11–§4.18.15; 10 KIOSK-002…
// KIOSK-004, KIOSK-007, KIOSK-024, KIOSK-031, KIOSK-032; 11 №77, №78, SEC-140; ADR-115 п. 20, п. 24, п. 26; P-002 §8.2,
// §8.11). Запись планшета без ПДн покупателей, хэша аварийного кода и `device_key`; ответ подключения — токены
// технического пользователя `kind=kiosk` и аварийный код выхода (показывается один раз, нигде не хранится).
// Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';

/// Права SCR-54 (11 §4.3 №77, №78) и операция step-up подключения, подключения заново и отключения (08 §4.18.11).
abstract final class KioskAdminOperations {
  /// `kiosk.manage` — `StepUpOperation` (область `admin_users`, 11 §4.1 п. 7).
  static const String manage = 'kiosk.manage';
}

/// Запись планшета магазина (`StoreTablet`, 08 §3.17).
final class StoreTablet {
  const StoreTablet({
    required this.id,
    required this.name,
    required this.warehouseId,
    required this.status,
    required this.enrolledAt,
    this.reconnectedAt,
    this.revokedAt,
    this.lastSeenAt,
    this.lockTaskEnabled,
    this.appVersion,
    this.expiresAt,
  });

  /// `store_tablets.id`.
  final String id;

  /// Имя планшета (`user_profiles.full_name` технического пользователя; не ПДн).
  final String name;

  /// Склад планшета (`user_profiles.home_warehouse_id`; ADR-115 п. 24 — тот же, что у кассы).
  final String warehouseId;
  final StoreTabletStatus status;
  final DateTime enrolledAt;
  final DateTime? reconnectedAt;
  final DateTime? revokedAt;

  /// Последняя связь (`null` — запросов ещё не было).
  final DateTime? lastSeenAt;

  /// Закрепление по `X-Kiosk-Lock`: `true` — включено; `false` и `null` (сигнала ещё не было) — «Закрепление не
  /// включено» (ADR-115 п. 26; 12 T-KIOSK-068).
  final bool? lockTaskEnabled;

  /// Версия приложения планшета (`X-App-Version`, например `1.4.2+87`).
  final String? appVersion;

  /// Абсолютный срок действующей сессии планшета (`null` — сессии нет).
  final DateTime? expiresAt;

  /// Напоминание о подключении заново — за 30 дней до [expiresAt] и меньше (Р-22 (а); 02 UI-54-010).
  static const Duration reconnectReminder = Duration(days: 30);

  /// Длина имени (08 §4.18.11, `name` 2…150).
  static const int nameMin = 2;
  static const int nameMax = 150;

  bool get isActive => status == StoreTabletStatus.active;

  /// «Закрепление включено» — только `true`.
  bool get lockOn => lockTaskEnabled == true;

  /// До конца подключения осталось 30 дней и меньше (в том числе срок уже прошёл).
  bool expiresSoon(DateTime nowUtc) {
    final DateTime? at = expiresAt;
    return at != null && at.toUtc().difference(nowUtc.toUtc()) <= reconnectReminder;
  }

  /// Версия планшета ниже рекомендуемой для Android (`recommendedAppVersion` `GET /settings/public`; P-002 §8.11 п. 1).
  bool updateNeeded(String? recommendedByPlatform) => KioskAppVersion.isBelow(appVersion, recommendedByPlatform);

  /// Имя без лишних пробелов — правило длины 2…150.
  static bool validName(String name) {
    final int n = name.trim().length;
    return n >= nameMin && n <= nameMax;
  }

  @override
  bool operator ==(Object other) =>
      other is StoreTablet &&
      other.id == id &&
      other.name == name &&
      other.warehouseId == warehouseId &&
      other.status == status &&
      other.enrolledAt == enrolledAt &&
      other.reconnectedAt == reconnectedAt &&
      other.revokedAt == revokedAt &&
      other.lastSeenAt == lastSeenAt &&
      other.lockTaskEnabled == lockTaskEnabled &&
      other.appVersion == appVersion &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    warehouseId,
    status,
    enrolledAt,
    reconnectedAt,
    revokedAt,
    lastSeenAt,
    lockTaskEnabled,
    appVersion,
    expiresAt,
  );

  @override
  String toString() => 'StoreTablet($id, ${status.value})';
}

/// Ответ подключения и подключения заново (`KioskTokens`, 08 §3.17): токены планшета и аварийный код выхода.
/// Код показывается администратору один раз (11 SEC-140); в журналы, адрес, буфер обмена и хранилища не попадает —
/// на устройстве сохраняется только его хэш (`SessionController.becomeKiosk`).
final class KioskEnrollment {
  const KioskEnrollment({
    required this.tablet,
    required this.accessToken,
    required this.refreshToken,
    required this.exitCode,
    this.sessionId,
  });

  final StoreTablet tablet;
  final String accessToken;
  final String refreshToken;

  /// 8 цифр CSPRNG.
  final String exitCode;
  final String? sessionId;

  /// Формат аварийного кода (`^\d{8}$`).
  static final RegExp exitCodePattern = RegExp(r'^\d{8}$');

  /// Код для показа: группы по 4 цифры («1234 5678», 02 UI-54-014).
  static String grouped(String code) {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < code.length; i++) {
      if (i > 0 && i % 4 == 0) out.write(' ');
      out.write(code[i]);
    }
    return out.toString();
  }

  @override
  String toString() => 'KioskEnrollment(${tablet.id}, ***)';
}

/// Склад для формы планшета (`CatalogWarehouse`, 08 §4.4.6).
final class TabletWarehouse {
  const TabletWarehouse({required this.id, required this.name, this.isActive = true, this.isDefaultForPos = false});

  final String id;
  final String name;
  final bool isActive;
  final bool isDefaultForPos;

  @override
  String toString() => 'TabletWarehouse($id)';
}

/// Склад по умолчанию при подключении (02 UI-54-012, SCR-54.9, AC-UI-54-004; ADR-115 п. 24): активный склад с
/// `isDefaultForPos=true` из `GET /catalog/warehouses`, иначе первый активный; склад кассы выбирает администратор.
String? defaultTabletWarehouse(List<TabletWarehouse> warehouses) {
  final List<TabletWarehouse> active = warehouses.where((TabletWarehouse w) => w.isActive).toList();
  return (active.where((TabletWarehouse w) => w.isDefaultForPos).firstOrNull ?? active.firstOrNull)?.id;
}

/// Сравнение версии планшета с рекомендуемой (`SemVerByPlatform`: `android=1.2.0,windows=1.2.0`).
abstract final class KioskAppVersion {
  static final RegExp _semver = RegExp(r'^(\d+)\.(\d+)\.(\d+)');

  /// `[major, minor, patch]` из `1.4.2+87` / `1.4.2`; `null` — не версия.
  static List<int>? parse(String? version) {
    final RegExpMatch? m = version == null ? null : _semver.firstMatch(version.trim());
    if (m == null) return null;
    return <int>[int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)];
  }

  /// Значение платформы [platform] из `SemVerByPlatform` (или строка без платформ — как есть).
  static String? forPlatform(String? byPlatform, {String platform = 'android'}) {
    if (byPlatform == null || byPlatform.trim().isEmpty) return null;
    if (!byPlatform.contains('=')) return byPlatform.trim();
    for (final String part in byPlatform.split(',')) {
      final List<String> kv = part.trim().split('=');
      if (kv.length == 2 && kv[0].trim() == platform) return kv[1].trim();
    }
    return null;
  }

  /// [appVersion] ниже рекомендуемой версии Android; неизвестные значения — `false` (без предупреждения).
  static bool isBelow(String? appVersion, String? recommendedByPlatform) {
    final List<int>? have = parse(appVersion);
    final List<int>? want = parse(forPlatform(recommendedByPlatform));
    if (have == null || want == null) return false;
    for (int i = 0; i < 3; i++) {
      if (have[i] != want[i]) return have[i] < want[i];
    }
    return false;
  }
}

// DTO `Me` — `GET /me` (08 §4.3; OpenAPI components.schemas.Me и вложенные Profile,
// MeCustomerLink, Settings, Consent). Источник правды клиента о ролях и правах;
// `permissions[]` — для скрытия кнопок, не защита (SRC-C-133).
// Содержит ПДн (ФИО, телефон) — только в памяти, toString без значений (NFR-LOG-001).
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:optomstroy/core/enums.dart';

part 'me.freezed.dart';
part 'me.g.dart';

@Freezed(toStringOverride: false)
abstract class Me with _$Me {
  const factory Me({
    required String id,
    required String kind,
    required String status,
    required List<String> roles,
    required List<String> permissions,
    required int permissionsVersion,

    /// `Me.tablet` (OpenAPI 1.3.0) — только `kind=kiosk`: планшет магазина вызывающего технического пользователя
    /// (08 §3.14; ADR-115). У `staff` и `customer` поля нет.
    MeKioskTablet? tablet,
    String? discountLimitPercent,
    MeProfile? profile,
    MeCustomerLink? customerLink,
    UserSettings? settings,
    MeSecurity? security,
    List<Consent>? consents,
    MeSession? session,
    MeAppVersion? appVersion,
    String? apiVersion,
    DateTime? serverTime,
  }) = _Me;

  const Me._();

  factory Me.fromJson(Map<String, dynamic> json) => _$MeFromJson(json);

  UserKind? get userKind => UserKind.tryParse(kind);
  UserStatus? get userStatus => UserStatus.tryParse(status);

  /// Известные роли; неизвестные значения отбрасываются (совместимость вперёд).
  List<RoleCode> get roleCodes => [for (final r in roles) ?RoleCode.tryParse(r)];

  bool can(String permission) => permissions.contains(permission);

  @override
  String toString() => 'Me(id: $id, kind: $kind, roles: $roles)';
}

/// `MeKioskTablet` (08 §3.14; ADR-115): планшет магазина технического пользователя `kind=kiosk`.
@Freezed(toStringOverride: false)
abstract class MeKioskTablet with _$MeKioskTablet {
  const factory MeKioskTablet({required String id, required String name, required String warehouseId}) = _MeKioskTablet;

  const MeKioskTablet._();

  factory MeKioskTablet.fromJson(Map<String, dynamic> json) => _$MeKioskTabletFromJson(json);

  @override
  String toString() => 'MeKioskTablet(id: $id)';
}

/// `Profile`.
@Freezed(toStringOverride: false)
abstract class MeProfile with _$MeProfile {
  const factory MeProfile({
    String? fullName,
    String? phone,
    int? birthYear,
    String? activitySphere,
    String? avatarUrl,
    int? rowVersion,
  }) = _MeProfile;

  const MeProfile._();

  factory MeProfile.fromJson(Map<String, dynamic> json) => _$MeProfileFromJson(json);

  @override
  String toString() => 'MeProfile(***)';
}

/// `MeCustomerLink` (09 REG-032).
@Freezed(toStringOverride: false)
abstract class MeCustomerLink with _$MeCustomerLink {
  const factory MeCustomerLink({
    required String status,
    String? linkId,
    String? displayNameMasked,
    String? customerId,
    String? displayName,
  }) = _MeCustomerLink;

  const MeCustomerLink._();

  factory MeCustomerLink.fromJson(Map<String, dynamic> json) => _$MeCustomerLinkFromJson(json);

  @override
  String toString() => 'MeCustomerLink($status)';
}

/// `Settings` — настройки интерфейса пользователя (PUT /me/settings).
@freezed
abstract class UserSettings with _$UserSettings {
  const factory UserSettings({
    String? locale,
    ScannerSettings? scanner,
    bool? scanAddsToCart,
    PrinterSettings? printer,
    String? catalogView,
    String? defaultWarehouseId,
    int? idleLockMinutes,
    int? rowVersion,
  }) = _UserSettings;

  factory UserSettings.fromJson(Map<String, dynamic> json) => _$UserSettingsFromJson(json);
}

/// `MeSettingsScanner` / `Settings.scanner`.
@freezed
abstract class ScannerSettings with _$ScannerSettings {
  const factory ScannerSettings({String? mode, String? suffix}) = _ScannerSettings;

  factory ScannerSettings.fromJson(Map<String, dynamic> json) => _$ScannerSettingsFromJson(json);
}

/// `MeSettingsPrinter` / `Settings.printer`.
@freezed
abstract class PrinterSettings with _$PrinterSettings {
  const factory PrinterSettings({String? defaultFormat, bool? autoPrint}) = _PrinterSettings;

  factory PrinterSettings.fromJson(Map<String, dynamic> json) => _$PrinterSettingsFromJson(json);
}

/// `Me.security` (08 §4.3.1; OpenAPI 1.4.0 — вход по лицу, 15 ADR-116). У `kind=kiosk` объекта нет (08 §3.14).
@freezed
abstract class MeSecurity with _$MeSecurity {
  const factory MeSecurity({
    bool? pinSet,
    bool? biometricsEnabled,

    /// Строкой контракта: `android_class3 | ios | windows_hello_gate | none | android_class2 | windows_hello_key`
    /// (`android_class2` — живая семья уровня W этого устройства, `windows_hello_key` — живой ключ Windows Hello W2;
    /// 08 §4.3.1). Неизвестное значение не ломает разбор (08 §2.11).
    String? biometricsPlatform,

    /// Уровень W Android («лицо или отпечаток», Class 2) разрешён этому пользователю на этом устройстве:
    /// `AUTH_BIO_ALLOW_WEAK` × вид пользователя × `platform=android` (09 BIO-030; 08 §4.3.1). Нет поля — `false`.
    bool? biometricWeakAllowed,

    /// Вход по ключу Windows Hello без PIN приложения (W2) разрешён на этом устройстве: `AUTH_WINDOWS_HELLO_KEY`
    /// и правило `personal` (09 BIO-038; 08 §4.3.1). `false` — SCR-42 предлагает только гейт W1. Нет поля — `false`.
    bool? windowsHelloKeyAllowed,
  }) = _MeSecurity;

  factory MeSecurity.fromJson(Map<String, dynamic> json) => _$MeSecurityFromJson(json);
}

/// `Consent`.
@freezed
abstract class Consent with _$Consent {
  const factory Consent({
    required String kind,
    required String version,
    required bool granted,
    DateTime? grantedAt,
    DateTime? revokedAt,
  }) = _Consent;

  factory Consent.fromJson(Map<String, dynamic> json) => _$ConsentFromJson(json);
}

/// `Me.session`.
@freezed
abstract class MeSession with _$MeSession {
  const factory MeSession({
    String? sid,
    String? deviceId,
    String? deviceName,
    DateTime? createdAt,
    List<String>? amr,
    DateTime? expiresAt,
  }) = _MeSession;

  factory MeSession.fromJson(Map<String, dynamic> json) => _$MeSessionFromJson(json);
}

/// `Me.appVersion` — дублирует `X-Min-App-Version` / `X-Recommended-App-Version` (08 §2.11).
@freezed
abstract class MeAppVersion with _$MeAppVersion {
  const factory MeAppVersion({String? min, String? recommended}) = _MeAppVersion;

  factory MeAppVersion.fromJson(Map<String, dynamic> json) => _$MeAppVersionFromJson(json);
}

// Сущности SCR-42 «Настройки» (02 ч. E; 08 §4.1.6, §4.3.4–§4.3.7; 09 §8.4, §9.5–§9.6; D-13, D-48).
// Чистый Dart: без фреймворков (FL-01). ПДн (имя устройства, IP) — только память, toString без значений.
import 'package:optomstroy/core/enums.dart';

/// Секции SCR-42 (`?section=`, 02 SCR-42.6).
enum SettingsSection {
  language('language'),
  security('security'),
  sessions('sessions'),
  scanner('scanner'),
  printer('printer'),
  display('display'),
  about('about');

  const SettingsSection(this.value);

  /// Значение query `section`.
  final String value;

  static SettingsSection? tryParse(String? value) {
    for (final SettingsSection s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// Сессия пользователя на устройстве (`Session`, 08 §4.1.6).
final class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.deviceId,
    required this.isCurrent,
    this.deviceName,
    this.platform,
    this.appVersion,
    this.kind,
    this.createdAt,
    this.lastUsedAt,
    this.ipMasked,
  });

  final String id;
  final String deviceId;
  final bool isCurrent;

  /// Имя устройства (до 60 символов).
  final String? deviceName;
  final DevicePlatform? platform;
  final String? appVersion;
  final SessionKind? kind;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;

  /// Маскированный IP (`212.***.***.12`) — как пришёл с сервера.
  final String? ipMasked;

  DeviceSession copyWith({String? deviceName}) => DeviceSession(
    id: id,
    deviceId: deviceId,
    isCurrent: isCurrent,
    deviceName: deviceName ?? this.deviceName,
    platform: platform,
    appVersion: appVersion,
    kind: kind,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt,
    ipMasked: ipMasked,
  );

  @override
  bool operator ==(Object other) =>
      other is DeviceSession &&
      other.id == id &&
      other.deviceId == deviceId &&
      other.isCurrent == isCurrent &&
      other.deviceName == deviceName &&
      other.platform == platform &&
      other.appVersion == appVersion &&
      other.kind == kind &&
      other.createdAt == createdAt &&
      other.lastUsedAt == lastUsedAt &&
      other.ipMasked == ipMasked;

  @override
  int get hashCode =>
      Object.hash(id, deviceId, isCurrent, deviceName, platform, appVersion, kind, createdAt, lastUsedAt, ipMasked);

  @override
  String toString() => 'DeviceSession($id, current: $isCurrent)';
}

/// Правило имени устройства (UI-42-016; 08 §4.1.6): 1…60 символов без управляющих.
abstract final class DeviceNameRule {
  static const int maxLength = 60;

  static final RegExp _control = RegExp(r'[\u0000-\u001F\u007F]');

  /// Нормализованное имя или `null`, если правило нарушено.
  static String? normalize(String raw) {
    final String v = raw.trim();
    if (v.isEmpty || v.length > maxLength || _control.hasMatch(v)) return null;
    return v;
  }
}

/// Вид биометрического входа на устройстве (UI-42-010).
enum BiometricSupport {
  /// Android Class 3 / iOS: вход с криптопривязкой `biometric_refresh` (09 §9.4).
  cryptoLogin,

  /// Windows Hello — только UX-гейт перед PIN, без секретов (D-13, D-48).
  windowsHelloGate,

  /// Датчик есть, биометрия в ОС не настроена — «Настроить в системе».
  notEnrolled,

  /// Нет оборудования / API < 30 / слабая биометрия / платформа вне R1.
  unavailable,
}

/// Платформа подписи тумблера (`settings_bio_android` / `_ios` / `_windows`).
enum BiometricPlatformLabel { android, ios, windows }

/// Состояние «Защиты входа» (UI-42-009…UI-42-026).
final class LoginProtectionState {
  const LoginProtectionState({
    required this.userKind,
    required this.pinSet,
    required this.biometricsEnabled,
    required this.support,
    required this.platformLabel,
    this.idleLockMinutes,
    this.birthYear,
    this.settingsAsOf,
    this.scannerMode,
    this.scanAddsToCart,
    this.printerFormat,
    this.printerAutoPrint,
  });

  final UserKind? userKind;

  /// `Me.security.pinSet`.
  final bool pinSet;

  /// Биометрия включена на этом устройстве (локальный признак `auth.biometrics_enabled`).
  final bool biometricsEnabled;
  final BiometricSupport support;
  final BiometricPlatformLabel platformLabel;

  /// `Settings.idleLockMinutes` (staff; 09 §8.8).
  final int? idleLockMinutes;

  /// Год рождения (только для проверки «год рождения в PIN»; ПДн — в toString нет).
  final int? birthYear;

  /// Серверные настройки взяты из кэша `/me` от этого момента (обновление не удалось) — `settings_stale_caption`.
  final DateTime? settingsAsOf;

  /// `Settings.scanner.mode` (`hid` | `camera`; UI-42-011) — серверная настройка пользователя.
  final String? scannerMode;

  /// `Settings.scanAddsToCart` (UI-42-019; ядро §19.4); `null` — сервер не прислал (умолчание по роли).
  final bool? scanAddsToCart;

  /// `Settings.printer.defaultFormat` (`80mm` | `a4`; UI-42-020); `null` — сервер не прислал.
  final String? printerFormat;

  /// `Settings.printer.autoPrint` (UI-42-022, PRINT-009); `null` — сервер не прислал.
  final bool? printerAutoPrint;

  bool get isStaff => userKind != UserKind.customer;

  /// Длина PIN по политике роли (09 §9.6): staff — 6, customer — 4.
  int get pinLength => isStaff ? 6 : 4;

  LoginProtectionState copyWith({
    bool? pinSet,
    bool? biometricsEnabled,
    int? idleLockMinutes,
    bool clearIdleLock = false,
    String? scannerMode,
    bool? scanAddsToCart,
  }) => LoginProtectionState(
    userKind: userKind,
    pinSet: pinSet ?? this.pinSet,
    biometricsEnabled: biometricsEnabled ?? this.biometricsEnabled,
    support: support,
    platformLabel: platformLabel,
    idleLockMinutes: clearIdleLock ? null : (idleLockMinutes ?? this.idleLockMinutes),
    birthYear: birthYear,
    settingsAsOf: settingsAsOf,
    scannerMode: scannerMode ?? this.scannerMode,
    scanAddsToCart: scanAddsToCart ?? this.scanAddsToCart,
    printerFormat: printerFormat,
    printerAutoPrint: printerAutoPrint,
  );

  @override
  bool operator ==(Object other) =>
      other is LoginProtectionState &&
      other.userKind == userKind &&
      other.pinSet == pinSet &&
      other.biometricsEnabled == biometricsEnabled &&
      other.support == support &&
      other.platformLabel == platformLabel &&
      other.idleLockMinutes == idleLockMinutes &&
      other.birthYear == birthYear &&
      other.settingsAsOf == settingsAsOf &&
      other.scannerMode == scannerMode &&
      other.scanAddsToCart == scanAddsToCart &&
      other.printerFormat == printerFormat &&
      other.printerAutoPrint == printerAutoPrint;

  @override
  int get hashCode => Object.hash(
    userKind,
    pinSet,
    biometricsEnabled,
    support,
    platformLabel,
    idleLockMinutes,
    birthYear,
    settingsAsOf,
  );

  @override
  String toString() =>
      'LoginProtectionState(${userKind?.value}, pinSet: $pinSet, bio: $biometricsEnabled, ${support.name})';
}

/// Итог включения биометрии (09 §9.5; 02 SCR-42.4 UI-42-010).
enum BiometricToggleOutcome {
  /// Включено (Android/iOS — токен зашифрован ключом; Windows — UX-гейт).
  enabled,

  /// Выключено.
  disabled,

  /// Системный диалог отменён — `settings_bio_cancelled`, тумблер «выкл».
  cancelled,

  /// StepUpDialog отменён.
  stepUpCancelled,

  /// `CONSENT_REQUIRED` — лист согласия снова.
  consentRequired,

  /// Нет сети.
  offline,

  /// Прочая ошибка (ОС / сервер) — `settings_save_error`.
  failed,
}

/// Тексты системного диалога биометрии (из ARB экрана).
final class BiometricPromptCopy {
  const BiometricPromptCopy({required this.title, required this.cancel, this.subtitle});

  final String title;
  final String? subtitle;
  final String cancel;
}

/// Значения автоблокировки (UI-42-023): 5/10/15/30 мин; для staff ≤ 30 (09 §8.8).
abstract final class IdleLockOptions {
  static const List<int> minutes = <int>[5, 10, 15, 30];

  /// По умолчанию (`SESSION_IDLE_LOCK_MINUTES`, ядро §17.7).
  static const int defaultMinutes = 30;
}

/// Плотность (UI-42-006; `DsDensity`).
enum DisplayDensity { auto, standard, compact }

/// Размер текста (UI-42-025; Q-218): множитель поверх системного, clamp — у приложения.
enum TextScaleOption {
  system(1),
  large(1.15),
  xlarge(1.3);

  const TextScaleOption(this.factor);

  final double factor; // money-double: allow — масштаб текста
}

/// Локальные настройки отображения устройства (drift `settings(scope=device)`, 07 §11.2).
final class DisplayPreferences {
  const DisplayPreferences({
    this.density = DisplayDensity.auto,
    this.textScale = TextScaleOption.system,
    this.reduceMotion = false,
  });

  static const DisplayPreferences defaults = DisplayPreferences();

  final DisplayDensity density;
  final TextScaleOption textScale;
  final bool reduceMotion;

  DisplayPreferences copyWith({DisplayDensity? density, TextScaleOption? textScale, bool? reduceMotion}) =>
      DisplayPreferences(
        density: density ?? this.density,
        textScale: textScale ?? this.textScale,
        reduceMotion: reduceMotion ?? this.reduceMotion,
      );

  @override
  bool operator ==(Object other) =>
      other is DisplayPreferences &&
      other.density == density &&
      other.textScale == textScale &&
      other.reduceMotion == reduceMotion;

  @override
  int get hashCode => Object.hash(density, textScale, reduceMotion);

  @override
  String toString() => 'DisplayPreferences(${density.name}, ${textScale.name}, reduceMotion: $reduceMotion)';
}

/// «О приложении» (UI-42-008; D-46, ядро §18.2 п.12).
final class AppAboutInfo {
  const AppAboutInfo({
    required this.appVersion,
    this.platform,
    this.deviceIdSuffix,
    this.minVersion,
    this.recommendedVersion,
  });

  /// `1.4.2+87`.
  final String appVersion;
  final DevicePlatform? platform;

  /// Последние 8 символов идентификатора устройства.
  final String? deviceIdSuffix;

  /// Из последних заголовков `X-Min-App-Version` / `X-Recommended-App-Version` (платформа клиента).
  final String? minVersion;
  final String? recommendedVersion;

  @override
  bool operator ==(Object other) =>
      other is AppAboutInfo &&
      other.appVersion == appVersion &&
      other.platform == platform &&
      other.deviceIdSuffix == deviceIdSuffix &&
      other.minVersion == minVersion &&
      other.recommendedVersion == recommendedVersion;

  @override
  int get hashCode => Object.hash(appVersion, platform, deviceIdSuffix, minVersion, recommendedVersion);

  @override
  String toString() => 'AppAboutInfo($appVersion, ${platform?.value})';
}

/// Кто открыл SCR-42 (видимость секций и правил по ролям, 02 SCR-42.10).
final class SettingsViewer {
  const SettingsViewer({this.kind, this.primaryRole});

  final UserKind? kind;
  final RoleCode? primaryRole;

  /// `customer`: без секций «Сканер» и «Принтер», без автоблокировки; PIN — 4 цифры.
  bool get isCustomer => kind == UserKind.customer || primaryRole == RoleCode.customer;

  bool get isStaff => !isCustomer;

  @override
  bool operator ==(Object other) => other is SettingsViewer && other.kind == kind && other.primaryRole == primaryRole;

  @override
  int get hashCode => Object.hash(kind, primaryRole);

  @override
  String toString() => 'SettingsViewer(${kind?.value}, ${primaryRole?.value})';
}

// Порт закрепления планшета магазина (P-002 §8.10; 06 §6.2 «Размещение режима «Планшет магазина»» п. (3), (8), §6.10
// «Привязки корня в режиме «Планшет магазина»»; 16 §10.10 «Ограничения на планшете»; ADR-115 п. 26, п. 29; 13 TAB-2-09).
//
// Android — приложение — владелец устройства (Device Owner; `adb shell dpm set-device-owner
// com.example.optomstroy/.KioskDeviceAdminReceiver`, 16 §10.10 шаг 4) + режим `lock task` + приложение «Домой»:
// [ChannelKioskLock], канал `kg.optomstroy/kiosk_lock` (`MainActivity` → `KioskLockChannel.kt`). Windows и веб —
// [NoKioskLock]: закрепления в приложении нет (Windows — Assigned Access вне приложения), SCR-54 показывает
// «Закрепление не включено» (AC-UI-54-012).
//
// Протокол канала — словари, без исключений:
//   status                → снимок
//   enable  {политика}    → снимок после включения (`error: not_device_owner` — приложение не владелец устройства)
//   disable               → снимок после снятия (снимаются все известные каналу ограничения, Device Owner остаётся;
//                           без Device Owner снимать нечего — не ошибка)
// Снимок: {supported, deviceOwner, lockTaskActive, homeApp, activeRestrictions, unsupportedRestrictions,
//          rejectedRestrictions, lockTaskFeatures (null — API < 28), error?}.
// Политика — одна константа [kioskLockPolicy]: набор выбирает Dart, канал применяет переданный (только ключи из своего
// `KNOWN_RESTRICTIONS`), поэтому набор проверяется тестом (test/core/hardware/kiosk_lock_test.dart).
//
// Состояние «Закрепление включено» (заголовок `X-Kiosk-Lock: on`, ADR-115 п. 26) — [KioskLockStatus.isLocked]: Device
// Owner, `lock task`, приложение «Домой», ВЕСЬ набор ограничений политики (в том числе `no_autofill`) и функции
// `lock task` без уведомлений — по чтению состояния на самом устройстве. Так SCR-54 показывает и состояние ограничений,
// когда отладка по USB на планшете уже запрещена и `adb shell dumpsys device_policy` недоступен (решение WP-A03 по
// открытому вопросу 2 WP-D-CUST). Персональных данных порт не касается.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final Logger _log = Logger('hardware.kiosk_lock');

/// Набор ограничений владельца устройства, который включает [KioskLock.enable] и снимает [KioskLock.disable].
@immutable
final class KioskLockPolicy {
  const KioskLockPolicy({
    required this.userRestrictions,
    required this.lockTaskFeatures,
    required this.statusBarDisabled,
    required this.keyguardDisabled,
  });

  /// Ключи `UserManager.DISALLOW_*` (значения констант Android).
  final List<String> userRestrictions;

  /// Разрешённые функции `lock task` (`DevicePolicyManager.setLockTaskFeatures`, API 28+): `system_info`,
  /// `notifications`, `home`, `overview`, `global_actions`, `keyguard`. Пустой список — `LOCK_TASK_FEATURE_NONE`.
  final List<String> lockTaskFeatures;

  /// `DevicePolicyManager.setStatusBarDisabled` — шторка не открывается.
  final bool statusBarDisabled;

  /// `DevicePolicyManager.setKeyguardDisabled` — без экрана блокировки Android (вход в зал — сразу витрина SCR-51).
  final bool keyguardDisabled;

  /// Аргументы метода `enable` канала.
  Map<String, Object?> toChannelArguments() => <String, Object?>{
    'userRestrictions': List<String>.of(userRestrictions),
    'lockTaskFeatures': List<String>.of(lockTaskFeatures),
    'statusBarDisabled': statusBarDisabled,
    'keyguardDisabled': keyguardDisabled,
  };
}

/// Ограничения планшета магазина — перечень 16 §10.10 «Ограничения на планшете» (P-002 §8.10; ADR-115 п. 29).
const KioskLockPolicy kioskLockPolicy = KioskLockPolicy(
  userRestrictions: <String>[
    // UserManager.DISALLOW_SAFE_BOOT — нет безопасного режима.
    'no_safe_boot',
    // UserManager.DISALLOW_FACTORY_RESET — нет сброса из настроек (сброс из меню восстановления остаётся: 16 §15.7, §15.8).
    'no_factory_reset',
    // UserManager.DISALLOW_DEBUGGING_FEATURES — нет отладки по USB.
    'no_debugging_features',
    // UserManager.DISALLOW_INSTALL_APPS — нет установки приложений (обновление — после «Отключить», 16 §10.10).
    'no_install_apps',
    // UserManager.DISALLOW_AUTOFILL — нет службы автозаполнения (ADR-115 п. 29; 11 PRIV-033).
    'no_autofill',
  ],
  // LOCK_TASK_FEATURE_NONE: без уведомлений и системной строки, без «Домой», «Недавних», меню питания и экрана блокировки.
  lockTaskFeatures: <String>[],
  statusBarDisabled: true,
  keyguardDisabled: true,
);

/// Ошибка команды канала.
enum KioskLockError {
  /// Приложение не владелец устройства: закрепление не включается (закрепление экрана с PIN — только по отдельному
  /// решению заказчика, 16 §10.10).
  notDeviceOwner,

  /// Команда не выполнена (исключение Android); снимок показывает, что успело примениться.
  failed,
}

/// Состояние закрепления на устройстве.
@immutable
final class KioskLockStatus {
  const KioskLockStatus({
    this.supported = false,
    this.deviceOwner = false,
    this.lockTaskActive = false,
    this.homeApp = false,
    this.activeRestrictions = const <String>{},
    this.unsupportedRestrictions = const <String>{},
    this.rejectedRestrictions = const <String>{},
    this.lockTaskFeatures,
    this.error,
  });

  /// Снимок канала (`status`, `enable`, `disable`).
  factory KioskLockStatus.fromChannel(Map<String, Object?> raw) => KioskLockStatus(
    supported: raw['supported'] == true,
    deviceOwner: raw['deviceOwner'] == true,
    lockTaskActive: raw['lockTaskActive'] == true,
    homeApp: raw['homeApp'] == true,
    activeRestrictions: _strings(raw['activeRestrictions']),
    unsupportedRestrictions: _strings(raw['unsupportedRestrictions']),
    rejectedRestrictions: _strings(raw['rejectedRestrictions']),
    lockTaskFeatures: raw['lockTaskFeatures'] == null ? null : _strings(raw['lockTaskFeatures']),
    error: switch (raw['error']) {
      null => null,
      'not_device_owner' => KioskLockError.notDeviceOwner,
      _ => KioskLockError.failed,
    },
  );

  /// Закрепления нет: Windows, веб, тесты, канал не зарегистрирован.
  static const KioskLockStatus unsupported = KioskLockStatus();

  /// Платформа с закреплением в приложении (Android).
  final bool supported;

  /// Приложение — владелец устройства.
  final bool deviceOwner;

  /// Режим `lock task` включён (`ActivityManager.LOCK_TASK_MODE_LOCKED`; закрепление экрана с PIN — не он).
  final bool lockTaskActive;

  /// Приложение назначено «Домой» (activity-alias `KioskHomeAlias` включён).
  final bool homeApp;

  /// Действующие ограничения из известных каналу.
  final Set<String> activeRestrictions;

  /// Ограничения, которых нет в версии Android устройства (например, `no_autofill` до API 26 — службы нет вовсе).
  final Set<String> unsupportedRestrictions;

  /// Ключи политики, которых канал не знает и не применил.
  final Set<String> rejectedRestrictions;

  /// Разрешённые функции `lock task`; `null` — API < 28 (функций нет, шторку закрывает `setStatusBarDisabled`).
  final Set<String>? lockTaskFeatures;

  /// Ошибка последней команды.
  final KioskLockError? error;

  /// Ограничения [policy], которые на устройстве не действуют.
  Set<String> missingRestrictions([KioskLockPolicy policy = kioskLockPolicy]) => <String>{
    for (final String key in policy.userRestrictions)
      if (!activeRestrictions.contains(key) && !unsupportedRestrictions.contains(key)) key,
  };

  /// Функции `lock task` совпадают с [policy] (на API < 28 — не применимо).
  bool lockTaskFeaturesMatch([KioskLockPolicy policy = kioskLockPolicy]) {
    final Set<String>? features = lockTaskFeatures;
    return features == null || setEquals(features, policy.lockTaskFeatures.toSet());
  }

  /// Закрепление по [policy] включено полностью.
  bool isLockedBy(KioskLockPolicy policy) =>
      supported &&
      deviceOwner &&
      lockTaskActive &&
      homeApp &&
      missingRestrictions(policy).isEmpty &&
      lockTaskFeaturesMatch(policy);

  /// «Закрепление включено» (02 SCR-54 UI-54-008): Device Owner, `lock task`, «Домой» и весь [kioskLockPolicy].
  bool get isLocked => isLockedBy(kioskLockPolicy);

  /// Значение заголовка `X-Kiosk-Lock` (08 §2.3; ADR-115 п. 26): `on` — [isLocked], иначе `off`.
  String get headerValue => isLocked ? 'on' : 'off';

  @override
  bool operator ==(Object other) =>
      other is KioskLockStatus &&
      other.supported == supported &&
      other.deviceOwner == deviceOwner &&
      other.lockTaskActive == lockTaskActive &&
      other.homeApp == homeApp &&
      setEquals(other.activeRestrictions, activeRestrictions) &&
      setEquals(other.unsupportedRestrictions, unsupportedRestrictions) &&
      setEquals(other.rejectedRestrictions, rejectedRestrictions) &&
      setEquals(other.lockTaskFeatures, lockTaskFeatures) &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    supported,
    deviceOwner,
    lockTaskActive,
    homeApp,
    Object.hashAllUnordered(activeRestrictions),
    Object.hashAllUnordered(unsupportedRestrictions),
    Object.hashAllUnordered(rejectedRestrictions),
    lockTaskFeatures == null ? null : Object.hashAllUnordered(lockTaskFeatures!),
    error,
  );

  @override
  String toString() =>
      'KioskLockStatus(supported: $supported, deviceOwner: $deviceOwner, lockTask: $lockTaskActive, home: $homeApp, '
      'restrictions: ${activeRestrictions.length}, missing: ${missingRestrictions().length}, '
      'features: ${lockTaskFeatures?.length}, error: ${error?.name})';

  static Set<String> _strings(Object? raw) => raw is List
      ? <String>{
          for (final Object? e in raw)
            if (e is String) e,
        }
      : const <String>{};
}

/// Закрепление планшета магазина: включает подключение и подключение заново (SCR-54, FLOW-043), снимают отзыв
/// (`401 KIOSK_REVOKED`) и аварийный выход (P-002 §8.2 п. 6, §8.9). Ошибки — в [KioskLockStatus.error], без исключений.
abstract interface class KioskLock {
  /// Текущее состояние на устройстве.
  Future<KioskLockStatus> status();

  /// Включить Device Owner-закрепление по [kioskLockPolicy]; без Device Owner — без действия
  /// ([KioskLockError.notDeviceOwner]).
  Future<KioskLockStatus> enable();

  /// Снять `lock task`, «Домой» и все ограничения; Device Owner остаётся (обновление и подключение заново, 16 §10.10).
  Future<KioskLockStatus> disable();
}

/// Без закрепления в приложении (Windows, веб, тесты): команды без действия, состояние — «не включено».
final class NoKioskLock implements KioskLock {
  const NoKioskLock();

  @override
  Future<KioskLockStatus> status() async => KioskLockStatus.unsupported;

  @override
  Future<KioskLockStatus> enable() async => KioskLockStatus.unsupported;

  @override
  Future<KioskLockStatus> disable() async => KioskLockStatus.unsupported;
}

/// Android: канал `kg.optomstroy/kiosk_lock` (`KioskLockChannel.kt`). На других платформах — как [NoKioskLock].
final class ChannelKioskLock implements KioskLock {
  ChannelKioskLock({
    MethodChannel? channel,
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
    this.policy = kioskLockPolicy,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _platform = platform ?? defaultTargetPlatform,
       _isWeb = isWeb;

  /// Имя канала — то же в `KioskLockChannel.kt`.
  static const String channelName = 'kg.optomstroy/kiosk_lock';

  /// Политика, которую передаёт `enable`.
  final KioskLockPolicy policy;

  final MethodChannel _channel;
  final TargetPlatform _platform;
  final bool _isWeb;

  @override
  Future<KioskLockStatus> status() => _invoke('status');

  @override
  Future<KioskLockStatus> enable() => _invoke('enable', policy.toChannelArguments());

  @override
  Future<KioskLockStatus> disable() => _invoke('disable');

  Future<KioskLockStatus> _invoke(String method, [Map<String, Object?>? arguments]) async {
    if (_isWeb || _platform != TargetPlatform.android) return KioskLockStatus.unsupported;
    try {
      final Map<String, Object?>? raw = await _channel.invokeMapMethod<String, Object?>(method, arguments);
      if (raw == null) return const KioskLockStatus(supported: true, error: KioskLockError.failed);
      final KioskLockStatus status = KioskLockStatus.fromChannel(raw);
      if (status.error != null) _log.warning('kiosk_lock.$method: ${status.error!.name}');
      return status;
    } on PlatformException catch (e) {
      _log.warning('kiosk_lock.$method: ${e.code}');
      return const KioskLockStatus(supported: true, error: KioskLockError.failed);
    } on MissingPluginException {
      _log.warning('kiosk_lock.$method: канал не зарегистрирован');
      return KioskLockStatus.unsupported;
    }
  }
}

/// Реализация порта для [platform]: Android — [ChannelKioskLock], Windows, iOS и веб — [NoKioskLock].
KioskLock kioskLockFor(TargetPlatform platform, {bool isWeb = kIsWeb}) =>
    !isWeb && platform == TargetPlatform.android ? ChannelKioskLock(platform: platform) : const NoKioskLock();

/// Порт закрепления (06 §6.10): по умолчанию — [NoKioskLock]; корень (`app/di/overrides.dart`) подставляет
/// [kioskLockFor] платформы. Презентация фичи kiosk получает его через `features/kiosk/kiosk_providers.dart` (FL-02),
/// core (сессия, интерсептор `X-Kiosk-Lock`) — отсюда.
final kioskLockProvider = Provider<KioskLock>((ref) => const NoKioskLock());

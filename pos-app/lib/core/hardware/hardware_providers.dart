// Провайдеры сканеров (core/hardware; RM-E-010). Шаблон этапа D: обычные Provider/Notifier без
// кодогенерации. Фичи (presentation) получают их через `features/scan/scan_providers.dart` (FL-02).
//
// HID: `scannerWedgeServiceProvider` — один сервис на приложение; подключает его к клавиатуре
// оболочка (`HidScanScope` из features/scan или `service.attach()` в `app/router/shells`).
// Камера: `barcodeCameraFactoryProvider` (в widget-тестах — фейк), `cameraScannerSupportedProvider`.
import 'dart:async';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/hardware/barcode_camera.dart';
import 'package:optomstroy/core/hardware/scanner_settings_store.dart';
import 'package:optomstroy/core/hardware/scanner_wedge_config.dart';
import 'package:optomstroy/core/hardware/scanner_wedge_service.dart';

final Logger _log = Logger('hardware.scanner');

/// Хранилище настроек сканера: drift `settings` (scope `device`) после входа, до входа — память.
final scannerSettingsStoreProvider = Provider<ScannerSettingsStore>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db == null ? MemoryScannerSettingsStore() : DriftScannerSettingsStore(db);
});

/// Текущие настройки HID-сканера (суффикс, порог между символами).
final scannerConfigProvider = NotifierProvider<ScannerConfigController, ScannerWedgeConfig>(
  ScannerConfigController.new,
);

/// Настройки HID-сканера: чтение из хранилища и изменение из SCR-42.
class ScannerConfigController extends Notifier<ScannerWedgeConfig> {
  bool _changed = false;

  ScannerSettingsStore? _store;

  @override
  ScannerWedgeConfig build() {
    _changed = false;
    final ScannerSettingsStore store = ref.watch(scannerSettingsStoreProvider);
    _store = store;
    unawaited(_load(store));
    return const ScannerWedgeConfig();
  }

  Future<void> _load(ScannerSettingsStore store) async {
    final ScannerWedgeConfig loaded;
    try {
      loaded = await store.load();
    } on Object catch (e) {
      // R1-N-01: чтение запущено без ожидания (`unawaited`), а БД пользователя закрывается при смене пользователя
      // и при выходе (`appDatabaseProvider` → `db.close()`). Запрос к закрытой БД бросал асинхронную ошибку вне
      // зоны теста/приложения (tearDownAll integration_test). Остаются значения по умолчанию.
      _log.fine('настройки сканера не прочитаны: ${e.runtimeType}');
      return;
    }
    // Пользователь успел изменить настройку до окончания чтения — его выбор важнее; хранилище сменилось
    // (другой пользователь) — результат относится к прежней БД.
    if (!_changed && ref.mounted && identical(_store, store)) state = loaded;
  }

  /// Окончание скана (UI-42-018). Серверную копию `Settings.scanner.suffix` сохраняет SCR-42.
  Future<void> setSuffix(ScannerSuffix suffix) => _apply(state.copyWith(suffix: suffix));

  /// Порог между символами (мс из [ScannerWedgeConfig.allowedThresholdsMs]).
  Future<void> setInterKeyThresholdMs(int ms) {
    if (!ScannerWedgeConfig.allowedThresholdsMs.contains(ms)) return Future<void>.value();
    return _apply(state.copyWith(interKeyThreshold: Duration(milliseconds: ms)));
  }

  Future<void> _apply(ScannerWedgeConfig next) async {
    _changed = true;
    state = next;
    try {
      await ref.read(scannerSettingsStoreProvider).save(next);
    } on Object catch (e) {
      // БД закрыта (выход во время сохранения) — значение действует до конца процесса.
      _log.fine('настройки сканера не сохранены: ${e.runtimeType}');
    }
  }
}

/// Сервис HID-сканера (один на приложение). Настройки применяются без пересоздания.
final scannerWedgeServiceProvider = Provider<ScannerWedgeService>((ref) {
  final service = ScannerWedgeService(config: ref.read(scannerConfigProvider));
  ref
    ..listen<ScannerWedgeConfig>(scannerConfigProvider, (_, next) => service.config = next)
    ..onDispose(service.dispose);
  return service;
});

/// Фабрика камеры-сканера (SCR-17).
final barcodeCameraFactoryProvider = Provider<BarcodeCameraFactory>(
  (ref) =>
      ({required bool includeQr}) => MobileScannerBarcodeCamera(includeQr: includeQr),
);

/// Камера-сканер доступна на платформе (Android/iOS).
final cameraScannerSupportedProvider = Provider<bool>((ref) => cameraScannerSupportedOn(defaultTargetPlatform));

/// Открыть системные настройки приложения («Открыть настройки», UI-17-009; EQ-SCAN-07): пакет `app_settings`
/// на Android/iOS. `false` — не удалось (Windows и прочие платформы, нет плагина): экран повторяет запуск камеры.
final appSettingsLauncherProvider = Provider<Future<bool> Function()>(
  (ref) =>
      () => openOsAppSettings(defaultTargetPlatform),
);

/// Открывает настройки приложения в ОС на [platform]; `true` — экран настроек открыт.
Future<bool> openOsAppSettings(TargetPlatform platform) async {
  if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) return false;
  try {
    await AppSettings.openAppSettings();
    return true;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

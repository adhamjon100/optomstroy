// Публичный контракт фичи scan (06 §6.1 L-3 (2), §6.14; FL-07): провайдеры портов и сервисов
// сканеров для экранов (SCR-17, HID в каталоге, секция «Сканер» SCR-42).
//
// presentation не импортирует core/hardware напрямую (FL-02): нужные типы сервиса и камеры
// реэкспортируются отсюда. Порты, которые подключает композиционный корень `app/di/overrides.dart`:
//  * `scanBarcodeLookupProvider` — адаптер к `searchRepositoryProvider` каталога (README фичи);
//  * `scanCartPortProvider` — добавление в корзину (этап F; без него `mode=add` работает как `search`);
//  * `scanAddsToCartProvider` — настройка `scan_adds_to_cart` (`Settings.scanAddsToCart`, ядро §19.4).
// В widget-тестах — `ProviderScope(overrides: [scanBarcodeLookupProvider.overrideWithValue(fake), …])`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';

export 'package:optomstroy/core/hardware/barcode_camera.dart'
    show
        BarcodeCamera,
        BarcodeCameraFactory,
        BarcodeCameraState,
        CameraBarcodeFormat,
        CameraDetection,
        CameraStatus,
        CameraTorch;
export 'package:optomstroy/core/hardware/barcode_value.dart' show BarcodeValue;
export 'package:optomstroy/core/hardware/hardware_providers.dart'
    show
        ScannerConfigController,
        appSettingsLauncherProvider,
        barcodeCameraFactoryProvider,
        cameraScannerSupportedProvider,
        scannerConfigProvider,
        scannerWedgeServiceProvider;
export 'package:optomstroy/core/hardware/scanner_wedge_config.dart' show ScannerSuffix, ScannerWedgeConfig;
export 'package:optomstroy/core/hardware/scanner_wedge_service.dart'
    show
        HidCaptureMode,
        HidScanEvent,
        HidScanIgnored,
        HidScanIncomplete,
        HidScanRegistration,
        HidScanRejected,
        HidScanned,
        ScannerWedgeService;

Never _unbound(String name) => throw UnimplementedError('$name: подключите адаптер в app/di/overrides.dart');

/// Поиск по штрихкоду (адаптер `SearchRepository.barcode`/`barcodeCached` каталога).
final scanBarcodeLookupProvider = Provider<ScanBarcodeLookup>((ref) => _unbound('scanBarcodeLookupProvider'));

/// Сценарий «штрихкод → товар» (сервер, офлайн — кэш).
final lookupScannedBarcodeProvider = Provider<LookupScannedBarcode>(
  (ref) => LookupScannedBarcode(ref.watch(scanBarcodeLookupProvider)),
);

/// Корзина для «сразу в корзину»; `null` — не подключена (или роль без добавления: `owner`, `customer`).
final scanCartPortProvider = Provider<ScanCartPort?>((ref) => null);

/// Настройка «Сразу добавлять в корзину» для HID-скана в каталоге (UI-42-019; по умолчанию `cashier` —
/// вкл., `seller` — выкл.). Значение подставляет корень из `Settings.scanAddsToCart` пользователя.
final scanAddsToCartProvider = Provider<bool>((ref) => false);

/// Режим «Серия» камеры (UI-17-007; по умолчанию выкл., Q-207). Хранится на время сессии приложения
/// (ключ `scan_series_mode` в 07 §11.2 не закреплён — EQ-SCAN-05).
final scanSeriesModeProvider = NotifierProvider<ScanSeriesModeController, bool>(ScanSeriesModeController.new);

/// Переключатель «Серия».
class ScanSeriesModeController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Включает/выключает серию.
  void set(bool value) => state = value;
}

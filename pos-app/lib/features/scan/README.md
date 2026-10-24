# features/scan

Экраны: SCR-17 `/scan?mode=search|add|order|test` (камера, Android/iOS; HID-сканер — `core/hardware`).
Задача: RM-E-010 (13 §3.5). Экран: `presentation/screens/scan_screen.dart` → `ScanScreen`.

## Состав

| Файл | Назначение |
|---|---|
| `core/hardware/hid_wedge_detector.dart` | Чистый автомат: символы с интервалом < порога (50 мс) + окончание Enter/Tab → скан; ручной ввод; обрыв без окончания (300 мс); «Без суффикса» — пауза 150 мс |
| `core/hardware/scanner_wedge_service.dart` | `ScannerWedgeService`: обработчик `HardwareKeyboard` + ранний обработчик `FocusManager`; правило 02 п. 2.2.11 (`HidCaptureMode`); события `HidScanned` / `HidScanRejected` / `HidScanIgnored` / `HidScanIncomplete`; `registerScanTarget(FocusNode)`, `suspend()` |
| `core/hardware/barcode_camera.dart` | Порт `BarcodeCamera` + `MobileScannerBarcodeCamera` (`mobile_scanner` 7.4.2) |
| `core/hardware/scanner_wedge_config.dart`, `scanner_settings_store.dart`, `barcode_value.dart` | Настройки (суффикс, порог), хранение в drift `settings` (scope `device`), формат кода 3…64 `[0-9A-Za-z-]` |
| `core/hardware/hardware_providers.dart` | `scannerWedgeServiceProvider`, `scannerConfigProvider`, `barcodeCameraFactoryProvider`, `cameraScannerSupportedProvider`, `appSettingsLauncherProvider` |
| `scan_providers.dart` | Публичный контракт фичи: реэкспорт типов core/hardware для presentation (FL-02), порты `scanBarcodeLookupProvider`, `scanCartPortProvider`, `scanAddsToCartProvider`, `scanSeriesModeProvider` |
| `domain/scan_lookup.dart` | `ScanMode`, `ScanLookupResult`, `LookupScannedBarcode` (сервер → 404 → офлайн-кэш), результаты `pop`: `ScannedCode`, `ScannedProduct`; порт корзины `ScanCartPort` |
| `domain/camera_code_filter.dart` | 2 кадра подряд, подавление повтора 1,5 с |
| `presentation/hid_scan_scope.dart` | `HidScanScope` — HID «без экрана» в каталоге (обернуть контент оболочки staff/customer) |
| `presentation/scanner_settings_section.dart` | `ScannerSettingsSection` — раздел «Сканер» для SCR-42 |

## Подключение (сделано в композиционном корне, интеграция этапа E)

1. **Поиск по штрихкоду.** Ребра `scan → catalog` в DAG 06 §6.1 нет (EQ-FEF-07, EQ-SCAN-03), поэтому адаптер
   `CatalogScanBarcodeLookup` живёт в `lib/app/di/scan_catalog_adapter.dart` (тест
   `test/features/scan/catalog_scan_adapter_test.dart`) и подключён в `appOverrides`:
   `scanBarcodeLookupProvider` ← `searchRepositoryProvider` каталога (кэш → сеть).
2. **HID в оболочке.** `AppShell` (`app/router/shells/app_shell.dart`) оборачивает ветки `StatefulShellRoute`
   в `HidScanScope`; для режима `customer` область выключена (`enabled: false`). Экраны входа SCR-01…08 — вне
   оболочки. Экраны с особым поведением (SCR-25, SCR-38, SCR-11) передают `onEvent` или подписываются на
   `ref.read(scannerWedgeServiceProvider).events`; нампад SCR-16 и финансовые формы — `service.suspend()`.
3. **Настройки.** `scanAddsToCartProvider` — пока умолчание по роли (`cashier` — вкл., прочие — выкл.;
   `scanAddsToCartByDefault` в `app/di/overrides.dart`); серверная `Settings.scanAddsToCart` подключается вместе
   с портом корзины (этап F). `ScannerSettingsSection` встроен в SCR-42 (`settingsScannerSectionProvider`),
   окончание скана сохраняется `PUT /me/settings {scanner.suffix}`.
4. **Корзина** (этап F): `scanCartPortProvider` ← адаптер корзины; без него `mode=add` работает как `search`.
5. **iOS:** `NSCameraUsageDescription` добавлен в `ios/Runner/Info.plist` (сборка iOS не проверялась).
   Android: разрешение `CAMERA` объявляет плагин `mobile_scanner`. «Открыть настройки» (UI-17-009) —
   пакет `app_settings` (Android/iOS; на Windows — `false`, экран повторяет запуск камеры).

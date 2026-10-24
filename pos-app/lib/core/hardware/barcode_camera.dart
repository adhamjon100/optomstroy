// Камера-сканер штрихкодов (SCR-17; `mobile_scanner`, только Android/iOS — R3 §7, D-42).
//
// Порт [BarcodeCamera] отделяет экран SCR-17 от плагина: в widget-тестах подставляется фейк
// (`barcodeCameraFactoryProvider`), на устройстве — [MobileScannerBarcodeCamera].
// Разрешение камеры запрашивает сам плагин при `start()`; отказ → [CameraStatus.permissionDenied].
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Формат кода, распознанного камерой (подпись — для `scan_test_result`, 02 SCR-17.4).
enum CameraBarcodeFormat {
  /// EAN-13.
  ean13('EAN-13'),

  /// EAN-8.
  ean8('EAN-8'),

  /// Code 128.
  code128('Code128'),

  /// UPC-A.
  upcA('UPC-A'),

  /// UPC-E.
  upcE('UPC-E'),

  /// QR (номер заказа с распечатки, `mode=order`).
  qrCode('QR'),

  /// Иной формат.
  other('other');

  const CameraBarcodeFormat(this.label);

  /// Техническая подпись формата.
  final String label;
}

/// Состояние камеры.
enum CameraStatus {
  /// Не запущена.
  idle,

  /// Запускается (в т. ч. системный запрос разрешения, UI-17-008).
  starting,

  /// Превью работает.
  running,

  /// Нет разрешения ОС (UI-17-009).
  permissionDenied,

  /// Камеры нет / платформа не поддерживается.
  unsupported,

  /// Камера занята или ошибка (`scan_camera_error`).
  failed,
}

/// Фонарик.
enum CameraTorch {
  /// Нет вспышки — кнопка скрыта (UI-17-002).
  unavailable,

  /// Выключен.
  off,

  /// Включён.
  on,
}

/// Состояние камеры для экрана.
@immutable
final class BarcodeCameraState {
  /// Создаёт состояние.
  const BarcodeCameraState({this.status = CameraStatus.idle, this.torch = CameraTorch.unavailable});

  /// Статус.
  final CameraStatus status;

  /// Фонарик.
  final CameraTorch torch;

  @override
  bool operator ==(Object other) => other is BarcodeCameraState && other.status == status && other.torch == torch;

  @override
  int get hashCode => Object.hash(status, torch);
}

/// Код, распознанный в кадре.
@immutable
final class CameraDetection {
  /// Создаёт распознавание.
  const CameraDetection(this.value, this.format);

  /// Значение кода.
  final String value;

  /// Формат.
  final CameraBarcodeFormat format;
}

/// Порт камеры-сканера.
abstract interface class BarcodeCamera {
  /// Состояние (статус, фонарик).
  ValueListenable<BarcodeCameraState> get state;

  /// Распознавания по кадрам: один элемент потока — коды одного кадра.
  Stream<List<CameraDetection>> get detections;

  /// Запуск (первый запуск запрашивает разрешение ОС).
  Future<void> start();

  /// Остановка (уход в фон, пауза при листе выбора варианта).
  Future<void> stop();

  /// Переключение фонарика.
  Future<void> toggleTorch();

  /// Освобождение ресурсов.
  Future<void> dispose();

  /// Превью камеры на всю доступную область.
  Widget buildPreview(BuildContext context);
}

/// Создаёт камеру; [includeQr] — распознавать и QR (номер заказа, `mode=order`).
typedef BarcodeCameraFactory = BarcodeCamera Function({required bool includeQr});

/// Камера поддерживается платформой (Android/iOS; на Windows SCR-17 не открывается — D-42).
bool cameraScannerSupportedOn(TargetPlatform platform, {bool isWeb = kIsWeb}) =>
    !isWeb && (platform == TargetPlatform.android || platform == TargetPlatform.iOS);

/// Реализация на `mobile_scanner` 7.x.
final class MobileScannerBarcodeCamera implements BarcodeCamera {
  /// Создаёт камеру с форматами EAN-13, EAN-8, Code128, UPC-A/E (Q-009, [ТИПОВО]) и QR по [includeQr].
  MobileScannerBarcodeCamera({required bool includeQr})
    : _controller = MobileScannerController(
        autoStart: false,
        formats: <BarcodeFormat>[
          BarcodeFormat.ean13,
          BarcodeFormat.ean8,
          BarcodeFormat.code128,
          BarcodeFormat.upcA,
          BarcodeFormat.upcE,
          if (includeQr) BarcodeFormat.qrCode,
        ],
      ) {
    _controller.addListener(_sync);
  }

  final MobileScannerController _controller;
  final ValueNotifier<BarcodeCameraState> _state = ValueNotifier<BarcodeCameraState>(const BarcodeCameraState());

  @override
  ValueListenable<BarcodeCameraState> get state => _state;

  @override
  Stream<List<CameraDetection>> get detections => _controller.barcodes.map(
    (capture) => <CameraDetection>[
      for (final b in capture.barcodes)
        if (b.rawValue != null) CameraDetection(b.rawValue!, _format(b.format)),
    ],
  );

  @override
  Future<void> start() async {
    _state.value = BarcodeCameraState(status: CameraStatus.starting, torch: _state.value.torch);
    try {
      await _controller.start();
    } on MobileScannerException catch (e) {
      _state.value = BarcodeCameraState(status: _statusOf(e.errorCode));
      return;
    }
    _sync();
  }

  @override
  Future<void> stop() => _controller.stop();

  @override
  Future<void> toggleTorch() => _controller.toggleTorch();

  @override
  Future<void> dispose() async {
    _controller.removeListener(_sync);
    await _controller.dispose();
    _state.dispose();
  }

  @override
  Widget buildPreview(BuildContext context) => MobileScanner(
    controller: _controller,
    placeholderBuilder: (_) => const SizedBox.expand(),
    errorBuilder: (_, _) => const SizedBox.expand(),
  );

  void _sync() {
    final v = _controller.value;
    final error = v.error;
    final status = error != null
        ? _statusOf(error.errorCode)
        : v.isRunning
        ? CameraStatus.running
        : v.isStarting
        ? CameraStatus.starting
        : CameraStatus.idle;
    final torch = switch (v.torchState) {
      TorchState.on => CameraTorch.on,
      TorchState.off || TorchState.auto => CameraTorch.off,
      TorchState.unavailable => CameraTorch.unavailable,
    };
    _state.value = BarcodeCameraState(status: status, torch: torch);
  }

  static CameraStatus _statusOf(MobileScannerErrorCode code) => switch (code) {
    MobileScannerErrorCode.permissionDenied => CameraStatus.permissionDenied,
    MobileScannerErrorCode.unsupported => CameraStatus.unsupported,
    _ => CameraStatus.failed,
  };

  static CameraBarcodeFormat _format(BarcodeFormat f) => switch (f) {
    BarcodeFormat.ean13 => CameraBarcodeFormat.ean13,
    BarcodeFormat.ean8 => CameraBarcodeFormat.ean8,
    BarcodeFormat.code128 => CameraBarcodeFormat.code128,
    BarcodeFormat.upcA => CameraBarcodeFormat.upcA,
    BarcodeFormat.upcE => CameraBarcodeFormat.upcE,
    BarcodeFormat.qrCode => CameraBarcodeFormat.qrCode,
    _ => CameraBarcodeFormat.other,
  };
}

// SCR-17 Сканер штрихкода — камера, Android/iOS (`/scan?mode=search|add|order|test`, staff; 02 ч. B).
//
// Имя класса, путь файла и параметры конструктора фиксированы основой маршрутов (app/router/routes.dart).
// Камера — порт `BarcodeCamera` (`mobile_scanner` на устройстве, фейк в тестах). На Windows и без камеры
// экран не применяется (D-42): показывается `EmptyState.noCamera` с подсказкой HID-сканера.
// Поток: код в 2 кадрах подряд (CameraCodeFilter) → проверка формата 3…64 `[0-9A-Za-z-]` →
//  * `order`/`test`: карточка 600 мс → `pop(ScannedCode)` без запросов (UI-17-013/014);
//  * `search`/`add`: `GET /search/barcode/{value}` (офлайн — кэш) → найдено: серия выкл. — закрыть и
//    открыть SCR-14 (`add` — сначала +1 шаг в корзину, если порт корзины подключён); серия вкл. — карточка
//    «Открыть карточку»; не найдено — карточка `error` 3 с, сканирование продолжается (UI-17-012);
//    ошибка — «Не удалось проверить штрихкод · Повторить».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/scan/domain/camera_code_filter.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/presentation/scan_navigation.dart';
import 'package:optomstroy/features/scan/presentation/widgets/scan_result_card.dart';
import 'package:optomstroy/features/scan/presentation/widgets/scan_viewfinder.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';
import 'package:uuid/uuid.dart';

/// SCR-17 — Сканер штрихкода — камера, Android/iOS.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({this.mode, super.key});

  /// ID экрана по 02 §4.1.
  static const String screenId = 'SCR-17';

  /// Режим: `search|add|order|test` (02 §4.1).
  final String? mode;

  /// Сколько показывать распознанное значение в `order`/`test` перед закрытием.
  static const Duration valueHold = Duration(milliseconds: 600);

  /// Сколько показывать «не найдено».
  static const Duration notFoundHold = Duration(seconds: 3);

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

/// Последний результат (UI-17-005 … UI-17-014).
sealed class _Card {
  const _Card();
}

final class _Looking extends _Card {
  const _Looking(this.value);
  final String value;
}

final class _Found extends _Card {
  const _Found(this.value, this.result);
  final String value;
  final ScanLookupResult result;
}

final class _Added extends _Card {
  const _Added(this.result, this.receipt);
  final ScanLookupResult result;
  final ScanAddReceipt receipt;
}

final class _NotFound extends _Card {
  const _NotFound(this.value);
  final String value;
}

final class _LookupError extends _Card {
  const _LookupError(this.value);
  final String value;
}

final class _Invalid extends _Card {
  const _Invalid();
}

final class _CodeValue extends _Card {
  const _CodeValue(this.value, this.format);
  final String value;
  final String format;
}

class _ScanScreenState extends ConsumerState<ScanScreen> with WidgetsBindingObserver {
  late final ScanMode _mode = ScanMode.parse(widget.mode);
  late final bool _supported;
  BarcodeCamera? _camera;
  StreamSubscription<List<CameraDetection>>? _frames;
  final CameraCodeFilter _filter = CameraCodeFilter();
  final Stopwatch _clock = Stopwatch()..start();

  _Card? _card;
  ViewfinderFlash? _flash;
  Timer? _flashTimer;
  Timer? _cardTimer;
  Timer? _closeTimer;
  bool _busy = false;
  CameraDetection? _pending;
  bool _closing = false;
  int _addedCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _supported = ref.read(cameraScannerSupportedProvider);
    if (_supported) {
      final camera = ref.read(barcodeCameraFactoryProvider)(includeQr: _mode == ScanMode.order);
      _camera = camera;
      _frames = camera.detections.listen(_onFrame);
      // Превью должно быть в дереве до запуска (mobile_scanner ждёт привязки виджета).
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flashTimer?.cancel();
    _cardTimer?.cancel();
    _closeTimer?.cancel();
    unawaited(_frames?.cancel());
    unawaited(_camera?.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (camera == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        // Возврат из фона или из настроек ОС — повторная проверка разрешения (02 SCR-17.6).
        if (!_closing) _start();
      case AppLifecycleState.inactive || AppLifecycleState.paused || AppLifecycleState.hidden:
        unawaited(camera.stop());
      case AppLifecycleState.detached:
        break;
    }
  }

  void _start() {
    if (!mounted) return;
    final camera = _camera;
    if (camera == null || camera.state.value.status == CameraStatus.running) return;
    unawaited(camera.start());
  }

  // ---------------------------------------------------------------- распознавание

  void _onFrame(List<CameraDetection> frame) {
    if (!mounted || _closing) return;
    final accepted = _filter.onFrame(<String>[for (final d in frame) d.value], _clock.elapsed);
    if (accepted == null) return;
    final detection = frame.firstWhere((d) => d.value == accepted);
    _onCode(detection);
  }

  void _onCode(CameraDetection detection) {
    unawaited(HapticFeedback.mediumImpact());
    final value = BarcodeValue.normalize(detection.value);
    if (!BarcodeValue.isValid(value)) {
      _flashFor(ViewfinderFlash.error);
      _showCard(const _Invalid(), hold: ScanScreen.notFoundHold);
      return;
    }
    switch (_mode) {
      case ScanMode.order || ScanMode.test:
        _closing = true;
        _flashFor(ViewfinderFlash.success);
        _showCard(_CodeValue(value, detection.format.label));
        _closeTimer = Timer(ScanScreen.valueHold, () {
          if (mounted) closeScanner(context, result: ScannedCode(value, detection.format.label));
        });
      case ScanMode.search || ScanMode.add:
        if (_busy) {
          // Другой код во время запроса — в очередь (02 SCR-17.4).
          _pending = detection;
          return;
        }
        unawaited(_lookup(value));
    }
  }

  Future<void> _lookup(String value) async {
    _busy = true;
    _showCard(_Looking(value));
    final outcome = await ref.read(lookupScannedBarcodeProvider)(value);
    if (!mounted) return;
    switch (outcome) {
      case ScanFound(:final result):
        _flashFor(ViewfinderFlash.success);
        await _onFound(value, result);
      case ScanNotFound():
        _flashFor(ViewfinderFlash.error);
        _showCard(_NotFound(value), hold: ScanScreen.notFoundHold);
      case ScanLookupFailed():
        _flashFor(ViewfinderFlash.error);
        _showCard(_LookupError(value));
    }
    _busy = false;
    final next = _pending;
    _pending = null;
    if (next != null && mounted && !_closing) _onCode(next);
  }

  Future<void> _onFound(String value, ScanLookupResult result) async {
    final series = ref.read(scanSeriesModeProvider);
    final cart = _mode == ScanMode.add ? ref.read(scanCartPortProvider) : null;
    if (cart != null) {
      final added = await cart.addStep(result, idempotencyKey: const Uuid().v4());
      if (!mounted) return;
      switch (added.valueOrNull) {
        case final ScanAddReceipt receipt:
          _addedCount++;
          if (!series) {
            _closing = true;
            closeScanner(context, result: ScannedProduct(value, result, added: true));
            return;
          }
          _showCard(_Added(result, receipt));
        case null:
          _showCard(_LookupError(value));
      }
      return;
    }
    if (!series) {
      _openProduct(value, result);
      return;
    }
    _showCard(_Found(value, result));
  }

  void _openProduct(String value, ScanLookupResult result) {
    _closing = true;
    if (result.ambiguous) {
      AppSnackbar.show(context, message: AppLocalizations.of(context).scan_ambiguous);
    }
    closeScanner(context, result: ScannedProduct(value, result), then: ScanLocations.product(result));
  }

  void _showCard(_Card card, {Duration? hold}) {
    _cardTimer?.cancel();
    setState(() => _card = card);
    if (hold != null) {
      _cardTimer = Timer(hold, () {
        if (mounted && identical(_card, card)) setState(() => _card = null);
      });
    }
  }

  void _flashFor(ViewfinderFlash flash) {
    _flashTimer?.cancel();
    setState(() => _flash = flash);
    _flashTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  // ---------------------------------------------------------------- действия

  void _close() {
    _closing = true;
    if (_addedCount > 0) {
      AppSnackbar.show(context, message: AppLocalizations.of(context).scan_series_summary(_addedCount));
    }
    closeScanner(context);
  }

  void _manualEntry() {
    _closing = true;
    if (_mode == ScanMode.order) {
      closeScanner(context);
    } else {
      closeScanner(context, then: ScanLocations.search(), replaceWithGo: true);
    }
  }

  Future<void> _openSettings() async {
    final opened = await ref.read(appSettingsLauncherProvider)();
    // Настройки ОС не открылись — повторяем запуск: ОС может снова показать системный запрос.
    if (!opened) _start();
  }

  Future<void> _undo(ScanAddReceipt receipt) async {
    final cart = ref.read(scanCartPortProvider);
    if (cart == null) return;
    await cart.undo(receipt);
    if (!mounted) return;
    _addedCount = _addedCount > 0 ? _addedCount - 1 : 0;
    _cardTimer?.cancel();
    setState(() => _card = null);
  }

  // ---------------------------------------------------------------- интерфейс

  String get _title {
    final l10n = AppLocalizations.of(context);
    return switch (_mode) {
      ScanMode.order => l10n.scan_title_order,
      ScanMode.test => l10n.scan_title_test,
      ScanMode.search || ScanMode.add => l10n.scan_title,
    };
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final Widget body = camera == null
        ? _unavailable(context)
        : ValueListenableBuilder<BarcodeCameraState>(
            valueListenable: camera.state,
            builder: (context, state, _) => switch (state.status) {
              CameraStatus.permissionDenied => _noPermission(context),
              CameraStatus.unsupported => _unavailable(context),
              CameraStatus.failed => _cameraError(context),
              CameraStatus.idle || CameraStatus.starting || CameraStatus.running => _scanner(context, camera, state),
            },
          );
    return Scaffold(
      key: const ValueKey<String>('scan-screen'),
      // Под превью — `inverseSurface`; текст и рамка на затемнении — `onInverseSurface` (EQ-SCAN-06).
      backgroundColor: camera == null ? context.colors.background : context.colors.inverseSurface,
      body: body,
    );
  }

  Widget _plainScaffoldBody(BuildContext context, Widget content) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Column(
        children: <Widget>[
          Padding(
            padding: EdgeInsets.all(context.space.s1),
            child: Row(
              children: <Widget>[
                AppIconButton(icon: Icons.close_rounded, semanticLabel: l10n.ds_button_close, onPressed: _close),
                SizedBox(width: context.space.s2),
                Expanded(
                  child: Text(_title, style: context.text.title.copyWith(color: context.colors.textPrimary)),
                ),
              ],
            ),
          ),
          Expanded(child: Center(child: content)),
        ],
      ),
    );
  }

  /// UI-17-009: нет доступа к камере.
  Widget _noPermission(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      color: context.colors.surface,
      child: _plainScaffoldBody(
        context,
        EmptyState(
          key: const ValueKey<String>('scan-no-permission'),
          variant: EmptyStateVariant.noCamera,
          title: l10n.ds_empty_no_camera_title,
          body: l10n.scan_no_camera_body,
          actionLabel: l10n.scan_open_settings,
          onAction: () => unawaited(_openSettings()),
          secondaryActionLabel: _mode == ScanMode.test ? null : l10n.scan_manual_entry,
          onSecondaryAction: _mode == ScanMode.test ? null : _manualEntry,
        ),
      ),
    );
  }

  /// Windows / нет камеры (D-42): HID-сканер работает без экрана.
  Widget _unavailable(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _plainScaffoldBody(
      context,
      EmptyState(
        key: const ValueKey<String>('scan-unavailable'),
        variant: EmptyStateVariant.noCamera,
        title: l10n.ds_empty_no_camera_title,
        body: l10n.scan_hid_waiting,
        actionLabel: _mode == ScanMode.test ? null : l10n.scan_manual_entry,
        onAction: _mode == ScanMode.test ? null : _manualEntry,
      ),
    );
  }

  /// Камера занята / ошибка камеры.
  Widget _cameraError(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      color: context.colors.surface,
      child: _plainScaffoldBody(
        context,
        ErrorState.fullScreen(
          key: const ValueKey<String>('scan-camera-error'),
          title: l10n.ds_empty_no_camera_title,
          message: l10n.scan_camera_error,
          onRetry: _start,
          onBack: _mode == ScanMode.test ? null : _manualEntry,
          backLabel: _mode == ScanMode.test ? null : l10n.scan_manual_entry,
        ),
      ),
    );
  }

  Widget _scanner(BuildContext context, BarcodeCamera camera, BarcodeCameraState state) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final s = context.space;
    final compact = context.windowClass == WindowClass.compact;
    final running = state.status == CameraStatus.running;

    final Widget preview = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        camera.buildPreview(context),
        ScanViewfinder(flash: _flash, active: running && !_busy),
      ],
    );

    final Widget header = Padding(
      padding: EdgeInsets.symmetric(horizontal: s.s1),
      child: SizedBox(
        height: 56,
        child: Row(
          children: <Widget>[
            AppIconButton(
              key: const ValueKey<String>('scan-close'),
              icon: Icons.close_rounded,
              variant: AppIconButtonVariant.tonal,
              semanticLabel: l10n.ds_button_close,
              onPressed: _close,
            ),
            SizedBox(width: s.s2),
            Expanded(
              child: Text(
                _title,
                style: context.text.title.copyWith(color: c.onInverseSurface),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (state.torch != CameraTorch.unavailable)
              AppIconButton(
                key: const ValueKey<String>('scan-torch'),
                icon: state.torch == CameraTorch.on ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded,
                variant: AppIconButtonVariant.tonal,
                selected: state.torch == CameraTorch.on,
                semanticLabel: state.torch == CameraTorch.on ? l10n.scan_torch_off_a11y : l10n.scan_torch_on_a11y,
                onPressed: () => unawaited(camera.toggleTorch()),
              ),
          ],
        ),
      ),
    );

    final Widget hint = Text(
      _mode == ScanMode.order ? l10n.scan_hint_order : l10n.scan_hint,
      textAlign: TextAlign.center,
      style: context.text.body.copyWith(color: c.onInverseSurface),
    );

    final Widget bottom = Padding(
      padding: EdgeInsets.fromLTRB(s.s4, 0, s.s4, s.s4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_card != null) ...<Widget>[_resultCard(context, _card!), SizedBox(height: s.s3)],
          _controls(context),
        ],
      ),
    );

    if (compact) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          preview,
          SafeArea(
            child: Column(
              children: <Widget>[
                header,
                const Spacer(flex: 5),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: s.s4),
                  child: hint,
                ),
                const Spacer(flex: 2),
                bottom,
              ],
            ),
          ),
        ],
      );
    }
    // medium/expanded (Android-планшет): окно 480×360 по центру с теми же элементами.
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                header,
                ClipRRect(
                  borderRadius: BorderRadius.all(context.radii.md),
                  child: SizedBox(height: 360, child: preview),
                ),
                Padding(padding: EdgeInsets.all(s.s4), child: hint),
                bottom,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final s = context.space;
    final showManual = _mode != ScanMode.test;
    final showSeries = _mode.looksUpProduct;
    if (!showManual && !showSeries) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.all(context.radii.md)),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: s.s3, vertical: s.s1),
        child: Row(
          children: <Widget>[
            if (showManual)
              AppButton(
                key: const ValueKey<String>('scan-manual'),
                label: l10n.scan_manual_entry,
                variant: AppButtonVariant.outlined,
                onPressed: _manualEntry,
              ),
            if (showManual && showSeries) SizedBox(width: s.s2),
            if (!showSeries) const Spacer(),
            if (showSeries)
              Expanded(
                child: AppSwitch(
                  key: const ValueKey<String>('scan-series'),
                  value: ref.watch(scanSeriesModeProvider),
                  label: l10n.scan_series,
                  onChanged: (v) => ref.read(scanSeriesModeProvider.notifier).set(v),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(BuildContext context, _Card card) {
    final l10n = AppLocalizations.of(context);
    String? offlineNote(ScanLookupResult r) {
      if (!r.fromCache) return null;
      final at = r.asOf;
      if (at == null) return null;
      return l10n.scan_offline_note(DateFormat.Hm().format(at.toLocal()));
    }

    String subtitleOf(ScanLookupResult r, String value) =>
        <String>[if (r.sku != null && r.sku!.isNotEmpty) r.sku!, value].join(' · ');

    return switch (card) {
      _Looking(:final value) => ScanResultCard(
        key: const ValueKey<String>('scan-card-looking'),
        title: value,
        loading: true,
      ),
      _Found(:final value, :final result) => ScanResultCard(
        key: const ValueKey<String>('scan-card-found'),
        title: result.productName,
        subtitle: subtitleOf(result, value),
        note: result.ambiguous ? l10n.scan_ambiguous : offlineNote(result),
        tone: result.ambiguous ? ScanResultTone.info : ScanResultTone.neutral,
        actions: <ScanResultAction>[
          ScanResultAction(
            l10n.scan_open_product,
            () => _openProduct(value, result),
            key: const ValueKey<String>('scan-open-product'),
          ),
        ],
      ),
      _Added(:final result, :final receipt) => ScanResultCard(
        key: const ValueKey<String>('scan-card-added'),
        title: l10n.scan_added(result.productName, receipt.quantityLabel, receipt.unitLabel ?? ''),
        note: offlineNote(result),
        tone: ScanResultTone.success,
        actions: <ScanResultAction>[ScanResultAction(l10n.ds_button_undo, () => unawaited(_undo(receipt)))],
      ),
      _NotFound(:final value) => ScanResultCard(
        key: const ValueKey<String>('scan-card-not-found'),
        title: l10n.scan_not_found(value),
        tone: ScanResultTone.error,
        actions: <ScanResultAction>[ScanResultAction(l10n.scan_manual_entry, _manualEntry)],
      ),
      _LookupError(:final value) => ScanResultCard(
        key: const ValueKey<String>('scan-card-error'),
        title: l10n.scan_lookup_error,
        subtitle: value,
        tone: ScanResultTone.error,
        actions: <ScanResultAction>[ScanResultAction(l10n.ds_button_retry, () => unawaited(_lookup(value)))],
      ),
      _Invalid() => ScanResultCard(
        key: const ValueKey<String>('scan-card-invalid'),
        title: l10n.scan_invalid_code,
        tone: ScanResultTone.error,
      ),
      _CodeValue(:final value, :final format) => ScanResultCard(
        key: const ValueKey<String>('scan-card-value'),
        title: _mode == ScanMode.order ? l10n.scan_order_value(value) : l10n.scan_test_result(format, value),
        tone: _mode == ScanMode.test ? ScanResultTone.info : ScanResultTone.neutral,
      ),
    };
  }
}

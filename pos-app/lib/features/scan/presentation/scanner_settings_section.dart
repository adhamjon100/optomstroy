// Раздел «Сканер штрихкодов» для SCR-42 (02 SCR-42: UI-42-018 окончание скана, UI-42-012 тест сканера;
// порог между символами — EQ-SCAN-01). Встраивает исполнитель SCR-42 или интегратор:
// `ScannerSettingsSection(onSuffixChanged: (s) => …PUT /me/settings {scanner.suffix}…)`.
// Режим сканера (UI-42-011) и «Сразу добавлять в корзину» (UI-42-019) — серверные настройки
// пользователя (`PUT /me/settings`), их ведёт экран SCR-42.
//
// Тест HID: поле получает символы скана (OSK не вызывается, `TextInputType.none`); после окончания —
// значение и тип, затем `GET /search/barcode/{value}`: «Найден: {name} · арт. {sku}» / «Штрихкод {code}
// не найден в каталоге». Быстрая серия без окончания за 300 мс — подсказка `settings_scanner_no_suffix`.
// Камера (Android/iOS) — «Проверить камерой» → SCR-17 `mode=test` → результат проверяется так же.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/presentation/scan_navigation.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';

/// Раздел настроек сканера.
class ScannerSettingsSection extends ConsumerStatefulWidget {
  /// Создаёт раздел.
  const ScannerSettingsSection({super.key, this.showHeader = true, this.onSuffixChanged});

  /// Показывать заголовок «Сканер штрихкодов».
  final bool showHeader;

  /// Окончание изменено — SCR-42 сохраняет `Settings.scanner.suffix` на сервере.
  final ValueChanged<ScannerSuffix>? onSuffixChanged;

  /// Тип кода по значению HID-скана (сканер формат не сообщает).
  static String guessFormat(String value) {
    final digits = RegExp(r'^\d+$').hasMatch(value);
    if (digits && value.length == 13) return CameraBarcodeFormat.ean13.label;
    if (digits && value.length == 8) return CameraBarcodeFormat.ean8.label;
    if (digits && value.length == 12) return CameraBarcodeFormat.upcA.label;
    return CameraBarcodeFormat.code128.label;
  }

  @override
  ConsumerState<ScannerSettingsSection> createState() => _ScannerSettingsSectionState();
}

enum _TestStatus { idle, checking, found, notFound, error, invalid, noSuffix }

class _ScannerSettingsSectionState extends ConsumerState<ScannerSettingsSection> {
  late final ScannerWedgeService _service;
  late final HidScanRegistration _target;
  StreamSubscription<HidScanEvent>? _sub;
  bool _ownsAttachment = false;
  final FocusNode _testFocus = FocusNode(debugLabel: 'scanner-test-field');
  final TextEditingController _testText = TextEditingController();

  _TestStatus _status = _TestStatus.idle;
  String _value = '';
  String _format = '';
  ScanLookupResult? _found;
  int _requestSeq = 0;

  @override
  void initState() {
    super.initState();
    _service = ref.read(scannerWedgeServiceProvider);
    if (!_service.isAttached) {
      _service.attach();
      _ownsAttachment = true;
    }
    _target = _service.registerScanTarget(_testFocus);
    _sub = _service.events.listen(_onEvent);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _target.release();
    if (_ownsAttachment) _service.detach();
    _testFocus.dispose();
    _testText.dispose();
    super.dispose();
  }

  void _onEvent(HidScanEvent event) {
    if (!mounted || !_testFocus.hasFocus) return;
    switch (event) {
      case HidScanned(:final value):
        _testText.text = value;
        unawaited(_check(value, ScannerSettingsSection.guessFormat(value)));
      case HidScanRejected(:final value):
        setState(() {
          _value = value;
          _status = _TestStatus.invalid;
        });
      case HidScanIncomplete():
        setState(() => _status = _TestStatus.noSuffix);
      case HidScanIgnored():
        break;
    }
  }

  Future<void> _check(String value, String format) async {
    final seq = ++_requestSeq;
    setState(() {
      _value = value;
      _format = format;
      _found = null;
      _status = _TestStatus.checking;
    });
    ScanLookupOutcome outcome;
    try {
      outcome = await ref.read(lookupScannedBarcodeProvider)(value);
    } on Object catch (e) {
      // Порт поиска не подключён (`scanBarcodeLookupProvider` без адаптера) — показываем ошибку проверки.
      outcome = ScanLookupFailed(value, UnknownFailure(cause: e));
    }
    if (!mounted || seq != _requestSeq) return;
    setState(() {
      switch (outcome) {
        case ScanFound(:final result):
          _found = result;
          _status = _TestStatus.found;
        case ScanNotFound():
          _status = _TestStatus.notFound;
        case ScanLookupFailed():
          _status = _TestStatus.error;
      }
    });
  }

  Future<void> _testCamera() async {
    final result = await GoRouter.of(context).push<Object?>(ScanLocations.scan(ScanMode.test));
    if (!mounted || result is! ScannedCode) return;
    _testText.text = result.value;
    await _check(result.value, result.format);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = context.space;
    final config = ref.watch(scannerConfigProvider);
    final controller = ref.read(scannerConfigProvider.notifier);
    final cameraSupported = ref.watch(cameraScannerSupportedProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.showHeader) AppSectionHeader(title: l10n.settings_section_scanner),
        AppDropdown<ScannerSuffix>(
          key: const ValueKey<String>('scanner-suffix'),
          label: l10n.settings_scanner_suffix_label,
          value: config.suffix,
          items: <AppDropdownItem<ScannerSuffix>>[
            AppDropdownItem<ScannerSuffix>(value: ScannerSuffix.enter, label: l10n.settings_scanner_suffix_enter),
            AppDropdownItem<ScannerSuffix>(value: ScannerSuffix.tab, label: l10n.settings_scanner_suffix_tab),
            AppDropdownItem<ScannerSuffix>(value: ScannerSuffix.none, label: l10n.settings_scanner_suffix_none),
          ],
          onChanged: (v) {
            unawaited(controller.setSuffix(v));
            widget.onSuffixChanged?.call(v);
          },
        ),
        SizedBox(height: s.s4),
        // Порог между символами (UI-42-012, EQ-SCAN-01): «Интервал между символами», значения «{ms} мс».
        AppDropdown<int>(
          key: const ValueKey<String>('scanner-threshold'),
          label: l10n.settings_scanner_interval_label,
          value: config.interKeyThreshold.inMilliseconds,
          items: <AppDropdownItem<int>>[
            for (final ms in ScannerWedgeConfig.allowedThresholdsMs)
              AppDropdownItem<int>(value: ms, label: l10n.settings_scanner_interval_value('$ms')),
          ],
          onChanged: (v) => unawaited(controller.setInterKeyThresholdMs(v)),
        ),
        SizedBox(height: s.s4),
        AppTextField(
          key: const ValueKey<String>('scanner-test-field'),
          controller: _testText,
          focusNode: _testFocus,
          hint: l10n.settings_scanner_test_hint,
          keyboardType: TextInputType.none,
        ),
        if (_status != _TestStatus.idle) ...<Widget>[
          SizedBox(height: s.s2),
          Align(alignment: AlignmentDirectional.centerStart, child: _resultChip(l10n)),
        ],
        if (cameraSupported) ...<Widget>[
          SizedBox(height: s.s3),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              key: const ValueKey<String>('scanner-test-camera'),
              label: l10n.settings_scanner_test_camera,
              variant: AppButtonVariant.outlined,
              icon: Icons.photo_camera_outlined,
              onPressed: () => unawaited(_testCamera()),
            ),
          ),
        ],
      ],
    );
  }

  Widget _resultChip(AppLocalizations l10n) {
    final (String label, StatusChipVariant variant) = switch (_status) {
      _TestStatus.checking || _TestStatus.idle => (l10n.scan_test_result(_format, _value), StatusChipVariant.info),
      _TestStatus.found => (
        l10n.settings_scanner_test_found(_found?.productName ?? '', _found?.sku ?? ''),
        StatusChipVariant.success,
      ),
      _TestStatus.notFound => (l10n.settings_scanner_test_not_found(_value), StatusChipVariant.warning),
      _TestStatus.error => (l10n.scan_lookup_error, StatusChipVariant.error),
      _TestStatus.invalid => (l10n.scan_invalid_code, StatusChipVariant.error),
      _TestStatus.noSuffix => (l10n.settings_scanner_no_suffix, StatusChipVariant.warning),
    };
    return StatusChip(key: const ValueKey<String>('scanner-test-result'), label: label, variant: variant);
  }
}

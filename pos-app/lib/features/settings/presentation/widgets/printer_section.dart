// Секция «Принтер» SCR-42 (02 UI-42-005, UI-42-014, UI-42-020…UI-42-022; PRINT-006, PRINT-009, PRINT-010; D-27, Q-019):
// формат по умолчанию «Чек 80 мм» / «A4» и «Печатать автоматически после создания заказа» — серверные настройки
// пользователя (`PUT /me/settings` `printer.defaultFormat`, `printer.autoPrint`); сетевой ESC/POS — адрес и порт
// (только устройство); «Тестовая печать» — нефискальный образец на выбранном принтере.
//
// DAG 06 §6.1 не разрешает settings импортировать печать (orders) — секцию подключает композиционный корень через
// `settingsPrinterSectionProvider` (`settings_providers.dart`), передавая реализацию [PrinterSettingsPort]
// (чтение/запись настроек и сервис печати). Пока порт не подключён, секция в SCR-42 не показывается (GQ-FEADM-07).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Формат печати по умолчанию (`printer.defaultFormat`).
enum PrinterFormat {
  receipt80('80mm'),
  a4('a4');

  const PrinterFormat(this.value);

  final String value;

  static PrinterFormat? tryParse(String? v) => values.where((PrinterFormat f) => f.value == v).firstOrNull;
}

/// Настройки принтера рабочего места.
@immutable
final class PrinterPrefs {
  const PrinterPrefs({this.format, this.autoPrint = false, this.address, this.port});

  /// `null` — сервер не прислал (умолчание по роли).
  final PrinterFormat? format;
  final bool autoPrint;

  /// Сетевой ESC/POS (локально на устройстве).
  final String? address;
  final int? port;

  PrinterPrefs copyWith({PrinterFormat? format, bool? autoPrint, String? address, int? port}) => PrinterPrefs(
    format: format ?? this.format,
    autoPrint: autoPrint ?? this.autoPrint,
    address: address ?? this.address,
    port: port ?? this.port,
  );
}

/// Контракт подключения секции (реализует корень приложения поверх `/me/settings`, drift и сервиса печати).
abstract interface class PrinterSettingsPort {
  /// Текущие настройки.
  Future<PrinterPrefs> load();

  /// Сохранить; `false` — не удалось (значение возвращается).
  Future<bool> save(PrinterPrefs prefs);

  /// Тестовая печать; `null` — отправлено, иначе — причина ошибки для `settings_print_error`.
  Future<String?> testPrint(PrinterPrefs prefs);
}

/// Секция «Принтер».
class PrinterSettingsSection extends StatefulWidget {
  const PrinterSettingsSection({required this.port, super.key});

  /// Ключи для тестов.
  static Key formatKey(PrinterFormat f) => ValueKey<String>('settings-printer-format-${f.value}');
  static const Key autoPrintKey = ValueKey<String>('settings-printer-autoprint');
  static const Key addressKey = ValueKey<String>('settings-printer-address');
  static const Key portKey = ValueKey<String>('settings-printer-port');
  static const Key testKey = ValueKey<String>('settings-printer-test');

  final PrinterSettingsPort port;

  /// IPv4 или имя хоста (без схемы).
  static bool validAddress(String v) {
    final String t = v.trim();
    if (t.isEmpty) return true;
    final RegExp ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
    final RegExpMatch? m = ipv4.firstMatch(t);
    if (m != null) return <int>[1, 2, 3, 4].every((int i) => int.parse(m.group(i)!) <= 255);
    return RegExp(r'^[A-Za-z0-9][A-Za-z0-9.\-]{0,252}$').hasMatch(t);
  }

  /// Порт 1…65535.
  static bool validPort(String v) {
    final String t = v.trim();
    if (t.isEmpty) return true;
    final int? p = int.tryParse(t);
    return p != null && p >= 1 && p <= 65535;
  }

  @override
  State<PrinterSettingsSection> createState() => _PrinterSettingsSectionState();
}

class _PrinterSettingsSectionState extends State<PrinterSettingsSection> {
  PrinterPrefs? _prefs;
  bool _failed = false;
  bool _printing = false;
  final TextEditingController _address = TextEditingController();
  final TextEditingController _port = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _address.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final PrinterPrefs p = await widget.port.load();
      if (!mounted) return;
      setState(() {
        _prefs = p;
        _failed = false;
        _address.text = p.address ?? '';
        _port.text = p.port?.toString() ?? '';
      });
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Применить сразу (optimistic) и сохранить; при ошибке — вернуть значение и снекбар `settings_save_error`.
  Future<void> _apply(PrinterPrefs next) async {
    final PrinterPrefs? before = _prefs;
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() => _prefs = next);
    final bool ok = await widget.port.save(next);
    if (ok || !mounted) return;
    setState(() => _prefs = before);
    AppSnackbar.show(context, message: l10n.settings_save_error, variant: AppSnackbarVariant.error);
  }

  void _applyNetwork() {
    final PrinterPrefs? p = _prefs;
    if (p == null ||
        !PrinterSettingsSection.validAddress(_address.text) ||
        !PrinterSettingsSection.validPort(_port.text)) {
      setState(() {});
      return;
    }
    unawaited(
      _apply(
        PrinterPrefs(
          format: p.format,
          autoPrint: p.autoPrint,
          address: _address.text.trim(),
          port: int.tryParse(_port.text.trim()),
        ),
      ),
    );
  }

  Future<void> _test() async {
    final PrinterPrefs? p = _prefs;
    if (p == null || _printing) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() => _printing = true);
    final String? error = await widget.port.testPrint(p);
    if (!mounted) return;
    setState(() => _printing = false);
    AppSnackbar.show(
      context,
      message: error == null ? l10n.settings_print_test_ok : l10n.settings_print_error(error),
      variant: error == null ? AppSnackbarVariant.success : AppSnackbarVariant.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final PrinterPrefs? p = _prefs;
    if (p == null) {
      if (_failed) return ErrorState.inline(message: l10n.settings_save_error, onRetry: () => unawaited(_load()));
      return const Column(children: <Widget>[SkeletonBox(height: 48), SizedBox(height: 8), SkeletonBox(height: 48)]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final PrinterFormat f in PrinterFormat.values)
          AppRadio<PrinterFormat>(
            key: PrinterSettingsSection.formatKey(f),
            value: f,
            groupValue: p.format,
            label: f == PrinterFormat.a4 ? l10n.settings_printer_format_a4 : l10n.settings_printer_format_80mm,
            onChanged: (PrinterFormat v) => unawaited(_apply(p.copyWith(format: v))),
          ),
        SizedBox(height: context.space.s3),
        AppSwitch(
          key: PrinterSettingsSection.autoPrintKey,
          value: p.autoPrint,
          label: l10n.settings_printer_autoprint,
          onChanged: (bool v) => unawaited(_apply(p.copyWith(autoPrint: v))),
        ),
        SizedBox(height: context.space.s4),
        AppSectionHeader(title: l10n.settings_printer_default, padding: EdgeInsets.zero),
        AppTextField(
          key: PrinterSettingsSection.addressKey,
          controller: _address,
          label: l10n.settings_printer_address,
          errorText: PrinterSettingsSection.validAddress(_address.text) ? null : l10n.settings_printer_address_error,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _applyNetwork(),
          onFocusChange: (bool focused) {
            if (!focused) _applyNetwork();
          },
        ),
        SizedBox(height: context.space.s2),
        AppTextField(
          key: PrinterSettingsSection.portKey,
          controller: _port,
          label: l10n.settings_printer_port,
          keyboardType: TextInputType.number,
          errorText: PrinterSettingsSection.validPort(_port.text) ? null : l10n.settings_printer_port_error,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _applyNetwork(),
          onFocusChange: (bool focused) {
            if (!focused) _applyNetwork();
          },
        ),
        SizedBox(height: context.space.s4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppButton(
            key: PrinterSettingsSection.testKey,
            label: l10n.settings_print_test,
            variant: AppButtonVariant.outlined,
            size: AppButtonSize.s,
            icon: Icons.print_outlined,
            loading: _printing,
            onPressed: _printing ? null : () => unawaited(_test()),
          ),
        ),
      ],
    );
  }
}

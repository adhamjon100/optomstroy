// Форма планшета SCR-54 UI-54-012 (02 SCR-54.3, SCR-54.4, SCR-54.8; 08 §4.18.11, §4.18.13; FLOW-043.S3, A5): имя
// (2–150, `profile_fullname_error_length`) и склад (активные склады, `GET /catalog/warehouses`). Один виджет — для
// подключения («Сделать это устройство планшетом магазина», склад по умолчанию — склад кассы, ADR-115 п. 24) и для
// «Изменить» (`ds_button_apply`, без step-up). Диалог 480 (compact — `AppBottomSheet`). Запрос выполняет вызывающий
// ([TabletFormSubmit]); `400 VALIDATION_FAILED` и `404 NOT_FOUND` — ошибка у поля, прочие ошибки — под формой, форма
// остаётся открытой (повтор — тем же `Idempotency-Key`, его держит вызывающий). Повторное нажатие во время запроса —
// игнор.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';

/// Тексты ошибок SCR-54 (02 SCR-54.8): `403 KIOSK_DISABLED` — «Режим планшета выключен», прочие — как SCR-45.
abstract final class TabletFailureText {
  static String of(AppLocalizations l10n, Failure failure) {
    if (failure is ServerFailure && failure.problemCode == ProblemCode.kioskDisabled) return l10n.error_kiosk_disabled;
    return AdminFailureText.of(l10n, failure);
  }

  /// Ошибка относится к складу формы (`404 NOT_FOUND` — склад не существует или неактивен; поле `warehouseId`).
  static bool warehouse(Failure failure) =>
      (failure is ServerFailure && failure.problemCode == ProblemCode.notFound) ||
      (failure is ValidationFailure && failure.errors.any((e) => e.field.endsWith('warehouseId')));

  /// Ошибка относится к имени (`400 VALIDATION_FAILED`, поле `name`).
  static bool name(Failure failure) =>
      failure is ValidationFailure && failure.errors.any((e) => e.field == 'name' || e.field.endsWith('.name'));
}

/// Режим формы.
enum TabletFormMode { enroll, edit }

/// Запрос формы: имя (без крайних пробелов) и склад → итог.
typedef TabletFormSubmit<T> = Future<AdminActionResult<T>> Function(String name, String warehouseId);

/// UI-54-012. Результат [show] — значение успешного [submit] или `null` (отмена).
class TabletFormDialog<T> extends StatefulWidget {
  const TabletFormDialog({
    super.key,
    required this.mode,
    required this.warehouses,
    required this.submit,
    this.initialName = '',
    this.initialWarehouseId,
    this.showTitle = true,
  });

  final TabletFormMode mode;
  final List<TabletWarehouse> warehouses;
  final TabletFormSubmit<T> submit;
  final String initialName;
  final String? initialWarehouseId;

  /// Заголовок внутри (диалог); в нижнем листе заголовок — у листа.
  final bool showTitle;

  /// Ключи для тестов.
  static const Key nameKey = ValueKey<String>('tablet-form-name');
  static const Key warehouseKey = ValueKey<String>('tablet-form-warehouse');
  static const Key submitKey = ValueKey<String>('tablet-form-submit');
  static const Key errorKey = ValueKey<String>('tablet-form-error');

  static String title(AppLocalizations l10n, TabletFormMode mode) =>
      mode == TabletFormMode.enroll ? l10n.kiosk_admin_enroll : l10n.kiosk_admin_edit;

  /// Диалог 480 (compact — нижний лист).
  static Future<T?> show<T>(
    BuildContext context, {
    required TabletFormMode mode,
    required List<TabletWarehouse> warehouses,
    required TabletFormSubmit<T> submit,
    String initialName = '',
    String? initialWarehouseId,
  }) {
    final bool compact = DsBreakpoints.of(context) == WindowClass.compact;
    final TabletFormDialog<T> form = TabletFormDialog<T>(
      mode: mode,
      warehouses: warehouses,
      submit: submit,
      initialName: initialName,
      initialWarehouseId: initialWarehouseId,
      showTitle: !compact,
    );
    if (compact) {
      return AppBottomSheet.show<T>(context, title: title(AppLocalizations.of(context), mode), body: form);
    }
    return showDialog<T>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => Dialog(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: form),
      ),
    );
  }

  @override
  State<TabletFormDialog<T>> createState() => _TabletFormDialogState<T>();
}

class _TabletFormDialogState<T> extends State<TabletFormDialog<T>> {
  late final TextEditingController _name = TextEditingController(text: widget.initialName);
  String? _warehouseId;
  bool _submitted = false;
  bool _busy = false;
  bool _serverName = false;
  bool _serverWarehouse = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    final String? initial = widget.initialWarehouseId;
    _warehouseId = initial != null && widget.warehouses.any((TabletWarehouse w) => w.id == initial) ? initial : null;
    _name.addListener(() {
      if (_serverName) setState(() => _serverName = false);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _nameValid => StoreTablet.validName(_name.text);

  /// Склады выбора: активные и текущий склад записи (изменение), даже если он стал неактивным.
  List<TabletWarehouse> get _choices => <TabletWarehouse>[
    for (final TabletWarehouse w in widget.warehouses)
      if (w.isActive || w.id == widget.initialWarehouseId) w,
  ];

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _submitted = true;
      _formError = null;
    });
    final String? warehouseId = _warehouseId;
    if (!_nameValid || warehouseId == null) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    final AdminActionResult<T> result = await widget.submit(_name.text.trim(), warehouseId);
    if (!mounted) return;
    switch (result) {
      case ActionDone<T>(:final value):
        Navigator.of(context).pop(value);
        return;
      case ActionFailed<T>(:final failure):
        setState(() {
          _busy = false;
          _serverName = TabletFailureText.name(failure);
          _serverWarehouse = TabletFailureText.warehouse(failure);
          _formError = _serverName || _serverWarehouse ? null : TabletFailureText.of(l10n, failure);
        });
      case ActionCancelled<T>():
        setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? nameError = (_submitted && !_nameValid) || _serverName ? l10n.profile_fullname_error_length : null;
    // Склад не выбран (справочник пуст или недоступен) или сервер не нашёл активный склад — «Не найдено».
    final String? warehouseError = _serverWarehouse || (_submitted && _warehouseId == null)
        ? l10n.error_not_found
        : null;
    return PopScope(
      canPop: !_busy,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(widget.showTitle ? context.space.s5 : context.space.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.showTitle) ...<Widget>[
              Text(
                TabletFormDialog.title(l10n, widget.mode),
                style: context.text.h3.copyWith(color: context.colors.textPrimary),
              ),
              SizedBox(height: context.space.s4),
            ],
            AppTextField(
              key: TabletFormDialog.nameKey,
              controller: _name,
              label: l10n.kiosk_admin_name_label,
              errorText: nameError,
              maxLength: StoreTablet.nameMax,
              enabled: !_busy,
              autofocus: widget.mode == TabletFormMode.enroll,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => unawaited(_submit()),
            ),
            SizedBox(height: context.space.s3),
            AppDropdown<String>(
              key: TabletFormDialog.warehouseKey,
              label: l10n.kiosk_admin_warehouse_label,
              value: _warehouseId,
              errorText: warehouseError,
              items: <AppDropdownItem<String>>[
                for (final TabletWarehouse w in _choices) AppDropdownItem<String>(value: w.id, label: w.name),
              ],
              onChanged: _busy
                  ? null
                  : (String id) => setState(() {
                      _warehouseId = id;
                      _serverWarehouse = false;
                    }),
            ),
            if (_formError != null) ...<Widget>[
              SizedBox(height: context.space.s3),
              Text(
                _formError!,
                key: TabletFormDialog.errorKey,
                style: context.text.body.copyWith(color: context.colors.error),
              ),
            ],
            SizedBox(height: context.space.s5),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: context.space.s2,
              runSpacing: context.space.s2,
              children: <Widget>[
                AppButton(
                  label: l10n.ds_button_cancel,
                  variant: AppButtonVariant.text,
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                ),
                AppButton(
                  key: TabletFormDialog.submitKey,
                  label: widget.mode == TabletFormMode.enroll ? l10n.kiosk_admin_enroll : l10n.ds_button_apply,
                  icon: widget.mode == TabletFormMode.enroll ? Icons.tablet_android_rounded : null,
                  loading: _busy,
                  onPressed: () => unawaited(_submit()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

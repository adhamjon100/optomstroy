// Подключение этого устройства планшетом магазина (02 SCR-54 UI-54-002, UI-54-012, UI-54-013; FLOW-043.S3–S4, A2,
// A6; 08 §4.18.11, §4.18.15; ADR-115 п. 20, п. 24):
// - [TabletEnrollDialog] — форма «Сделать это устройство планшетом магазина» (имя и склад; склад по умолчанию — склад
//   кассы) → `POST /admin/store-tablets`; один `Idempotency-Key` на набор полей: повтор после обрыва тем же ключом
//   второго планшета не создаёт (новые токены и новый аварийный код);
// - [TabletReconnectDialog] — выбор записи «Выберите планшет для подключения заново» (предвыбор — запись из признака
//   планшета на устройстве, если он сохранился) → `POST /admin/store-tablets/{id}/reconnect`; ключ — на выбранную запись.
// Запрос со step-up выполняет вызывающий; диалог держит loading и ошибку под формой.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_edit_dialog.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_actions.dart';

/// Запрос подключения с ключом идемпотентности формы.
typedef TabletEnrollSubmit =
    Future<AdminActionResult<KioskEnrollment>> Function(String name, String warehouseId, String idempotencyKey);

/// Запрос подключения заново выбранной записи.
typedef TabletReconnectSubmit =
    Future<AdminActionResult<KioskEnrollment>> Function(String tabletId, String idempotencyKey);

abstract final class TabletEnrollDialog {
  /// UI-54-012 в режиме подключения. Результат — ответ `201 KioskTokens` или `null` (отмена).
  static Future<KioskEnrollment?> show(
    BuildContext context, {
    required List<TabletWarehouse> warehouses,
    required TabletEnrollSubmit submit,
  }) {
    // Один ключ на набор полей (имя, склад): обрыв и «Повторить» — тот же ключ, другие значения — новый.
    String? key;
    String? keyFor;
    return TabletFormDialog.show<KioskEnrollment>(
      context,
      mode: TabletFormMode.enroll,
      warehouses: warehouses,
      initialWarehouseId: defaultTabletWarehouse(warehouses),
      submit: (String name, String warehouseId) {
        final String fields = '$name\u0000$warehouseId';
        if (key == null || keyFor != fields) {
          key = newIdempotencyKey();
          keyFor = fields;
        }
        return submit(name, warehouseId, key!);
      },
    );
  }
}

/// UI-54-013 «Выберите планшет для подключения заново».
class TabletReconnectDialog extends StatefulWidget {
  const TabletReconnectDialog({
    super.key,
    required this.tablets,
    required this.submit,
    this.preselectedId,
    this.warehouseName,
  });

  final List<StoreTablet> tablets;
  final TabletReconnectSubmit submit;

  /// Запись этого устройства (признак планшета), если известна.
  final String? preselectedId;

  /// Название склада строки.
  final String? Function(String warehouseId)? warehouseName;

  static const Key submitKey = ValueKey<String>('tablet-reconnect-submit');
  static const Key errorKey = ValueKey<String>('tablet-reconnect-error');
  static Key optionKey(String id) => ValueKey<String>('tablet-reconnect-$id');

  /// Диалог 480. Результат — ответ `200 KioskTokens` или `null` (отмена).
  static Future<KioskEnrollment?> show(
    BuildContext context, {
    required List<StoreTablet> tablets,
    required TabletReconnectSubmit submit,
    String? preselectedId,
    String? Function(String warehouseId)? warehouseName,
  }) => showDialog<KioskEnrollment>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: TabletReconnectDialog(
          tablets: tablets,
          submit: submit,
          preselectedId: preselectedId,
          warehouseName: warehouseName,
        ),
      ),
    ),
  );

  @override
  State<TabletReconnectDialog> createState() => _TabletReconnectDialogState();
}

class _TabletReconnectDialogState extends State<TabletReconnectDialog> {
  late String? _selected = widget.tablets.any((StoreTablet t) => t.id == widget.preselectedId)
      ? widget.preselectedId
      : null;
  final Map<String, String> _keys = <String, String>{};
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    final String? id = _selected;
    if (_busy || id == null) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final AdminActionResult<KioskEnrollment> result = await widget.submit(id, _keys[id] ??= newIdempotencyKey());
    if (!mounted) return;
    switch (result) {
      case ActionDone<KioskEnrollment>(:final value):
        Navigator.of(context).pop(value);
        return;
      case ActionFailed<KioskEnrollment>(:final failure):
        setState(() {
          _busy = false;
          _error = TabletFailureText.of(l10n, failure);
        });
      case ActionCancelled<KioskEnrollment>():
        setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_busy,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(context.space.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.kiosk_admin_reconnect_pick, style: context.text.h3.copyWith(color: context.colors.textPrimary)),
            SizedBox(height: context.space.s3),
            for (final StoreTablet t in widget.tablets)
              AppRadio<String>(
                key: TabletReconnectDialog.optionKey(t.id),
                value: t.id,
                groupValue: _selected,
                label: t.name,
                description: <String>[
                  ?widget.warehouseName?.call(t.warehouseId),
                  t.isActive ? l10n.kiosk_admin_status_active : l10n.kiosk_admin_status_revoked,
                ].join(' · '),
                onChanged: _busy ? null : (String id) => setState(() => _selected = id),
              ),
            if (_error != null) ...<Widget>[
              SizedBox(height: context.space.s3),
              Text(
                _error!,
                key: TabletReconnectDialog.errorKey,
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
                  key: TabletReconnectDialog.submitKey,
                  label: l10n.kiosk_admin_reconnect,
                  icon: Icons.sync_rounded,
                  loading: _busy,
                  onPressed: _selected == null ? null : () => unawaited(_submit()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

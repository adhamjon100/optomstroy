// Диалоги SCR-20: «Отложить заказ» с названием (UI-20-026), «Корзина изменена на другом устройстве» (UI-20-027),
// меню складов (UI-20-005), «Как получить подтверждение» (UI-20-031). Удаление/очистка — `ConfirmDialog` DS.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';

/// Анимация маршрута диалога (не деньги).
typedef _Anim = Animation<double>; // money-double: allow — анимация диалога

/// Масштаб появления диалога (не деньги).
typedef _Scale = Tween<double>; // money-double: allow — масштаб анимации

/// Логические пиксели (не деньги).
typedef _Lp = double; // money-double: allow — геометрия UI (lp)

/// Каркас диалога корзины: радиус `lg`, `elevation.3` + `overlay`, ширина [width] (compact — экран − 32), паддинг 24.
Future<T?> _showCartDialog<T>(
  BuildContext context, {
  required _Lp width,
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  final DsColors c = context.colors;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: AppLocalizations.of(context).ds_button_cancel,
    barrierColor: c.overlay,
    transitionDuration: context.motion.of(DsAnimations.dialog.duration),
    pageBuilder: (BuildContext ctx, _Anim a, _Anim b) => SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: Padding(
            padding: EdgeInsets.all(context.space.s4),
            child: Material(
              color: ctx.colors.surface,
              elevation: 0,
              borderRadius: BorderRadius.all(ctx.radii.lg),
              child: Padding(padding: EdgeInsets.all(context.space.s6), child: builder(ctx)),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (BuildContext ctx, _Anim a, _Anim b, Widget child) {
      final CurvedAnimation curve = CurvedAnimation(parent: a, curve: DsAnimations.dialog.curve);
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(scale: _Scale(begin: 0.96, end: 1).animate(curve), child: child),
      );
    },
  );
}

/// Итог диалога «Отложить заказ»: название (может быть пустым).
final class ParkDialogResult {
  const ParkDialogResult(this.name);

  final String? name;
}

/// UI-20-026: поле «Название (необязательно)» ≤ 60 [ТИПОВО]; «Отложить» / «Отмена»; `Enter` — «Отложить».
Future<ParkDialogResult?> showParkDialog(BuildContext context) =>
    _showCartDialog<ParkDialogResult>(context, width: 400, builder: (BuildContext ctx) => const _ParkDialog());

class _ParkDialog extends StatefulWidget {
  const _ParkDialog();

  @override
  State<_ParkDialog> createState() => _ParkDialogState();
}

class _ParkDialogState extends State<_ParkDialog> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final String v = _name.text.trim();
    Navigator.of(context).pop(ParkDialogResult(v.isEmpty ? null : v));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.cart_park_dialog_title, style: context.text.h3.copyWith(color: context.colors.textPrimary)),
        SizedBox(height: context.space.s4),
        AppTextField(
          key: const ValueKey<String>('cart-park-name'),
          controller: _name,
          label: l10n.cart_park_dialog_name_hint,
          maxLength: 60,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        SizedBox(height: context.space.s6),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            AppButton(
              label: l10n.ds_button_cancel,
              variant: AppButtonVariant.text,
              onPressed: () => Navigator.of(context).pop(),
            ),
            AppButton(
              key: const ValueKey<String>('cart-park-confirm'),
              label: l10n.cart_cta_park,
              icon: Icons.bookmark_outline_rounded,
              onPressed: _submit,
            ),
          ],
        ),
      ],
    );
  }
}

/// UI-20-027: серверная версия и список неприменённых локальных изменений; `true` — «Применить мои изменения»,
/// `false` — «Оставить как на сервере», `null` — закрыт без выбора (повторится при следующем открытии).
Future<bool?> showVersionConflictDialog(BuildContext context, CartVersionConflict conflict) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  return _showCartDialog<bool>(
    context,
    width: 480,
    dismissible: false,
    builder: (BuildContext ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.cart_version_conflict_title, style: ctx.text.h3.copyWith(color: ctx.colors.textPrimary)),
        SizedBox(height: ctx.space.s3),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final CartLocalLine l in conflict.unsent)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: ctx.space.s1),
                  child: Text(
                    '${l.productName ?? l.sku ?? l.key.variantId} — '
                    '${l.isDeletion ? l10n.qty_delete : '${CartFormats.qty(l.quantity)} ${l.unitLabel ?? ''}'.trim()}',
                    style: ctx.text.body.copyWith(color: ctx.colors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: ctx.space.s6),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: ctx.space.s2,
          runSpacing: ctx.space.s2,
          children: <Widget>[
            AppButton(
              key: const ValueKey<String>('cart-conflict-keep-server'),
              label: l10n.cart_version_conflict_keep_server,
              variant: AppButtonVariant.outlined,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            AppButton(
              key: const ValueKey<String>('cart-conflict-apply-mine'),
              label: l10n.cart_version_conflict_apply_mine,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ],
    ),
  );
}

/// UI-20-005: склады пользователя (кэш каталога), текущий отмечен галочкой. Результат — выбранный склад.
Future<CartWarehouseOption?> showWarehouseMenu(
  BuildContext context, {
  required List<CartWarehouseOption> options,
  required String? currentId,
}) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  return AppBottomSheet.show<CartWarehouseOption>(
    context,
    title: l10n.cart_warehouse_change_title,
    body: Builder(
      builder: (BuildContext ctx) => ListView(
        shrinkWrap: true,
        children: <Widget>[
          for (final CartWarehouseOption o in options)
            AppListTile(
              key: ValueKey<String>('cart-warehouse-${o.id}'),
              title: o.name,
              trailing: o.id == currentId ? Icon(Icons.check_rounded, color: ctx.colors.primaryText) : null,
              onTap: () => Navigator.of(ctx).pop(o),
            ),
        ],
      ),
    ),
  );
}

/// UI-20-031: «Как получить подтверждение»; `true` — «Отложить заказ».
Future<bool> showDiscountApprovalDialog(BuildContext context, {required String limit}) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  return ConfirmDialog.show(
    context,
    title: l10n.cart_discount_approval_how,
    message: l10n.cart_discount_approval_dialog_body(limit),
    confirmLabel: l10n.cart_discount_approval_park,
    cancelLabel: l10n.cart_discount_approval_ok,
  );
}

/// Ширина листа SCR-23 поверх корзины (02 SCR-23.2: 400 lp).
const double parkedSheetWidth = DsBreakpoints.productPanel; // money-double: allow — ширина листа (lp)

/// Запрет ввода дробей сверх точности строки нампадом (INV-006) — разбор ввода.
Qty? parseLineQuantity(String input, int precision) {
  try {
    return Qty.parseInput(input, precision: precision);
  } on Object {
    return null;
  }
}

/// Клавиша «Ctrl+Z» (UI-20-028) — для `CallbackShortcuts`.
const SingleActivator undoActivator = SingleActivator(LogicalKeyboardKey.keyZ, control: true);

/// Ожидание закрытия диалога без результата (для тестов — `unawaited`).
void ignoreResult(Future<Object?> f) => unawaited(f);

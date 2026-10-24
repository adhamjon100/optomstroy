import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `AppBottomSheet` (03 §9.47).
enum AppBottomSheetVariant {
  /// По содержимому, максимум 60 % (сортировка, единица, остатки).
  auto,

  /// 92 % высоты окна (корзина, фильтры).
  fullHeight,

  /// Панель справа, скругление `lg` слева; ширина 320 / 400 / 480.
  side,
}

/// Нижняя / боковая панель `AppBottomSheet` (03 §9.47): `surface`, верхние углы `lg`,
/// `elevation.3` + `overlay`; ручка 32×4 `borderStrong` (тач-цель 48 на всю ширину);
/// шапка 56: заголовок `h3` + `close`; прокручиваемое тело (паддинг 16/24); закреплённый
/// футер с CTA (`SafeArea`). Показ — [show] / [showSide], результат — `Future<T?>`.
class AppBottomSheet extends StatelessWidget {
  /// Создаёт содержимое панели.
  const AppBottomSheet({
    super.key,
    required this.body,
    this.title,
    this.footer,
    this.variant = AppBottomSheetVariant.auto,
    this.showHandle = true,
    this.onClose,
    this.width,
  });

  /// Заголовок.
  final String? title;

  /// Тело (прокручивается).
  final Widget body;

  /// Закреплённый футер с CTA.
  final Widget? footer;

  /// Вариант.
  final AppBottomSheetVariant variant;

  /// Ручка (у `side` нет).
  final bool showHandle;

  /// Крестик в шапке; по умолчанию — закрыть маршрут.
  final VoidCallback? onClose;

  /// Ширина `side`: 320 (overlay-корзина, medium), 400 (детали, medium), 480 (expanded).
  final double? width;

  /// Ширины `side` (ядро §19.4, DS-089).
  static const double sideCart = 320;

  /// Детали/формы на medium.
  static const double sideMedium = 400;

  /// Детали/формы на expanded.
  static const double sideExpanded = 480;

  /// Модальный нижний лист (`auto` / `fullHeight`).
  static Future<T?> show<T>(
    BuildContext context, {
    required Widget body,
    String? title,
    Widget? footer,
    AppBottomSheetVariant variant = AppBottomSheetVariant.auto,
  }) {
    final DsColors c = context.colors;
    final double h = MediaQuery.sizeOf(context).height;
    final double maxHeight = variant == AppBottomSheetVariant.fullHeight ? h * 0.92 : h * 0.6;
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: c.overlay,
      elevation: 0,
      constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 640),
      sheetAnimationStyle: AnimationStyle(
        duration: context.motion.of(DsAnimations.bottomSheet.duration),
        curve: DsAnimations.bottomSheet.curve,
      ),
      builder: (BuildContext ctx) => Padding(
        // Клавиатура поднимает лист (viewInsets).
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: AppBottomSheet(title: title, body: body, footer: footer, variant: variant),
      ),
    );
  }

  /// Боковая панель справа (`side`), slide-in по X (ANIM-025).
  static Future<T?> showSide<T>(
    BuildContext context, {
    required Widget body,
    required double width,
    String? title,
    Widget? footer,
  }) {
    final DsColors c = context.colors;
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: AppLocalizations.of(context).ds_button_close,
      barrierColor: c.overlay,
      transitionDuration: context.motion.of(DsAnimations.bottomSheet.duration),
      pageBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b) => Align(
        alignment: AlignmentDirectional.centerEnd,
        child: AppBottomSheet(
          title: title,
          body: body,
          footer: footer,
          variant: AppBottomSheetVariant.side,
          width: width,
        ),
      ),
      transitionBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b, Widget child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: a, curve: DsAnimations.bottomSheet.curve)),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool side = variant == AppBottomSheetVariant.side;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final VoidCallback close = onClose ?? () => Navigator.of(context).maybePop();
    final BorderRadius radius = side ? BorderRadius.horizontal(left: context.radii.lg) : context.radii.sheetTop;

    final Widget content = Column(
      mainAxisSize: side || variant == AppBottomSheetVariant.fullHeight ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showHandle && !side)
          Semantics(
            button: true,
            label: l10n.ds_button_close,
            onDismiss: close,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: close,
              child: SizedBox(
                height: 20,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.borderStrong,
                      borderRadius: BorderRadius.all(context.radii.full),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (title != null)
          SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 24, end: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.h3.copyWith(color: c.textPrimary),
                      ),
                    ),
                  ),
                  AppIconButton(icon: Icons.close_rounded, semanticLabel: l10n.ds_button_close, onPressed: close),
                ],
              ),
            ),
          ),
        Flexible(
          fit: side || variant == AppBottomSheetVariant.fullHeight ? FlexFit.tight : FlexFit.loose,
          child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 16), child: body),
        ),
        if (footer != null)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(padding: const EdgeInsets.fromLTRB(24, 12, 24, 12), child: footer),
            ),
          ),
      ],
    );

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: side ? (width ?? sideMedium) : null,
          decoration: BoxDecoration(color: c.surface, borderRadius: radius, boxShadow: context.elevation.e3),
          clipBehavior: Clip.antiAlias,
          child: content,
        ),
      ),
    );
  }
}

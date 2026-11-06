// Слой карточки товара витрины планшета магазина — SCR-51 UI-51-011 (02 ч. F; ADR-115 п. 22; 13 TAB-2-03): SCR-14 в
// варианте покупателя поверх `/kiosk` без нового маршрута (G-15 не выпускает на `/catalog/p/{id}`). Маршрут без
// страницы корневого навигатора, как drawer корзины (ADR-114 П.4): панель справа во всю высоту — expanded/large 640,
// medium — во весь экран [ТИПОВО]; затемнение `overlay` (0,48). «Назад», крестик, `Esc` и тап по затемнению закрывают
// слой; путь `/kiosk?c=`, категория, поиск и прокрутка витрины не меняются (02 SCR-51.6). ANIM-025: открытие 250 мс,
// закрытие 200 мс, при «Уменьшить анимации» — fade 80 мс (02 SCR-51.5).
//
// Содержимое слоя (данные карточки, варианты SCR-15, количество SCR-16, «В корзину») — порт
// `catalogKioskProductDetailsProvider` (фича product_details через корень: catalog ↛ product_details, 06 §6.1).
// Сброс планшета (FLOW-045) закрывает слой вместе с остальными маршрутами без страницы (`popUntil` страницы).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_motion.dart';

/// Слой карточки товара SCR-51.
abstract final class KioskProductSheet {
  /// Ключ панели слоя (тесты).
  static const Key key = ValueKey<String>('kiosk-product-sheet');

  /// Ключ крестика (тесты).
  static const Key closeKey = ValueKey<String>('kiosk-product-close');

  /// Ключ затемнения слева от панели (тесты).
  static const Key scrimKey = ValueKey<String>('kiosk-product-scrim');

  /// Ширина панели на expanded/large (02 UI-51-011 [ТИПОВО]).
  static const double width = 640; // money-double: allow — ширина панели слоя (lp), не деньги

  /// Открытие слоя (ANIM-025).
  static const Duration openDuration = Duration(milliseconds: 250);

  /// Закрытие слоя (ANIM-025).
  static const Duration closeDuration = Duration(milliseconds: 200);

  /// Ширина панели в окне [window] класса [wc]: medium (и уже) — во весь экран.
  static double widthFor(WindowClass wc, double window) => // money-double: allow — ширина панели (lp), не деньги
      wc == WindowClass.expanded || wc == WindowClass.large ? math.min(width, window) : window;

  /// Открыть слой с содержимым [body]; повторное открытие при открытом слое ничего не делает. Завершается, когда слой
  /// закрыт. [semanticLabel] — имя слоя для диктора (название товара; 03 A11Y-011: модальный слой объявляется).
  static Future<void> show(BuildContext context, {required String semanticLabel, required WidgetBuilder body}) async {
    if (_open != null && _open!.isActive) return;
    final DsMotion motion = context.motion;
    final _KioskProductSheetRoute route = _KioskProductSheetRoute(
      body: body,
      semanticLabel: semanticLabel,
      barrierLabel: AppLocalizations.of(context).ds_button_close,
      barrierColor: context.colors.overlay,
      reduceMotion: motion.reduceMotion,
      reduced: motion.reducedCrossfade,
    );
    _open = route;
    try {
      await Navigator.of(context, rootNavigator: true).push<void>(route);
    } finally {
      if (identical(_open, route)) _open = null;
    }
  }

  /// Слой открыт (маршрут в навигаторе).
  static bool get isOpen => _open?.isActive ?? false;

  static _KioskProductSheetRoute? _open;
}

/// Маршрут слоя: своя длительность открытия и закрытия (ANIM-025), затемнение рисует страница.
final class _KioskProductSheetRoute extends PopupRoute<void> {
  _KioskProductSheetRoute({
    required this.body,
    required this.semanticLabel,
    required this.barrierLabel,
    required this.barrierColor,
    required this.reduceMotion,
    required this.reduced,
  });

  final WidgetBuilder body;

  /// Имя слоя для диктора.
  final String semanticLabel;
  final bool reduceMotion;

  /// Единственная ненулевая длительность при «Уменьшить анимации» (fade 80 мс).
  final Duration reduced;

  @override
  final String barrierLabel;

  @override
  final Color barrierColor;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => reduceMotion ? reduced : KioskProductSheet.openDuration;

  @override
  Duration get reverseTransitionDuration => reduceMotion ? reduced : KioskProductSheet.closeDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation, // money-double: allow — анимация перехода, не деньги
    Animation<double> secondaryAnimation, // money-double: allow — анимация перехода, не деньги
  ) => _KioskProductSheetPage(
    animation: animation,
    reduceMotion: reduceMotion,
    semanticLabel: semanticLabel,
    body: body,
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation, // money-double: allow — анимация перехода, не деньги
    Animation<double> secondaryAnimation, // money-double: allow — анимация перехода, не деньги
    Widget child,
  ) => child;
}

/// Страница слоя: затемнение слева закрывает, панель справа выезжает (reduce-motion — появляется).
class _KioskProductSheetPage extends StatefulWidget {
  const _KioskProductSheetPage({
    required this.animation,
    required this.reduceMotion,
    required this.semanticLabel,
    required this.body,
  });

  final Animation<double> animation; // money-double: allow — анимация перехода, не деньги
  final bool reduceMotion;
  final String semanticLabel;
  final WidgetBuilder body;

  @override
  State<_KioskProductSheetPage> createState() => _KioskProductSheetPageState();
}

class _KioskProductSheetPageState extends State<_KioskProductSheetPage> {
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(1, 0),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: widget.animation, curve: DsMotion.defaults.standard));

  void _close() => unawaited(Navigator.of(context).maybePop());

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final double window = MediaQuery.sizeOf(context).width; // money-double: allow — ширина окна (lp), не деньги
    final double width = KioskProductSheet.widthFor(context.windowClass, window); // money-double: allow — ширина (lp)
    final Widget panel = SizedBox(
      key: KioskProductSheet.key,
      width: width,
      height: double.infinity, // money-double: allow — высота панели (lp), не деньги
      child: DecoratedBox(
        decoration: BoxDecoration(color: c.surface, boxShadow: context.elevation.e3),
        // Модальный слой: свой маршрут для диктора с именем — название товара (03 A11Y-011).
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: widget.semanticLabel,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.border)),
                  ),
                  alignment: AlignmentDirectional.centerEnd,
                  child: AppIconButton(
                    key: KioskProductSheet.closeKey,
                    icon: Icons.close_rounded,
                    semanticLabel: l10n.ds_button_close,
                    tooltip: l10n.ds_button_close,
                    onPressed: _close,
                  ),
                ),
                Expanded(child: Builder(builder: widget.body)),
              ],
            ),
          ),
        ),
      ),
    );
    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        // `Esc` (DismissIntent): ближайшее действие — у `Scaffold` (закрыть его drawer), до действия маршрута клавиша
        // не доходит — закрытие слоя задано здесь (как у drawer корзины).
        body: Actions(
          actions: <Type, Action<Intent>>{
            DismissIntent: CallbackAction<DismissIntent>(onInvoke: (DismissIntent _) => _close()),
          },
          child: Focus(
            autofocus: true,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // Затемнение слева закрывает слой само: `Scaffold` во всё окно перехватывает касания барьера (подпись
                // для диктора — у барьера маршрута, `barrierLabel`).
                GestureDetector(
                  key: KioskProductSheet.scrimKey,
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: _close,
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: widget.reduceMotion
                      ? FadeTransition(opacity: widget.animation, child: panel)
                      : SlideTransition(position: _slide, child: panel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

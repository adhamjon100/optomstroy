// T-UI-117 (golden; пакет wave2:APP-POLISH, находка ревью own-server:FIX-app «ни в одном эталоне нет метки
// «предварительно» в строке «Итого»»): `CartSummary` с меткой «предварительно» (UI-20-030; изменения не подтверждены
// сервером или нет сети) в окне compact 360 (03 §7.2), палитра B, сверху вниз:
//   * в строке, метка целиком — «Итого», метка и сумма в одну строку;
//   * в строке, метке остаток — сумма во всю свою ширину, метке только оставшееся место (с многоточием);
//   * строкой ниже (масштаб текста 1,3) — «Итого» и метка, сумма строкой ниже у конца, целиком;
//   * drawer 360 (планшет магазина: drawer во всю ширину окна, поля 20, фон подвала) — сумма строкой ниже.
// Ни в одной сцене сумма не уменьшается `FittedBox`; ветви этих же сцен проверяет `cart_summary_test.dart` («сцены
// эталона»). Ширина блока — как в приложении: экран корзины 360 (поля блока 16, внутри 328), drawer во всю ширину.
//
// Обновить эталоны: flutter test test/golden/cart_summary_golden_test.dart --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/cart_summary.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import 'design_system_golden_test.dart' show goldenWindows;

/// Сцена эталона: подпись, итог, масштаб текста, drawer.
typedef CartSummaryGoldenScene = ({String label, Money total, double scale, bool drawer});

/// Сцены эталона `ds_cart_summary_preliminary_compact` (ветви проверяет `cart_summary_test.dart`).
const List<CartSummaryGoldenScene> cartSummaryGoldenScenes = <CartSummaryGoldenScene>[
  (label: 'в строке · метка целиком · ×1', total: Money(85000), scale: 1, drawer: false),
  (label: 'в строке · метке остаток · ×1', total: Money(12445000), scale: 1, drawer: false),
  (label: 'строкой ниже · ×1,3', total: Money(12445000), scale: 1.3, drawer: false),
  (label: 'drawer 360 · строкой ниже · ×1', total: Money(12445000), scale: 1, drawer: true),
];

/// Блок итогов сцены [s] (ширину задаёт родитель — ширина окна, как у экрана корзины и drawer в приложении).
Widget cartSummaryGoldenBlock(CartSummaryGoldenScene s) => CartSummary(
  rows: <CartSummaryRow>[CartSummaryRow(label: 'Товаров (5)', amount: s.total)],
  totalLabel: 'Итого',
  total: s.total,
  preliminaryLabel: 'предварительно',
  drawer: s.drawer,
  note: 'Итог пересчитывает сервер по ценам 1С при оформлении',
  padding: s.drawer ? const EdgeInsets.fromLTRB(20, 16, 20, 0) : null,
);

/// Окно compact 360 без полей окна (`GoldenWindow` добавил бы 16): блоки во всю ширину, подписи сцен — с полем 16.
class _Window extends StatelessWidget {
  const _Window();

  @override
  Widget build(BuildContext context) {
    final Size window = goldenWindows[WindowClass.compact]!;
    final MediaQueryData base = MediaQuery.of(context);
    return MediaQuery(
      data: base.copyWith(
        size: window,
        disableAnimations: true,
        padding: EdgeInsets.zero,
        viewPadding: EdgeInsets.zero,
      ),
      child: Localizations(
        locale: const Locale('ru'),
        delegates: AppLocalizations.localizationsDelegates,
        child: Material(
          color: DsColors.lightB.background,
          child: SizedBox(
            width: window.width,
            child: Builder(
              builder: (BuildContext context) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final CartSummaryGoldenScene s in cartSummaryGoldenScenes) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(s.label, style: context.text.caption.copyWith(color: context.colors.textSecondary)),
                    ),
                    MediaQuery(
                      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(s.scale)),
                      child: s.drawer
                          ? ColoredBox(color: context.colors.drawerFooterBg, child: cartSummaryGoldenBlock(s))
                          : cartSummaryGoldenBlock(s),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  unawaited(
    goldenTest(
      'CartSummary «предварительно» · в строке и строкой ниже · compact',
      fileName: 'ds_cart_summary_preliminary_compact',
      constraints: BoxConstraints.tightFor(width: goldenWindows[WindowClass.compact]!.width),
      builder: () => const _Window(),
    ),
  );
}

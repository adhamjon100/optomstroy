import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Варианты `PriceText` (03 §9.16).
enum PriceTextVariant {
  /// Сетка каталога: `title 18/700`.
  grid,

  /// Список каталога: `bodyLg 16/700`.
  list,

  /// Компакт-строка: `body 14/700`.
  compact,

  /// Карточка товара: `h2 24/700`.
  card,
}

/// Единое отображение цены `PriceText` (03 §9.16, §16.4; D-19): сумма `tnum 700` `primaryText`
/// + «сом» (вес 500) → единица «/ шт» `caption textSecondary`. Значение — целые тыйыны сервера,
/// клиент цену не вычисляет (D-23); `double` не используется.
///
/// Нет цены (`amount == null`) — [missingLabel] («Цена не указана») `textSecondary`.
class PriceText extends StatelessWidget {
  /// Создаёт цену.
  const PriceText({
    super.key,
    required this.amount,
    this.unit,
    this.prefix,
    this.variant = PriceTextVariant.grid,
    this.missingLabel,
    this.disabled = false,
    this.semanticLabel,
  });

  /// Сумма; `null` — цены нет.
  final Money? amount;

  /// Подпись единицы («/ шт») — уже локализованная строка.
  final String? unit;

  /// Обёртка суммы («от {price}» для товара с вариантами разной цены, Q-206).
  final String Function(String formatted)? prefix;

  /// Вариант.
  final PriceTextVariant variant;

  /// Текст при отсутствии цены (`ds_price_missing`).
  final String? missingLabel;

  /// Товар недоступен — `textSecondary`.
  final bool disabled;

  /// Читаемая форма для screen reader («2 350 сом за штуку»).
  final String? semanticLabel;

  /// Обозначение валюты в UI (03 §16.4: «сом»; код `KGS` — только API). Часть формата
  /// `DsMoneyFormat` (03 §17.1), а не строка ARB — см. E_spec_questions EQ-CAT-03.
  static const String currency = 'сом';

  /// Узкий неразрывный пробел — разделитель разрядов (03 §16.4).
  static const String groupSeparator = ' ';

  /// Сумма без валюты: «2 350», «16 007,50», «−842,50» (минус U+2212). Тыйыны — при ненулевой
  /// дробной части или [fixed2] (финансовые контексты, Q-108).
  static String formatAmount(Money money, {bool fixed2 = false}) {
    final int value = money.tyiyn;
    final int abs = value.abs();
    final String som = (abs ~/ 100).toString();
    final int tyiyn = abs % 100;
    final StringBuffer grouped = StringBuffer();
    for (int i = 0; i < som.length; i++) {
      if (i > 0 && (som.length - i) % 3 == 0) {
        grouped.write(groupSeparator);
      }
      grouped.write(som[i]);
    }
    final String fraction = tyiyn != 0 || fixed2 ? ',${tyiyn.toString().padLeft(2, '0')}' : '';
    return '${value < 0 ? '−' : ''}$grouped$fraction';
  }

  /// Сумма с валютой через NBSP: «2 350 сом».
  static String format(Money money, {bool fixed2 = false}) => '${formatAmount(money, fixed2: fixed2)} $currency';

  /// Дробная денежная единица для чтения вслух (часть формата `DsMoneyFormat`, как [currency]).
  static const String subunit = 'тыйын';

  /// Сумма для экранного диктора: «16 007 сом 50 тыйын», «4 700 сом» (02 AC-UI-20-002, 03 A11Y-020) — без
  /// запятой, которую диктор читает как «запятая».
  static String spoken(Money money) {
    final int value = money.tyiyn;
    final String som = formatAmount(Money((value.abs() ~/ 100) * 100)).replaceAll(groupSeparator, ' ');
    final int tyiyn = value.abs() % 100;
    return '${value < 0 ? '−' : ''}$som $currency${tyiyn == 0 ? '' : ' $tyiyn $subunit'}';
  }

  TextStyle _amountStyle(BuildContext context) {
    final DsTypography t = context.text;
    final TextStyle base = switch (variant) {
      PriceTextVariant.grid => t.title,
      PriceTextVariant.list => t.bodyLg,
      PriceTextVariant.compact => t.body,
      PriceTextVariant.card => t.h2,
    };
    return t.priceOf(base);
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Money? value = amount;
    if (value == null) {
      return Text(
        missingLabel ?? '—',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.text.caption.copyWith(color: c.textSecondary),
      );
    }
    final Color color = disabled ? c.textSecondary : c.primaryText;
    final TextStyle amountStyle = _amountStyle(context).copyWith(color: color);
    final String formatted = format(value);
    final String shown = prefix?.call(formatted) ?? formatted;
    final String readable = shown.replaceAll(groupSeparator, '').replaceAll(' ', ' ');
    return Semantics(
      label: semanticLabel ?? (unit == null ? readable : '$readable $unit'),
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(text: shown, style: amountStyle),
            if (unit != null && unit!.isNotEmpty)
              TextSpan(
                text: ' $unit',
                style: context.text.caption.copyWith(color: c.textSecondary),
              ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
      ),
    );
  }
}

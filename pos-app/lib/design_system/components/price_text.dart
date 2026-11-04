import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Варианты `PriceText` (03 §9.16).
enum PriceTextVariant {
  /// Сетка каталога: `catalogPrice 18/800`, межбуквенный −0,2 (прототип, ADR-114).
  grid,

  /// Список каталога: `listPrice 17/800` (прототип, ADR-114).
  list,

  /// Компакт-строка и таблица «Компакт»: `compactPrice 14/800` (прототип, ADR-114).
  compact,

  /// Карточка товара: `h2 24/700` tnum.
  card,
}

/// Единое отображение цены `PriceText` (03 §9.16, §16.4; D-19). Значение — целые тыйыны сервера, клиент цену не
/// вычисляет (D-23); `double` не используется. Формат — как `money()` прототипа (ADR-114): всегда 2 знака, разряды —
/// неразрывный пробел U+00A0, перед «сом» — NBSP: «10 450,00 сом».
///
/// Сумма — `primaryText`: в каталоге стили прототипа без tnum (`grid` 18/800, `list` 17/800, `compact` 14/800), в
/// карточке товара — `h2 700` tnum; единица «/ шт» — `meta 13/400 catalogMeta` (у `compact` — `sku 12`, у `card` —
/// `caption textSecondary`). [wrapUnit] — единица отдельным блоком через зазор 4 с переносом на вторую строку, если
/// «цена / шт» не помещается (карточка сетки, прототип: `flex-wrap`, `gap: 4px`).
///
/// Для экранного диктора — [spoken]: «10 450 сом», «16 007 сом 50 тыйын» (без «запятой» и нулевых тыйынов; ADR-114
/// п. 4, A11Y-020, T-DS-103), у вариантов — с «от».
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
    this.unitStyle,
    this.wrapUnit = false,
    this.alignEnd = false,
    this.allowUnitLine = true,
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

  /// Своя подпись для screen reader («2 350 сом за штуку»); по умолчанию — [spoken] с единицей.
  final String? semanticLabel;

  /// Стиль единицы «/ шт»; по умолчанию — по [variant] (каталог — `meta 13/400 catalogMeta`).
  final TextStyle? unitStyle;

  /// Единица — отдельным блоком через зазор 4; не помещается рядом с суммой — на второй строке (сумма при нехватке
  /// ширины уменьшается). Иначе — одна строка с затуханием.
  final bool wrapUnit;

  /// При переносе [wrapUnit] обе строки — у конца (колонка цены строки списка, прототип: `text-align: right`).
  final bool alignEnd;

  /// [wrapUnit]: единице можно уйти на вторую строку; `false` — места под вторую строку нет (карточка сетки высотой
  /// 340, ревью RC-11), и «цена / шт» уменьшается целиком в одну строку (`scaleDown`), а не сжимает название.
  final bool allowUnitLine;

  /// Обозначение валюты в UI (03 §16.4: «сом»; код `KGS` — только API). Часть формата
  /// `DsMoneyFormat` (03 §17.1), а не строка ARB — см. E_spec_questions EQ-CAT-03.
  static const String currency = 'сом';

  /// Неразрывный пробел U+00A0 — разделитель разрядов (03 §16.4 ред. 1.18, `money()` прототипа; до ADR-114 — U+202F).
  static const String groupSeparator = ' ';

  /// Сумма без валюты: «2 350,00», «16 007,50», «−842,50» (минус U+2212). Всегда 2 знака (ADR-114); [fixed2] `false` —
  /// тыйыны только при ненулевой дробной части (чтение вслух, [spoken], [readable]).
  static String formatAmount(Money money, {bool fixed2 = true}) {
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

  /// Сумма с валютой через NBSP: «2 350,00 сом».
  static String format(Money money, {bool fixed2 = true}) => '${formatAmount(money, fixed2: fixed2)} $currency';

  /// Дробная денежная единица для чтения вслух (часть формата `DsMoneyFormat`, как [currency]).
  static const String subunit = 'тыйын';

  /// Сумма для экранного диктора: «16 007 сом 50 тыйын», «4 700 сом» (02 AC-UI-20-002, 03 A11Y-020) — без
  /// запятой, которую диктор читает как «запятая», и без нулевых тыйынов.
  static String spoken(Money money) {
    final int value = money.tyiyn;
    final String som = formatAmount(Money((value.abs() ~/ 100) * 100), fixed2: false).replaceAll(groupSeparator, ' ');
    final int tyiyn = value.abs() % 100;
    return '${value < 0 ? '−' : ''}$som $currency${tyiyn == 0 ? '' : ' $tyiyn $subunit'}';
  }

  /// Сумма без разрядов и без нулевых тыйынов — «2350 сом», «16007,50 сом» (прежняя форма подписи `Semantics` до
  /// ADR-114; подпись виджета и карточки каталога теперь — [spoken]).
  static String readable(Money money) =>
      '${formatAmount(money, fixed2: false).replaceAll(groupSeparator, '')} $currency';

  TextStyle _amountStyle(BuildContext context) {
    final DsTypography t = context.text;
    return switch (variant) {
      PriceTextVariant.grid => t.catalogPrice,
      PriceTextVariant.list => t.listPrice,
      PriceTextVariant.compact => t.compactPrice,
      PriceTextVariant.card => t.priceOf(t.h2),
    };
  }

  TextStyle _unitStyle(BuildContext context) {
    final DsColors c = context.colors;
    return unitStyle ??
        switch (variant) {
          PriceTextVariant.grid || PriceTextVariant.list => context.text.meta.copyWith(color: c.catalogMeta),
          PriceTextVariant.compact => context.text.sku.copyWith(color: c.catalogMeta),
          PriceTextVariant.card => context.text.caption.copyWith(color: c.textSecondary),
        };
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
    // Диктор: «10 450 сом», «16 007 сом 50 тыйын» (ADR-114 п. 4, 03 §16.4, A11Y-020) — без «запятой» и нулевых тыйынов.
    final String spokenAmount = spoken(value);
    final String a11y = (prefix?.call(spokenAmount) ?? spokenAmount).replaceAll(' ', ' ');
    final String? u = unit == null || unit!.isEmpty ? null : unit;
    final Widget body = wrapUnit && u != null
        ? _Wrapped(
            amount: shown,
            unit: u,
            amountStyle: amountStyle,
            unitStyle: _unitStyle(context),
            alignEnd: alignEnd,
            allowUnitLine: allowUnitLine,
          )
        : Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: shown, style: amountStyle),
                if (u != null) TextSpan(text: ' $u', style: _unitStyle(context)),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
          );
    return Semantics(label: semanticLabel ?? (u == null ? a11y : '$a11y $u'), excludeSemantics: true, child: body);
  }
}

/// Сумма и единица блоками через зазор `space.s1` (4) по базовой линии; не помещаются в строку — единица на второй
/// строке под суммой (зазор строк 4), сумма при нехватке ширины уменьшается (`scaleDown`, AC-UI-10-005). Без
/// [allowUnitLine] — строка «сумма / шт» уменьшается целиком.
class _Wrapped extends StatelessWidget {
  const _Wrapped({
    required this.amount,
    required this.unit,
    required this.amountStyle,
    required this.unitStyle,
    required this.alignEnd,
    required this.allowUnitLine,
  });

  final String amount;
  final String unit;
  final TextStyle amountStyle;
  final TextStyle unitStyle;
  final bool alignEnd;
  final bool allowUnitLine;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final double gap = context.space.s1;
      final Widget amountText = Text(amount, maxLines: 1, softWrap: false, style: amountStyle);
      final Widget unitText = Text(unit, maxLines: 1, softWrap: false, style: unitStyle);
      final double need = dsTextWidth(context, amount, amountStyle) + gap + dsTextWidth(context, unit, unitStyle);
      final Widget line = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          amountText,
          SizedBox(width: gap),
          unitText,
        ],
      );
      if (!box.hasBoundedWidth || need <= box.maxWidth) {
        return line;
      }
      if (!allowUnitLine) {
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignEnd ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
          child: line,
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: alignEnd ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
            child: amountText,
          ),
          SizedBox(height: gap),
          unitText,
        ],
      );
    },
  );
}

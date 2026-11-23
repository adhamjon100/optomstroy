import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_hairline.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/layout/title_trailing_bar.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Состояние строки `CartLine` (02 UI-20-006, UI-20-011; 03 §9.28).
enum CartLineTone {
  /// Обычная строка.
  normal,

  /// Цена изменилась — фон `warningContainer`.
  warning,

  /// Недостаточный остаток / отказ — полоса слева 3 lp `error`.
  error,

  /// Товар больше не продаётся — приглушена.
  unavailable,
}

/// Строка позиции корзины `CartLine` (03 §9.28): высота 64/72, паддинг 12 → `ProductImage` 48 (thumb) → колонка:
/// название `body 14/500` (2 строки; [dense] — 1), [variantLabel], [subtitle] «Арт. F4252 · 2 350 сом/шт»
/// `caption textSecondary tnum`, [message] (иконка + текст, A11Y-004) и [actions] → [quantity] (степпер
/// вызывающего) → сумма строки `bodyLg 16/700 textPrimary` (ширина ≥ 88; [preliminary] — «≈» `textSecondary`,
/// [pending] — индикатор 16) → `AppIconButton close 20` «Удалить» (цель 44).
///
/// [emphasized] — строка drawer корзины по прототипу без округления (ADR-114 п. 6; design-spec §13): поля 20 по бокам
/// и 12 по вертикали, разделитель `rowDivider` #EEF2F8 внутри полей; бокс фото 54×48 (`contain`, без фото — пустой);
/// через 12 — название 13/600 `catalogName` (строка 1,3), справа крестик «Удалить» 28×28 (радиус 8, глиф 14
/// `catalogMeta` линией 2,4); через 8 — степпер ([quantity], группа 102×34) и сумма строки `lineSum` 15/800
/// `textPrimary` без `tnum`. Высота строки с названием в одну строку — 95. Цели касания крестика и степпера — 44,
/// за счёт полей строки, без изменения вида (A11Y-003; [stepperInset]). [variantLabel], [subtitle] «Арт. … · 10 450,00 сом / шт»
/// (`textSecondary`; в прототипе их нет — паритет функций), [message] и [actions] — под названием и под степпером.
///
/// Сумма строки — только ответ сервера (D-23): компонент её не вычисляет.
class CartLine extends StatelessWidget {
  /// Создаёт строку.
  const CartLine({
    super.key,
    required this.title,
    required this.quantity,
    required this.removeLabel,
    this.subtitle,
    this.subtitleSemanticLabel,
    this.variantLabel,
    this.onVariantTap,
    this.variantActionLabel,
    this.imageUrl,
    this.lineTotal,
    this.preliminary = false,
    this.pending = false,
    this.tone = CartLineTone.normal,
    this.message,
    this.messageIcon,
    this.actions = const <Widget>[],
    this.onOpen,
    this.onRemove,
    this.selected = false,
    this.dense = false,
    this.emphasized = false,
    this.semanticLabel,
    this.stepperInset = 0,
  });

  /// Название товара.
  final String title;

  /// «Хром · 1/2"».
  final String? variantLabel;

  /// Тап по подписи варианта — смена варианта (02 UI-20-007, `AppButton.text S` «Хром · 1/2" ›», CART-005);
  /// `null` — подпись только текстом.
  final VoidCallback? onVariantTap;

  /// Подпись действия для экранного диктора («Заменить вариант»).
  final String? variantActionLabel;

  /// «Арт. F4252 · 2 350 сом/шт».
  final String? subtitle;

  /// Подпись [subtitle] для экранного диктора — суммы в форме `PriceText.spoken` («Арт. F4252 · 2 350 сом / шт», без
  /// «запятой» и нулевых тыйынов; ADR-114 п. 4, A11Y-020); `null` — читается видимый текст.
  final String? subtitleSemanticLabel;

  /// Миниатюра (thumb); `null` — заглушка.
  final String? imageUrl;

  /// Степпер количества (или «2 шт» в `readonly`).
  final Widget quantity;

  /// Сумма строки сервера; `null` — «—».
  final Money? lineTotal;

  /// Сумма не подтверждена сервером (изменение ещё не отправлено) — «≈» и `textSecondary`.
  final bool preliminary;

  /// Изменение отправляется — индикатор 16 у суммы.
  final bool pending;

  /// Предупреждение строки.
  final CartLineTone tone;

  /// Текст предупреждения («Цена изменилась: было 2 350 → стало 2 410 сом»).
  final String? message;

  /// Иконка предупреждения (по умолчанию — по [tone]).
  final IconData? messageIcon;

  /// Действия под предупреждением («Уменьшить до 3», «Удалить позицию»).
  final List<Widget> actions;

  /// Тап по фото/названию — карточка товара.
  final VoidCallback? onOpen;

  /// Крестик; `null` — скрыт (`readonly`) или недоступен.
  final VoidCallback? onRemove;

  /// «Удалить».
  final String removeLabel;

  /// Выбрана клавиатурой (↑/↓) — кольцо `focus` inset.
  final bool selected;

  /// expanded: название в одну строку, высота 64.
  final bool dense;

  /// Drawer корзины: название `body 600`, сумма строки `body 700`.
  final bool emphasized;

  /// «Смеситель Frap F4252, 2 штуки, 4 700 сом».
  final String? semanticLabel;

  /// Строка drawer ([emphasized]): невидимое поле целей касания слева от видимой части [quantity] (степпер-группа —
  /// `QuantityStepper.groupOuterInset`). Колонка названия и степпера начинается раньше на это поле, видимая обводка
  /// степпера и название — в 12 от фото, как в прототипе.
  final double stepperInset;

  /// Бокс фото строки drawer (прототип: 54×48, `object-fit: contain`).
  static const Size drawerPhoto = Size(54, 48);

  /// Сторона видимого крестика «Удалить» строки drawer (прототип: 28×28, радиус 8).
  static const double drawerRemoveSize = 28;

  /// Цель касания крестика строки drawer (03 §7.4): 44 × 44, видимый крестик — в её правом верхнем углу со сдвигом 8
  /// вниз, цель заходит в верхнее поле строки.
  static const double drawerRemoveTarget = 44;

  /// [subtitle] с подписью для диктора [subtitleSemanticLabel] (ревью R2C-04).
  Widget _spoken(Widget text) {
    final String? label = subtitleSemanticLabel;
    return label == null ? text : Semantics(label: label, excludeSemantics: true, child: text);
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool unavailable = tone == CartLineTone.unavailable;
    final Color bg = tone == CartLineTone.warning ? c.warningContainer : c.surface;
    final Color messageColor = switch (tone) {
      CartLineTone.warning => c.warning,
      CartLineTone.error => c.error,
      CartLineTone.unavailable || CartLineTone.normal => c.textSecondary,
    };
    final IconData icon =
        messageIcon ??
        switch (tone) {
          CartLineTone.warning => Icons.warning_amber_rounded,
          CartLineTone.error => Icons.error_outline_rounded,
          CartLineTone.unavailable => Icons.block_rounded,
          CartLineTone.normal => Icons.info_outline_rounded,
        };
    final Money? total = lineTotal;
    // Сумма строки — одним кеглем во всех строках (`body 700` в drawer — прототип 15/800 по шкале 03 §7.1, иначе
    // `bodyLg 700`): поле не уже 88 для выравнивания столбца. Не помещается рядом со степпером (телефон, крупный
    // текст) — строкой ниже у конца строки целиком, а не уменьшается (T-UI-117, пакет own-server:GAP-APP;
    // `TitleTrailingBar`); `FittedBox` — только защита, если сумма шире всей строки.
    final Color totalColor = preliminary || unavailable ? c.textSecondary : c.textPrimary;
    // Drawer (прототип): `lineSum` 15/800 без `tnum` (ADR-114 п. 6); иначе — `bodyLg 700 tnum`.
    final TextStyle totalStyle = emphasized
        ? context.text.lineSum.copyWith(color: totalColor)
        : context.text.priceOf(context.text.bodyLg).copyWith(fontWeight: FontWeight.w700, color: totalColor);
    final Widget sum = ConstrainedBox(
      constraints: BoxConstraints(minWidth: emphasized ? 0 : 88),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          if (pending) ...<Widget>[const AppProgress.circular(size: 16), SizedBox(width: context.space.s1)],
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                // Финансовая сумма — 2 знака, как итоги корзины и строки SCR-21 (03 Q-108).
                total == null ? '—' : '${preliminary ? '≈ ' : ''}${PriceText.format(total, fixed2: true)}',
                maxLines: 1,
                style: totalStyle,
              ),
            ),
          ),
        ],
      ),
    );
    if (emphasized) {
      return _drawerLine(context, c, sum: sum, icon: icon, messageColor: messageColor, unavailable: unavailable);
    }
    final Widget info = DsInteractive(
      onTap: onOpen,
      enabled: onOpen != null,
      builder: (BuildContext context, DsInteractionState st) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Opacity(
            opacity: unavailable ? 0.5 : 1,
            child: ProductImage(url: imageUrl, dimension: 48, borderRadius: BorderRadius.all(context.radii.sm)),
          ),
          SizedBox(width: context.space.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: dense ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.body.copyWith(
                    fontWeight: FontWeight.w500,
                    color: unavailable ? c.textSecondary : c.textPrimary,
                    decoration: st.hovered ? TextDecoration.underline : null,
                  ),
                ),
                if (variantLabel != null)
                  if (onVariantTap == null && variantActionLabel == null)
                    Text(
                      variantLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.caption.copyWith(color: c.primaryText),
                    )
                  else
                    _VariantLink(label: variantLabel!, actionLabel: variantActionLabel, onTap: onVariantTap),
                if (subtitle != null)
                  _spoken(
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.caption.copyWith(
                        color: c.textSecondary,
                        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final Widget body = Padding(
      padding: EdgeInsets.all(context.space.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: info),
              if (onRemove != null || removeLabel.isNotEmpty)
                AppIconButton(
                  icon: Icons.close_rounded,
                  iconSize: 20,
                  small: true,
                  semanticLabel: removeLabel,
                  onPressed: onRemove,
                ),
            ],
          ),
          SizedBox(height: context.space.s2),
          LayoutBuilder(
            // Узкая панель (overlay 320): степпер без отступа под миниатюрой.
            builder: (BuildContext context, BoxConstraints box) => Row(
              children: <Widget>[
                if (box.maxWidth >= 320) SizedBox(width: 48 + context.space.s3),
                Expanded(
                  child: TitleTrailingBar(
                    spacing: context.space.s2,
                    overflowSpacing: context.space.s1,
                    title: quantity,
                    trailing: sum,
                  ),
                ),
              ],
            ),
          ),
          if (message != null) ...<Widget>[
            SizedBox(height: context.space.s2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(icon, size: 16, color: messageColor),
                SizedBox(width: context.space.s1),
                Expanded(
                  child: Text(message!, style: context.text.caption.copyWith(color: messageColor)),
                ),
              ],
            ),
          ],
          if (actions.isNotEmpty) Wrap(spacing: context.space.s2, children: actions),
        ],
      ),
    );
    final Widget line = Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          bottom: BorderSide(color: c.border),
          left: tone == CartLineTone.error ? BorderSide(color: c.error, width: 3) : BorderSide.none,
        ),
      ),
      foregroundDecoration: selected ? BoxDecoration(border: Border.all(color: c.focus, width: 2)) : null,
      child: body,
    );
    return Semantics(container: true, label: semanticLabel, child: line);
  }

  /// Строка drawer корзины по прототипу (см. [emphasized]). Цели касания 44 не меняют вида: степпер-группа занимает
  /// 44 по высоте (видимая часть 34 — по центру), поэтому зазор над ней 3 и нижнее поле 7 вместо 8 и 12; колонка
  /// названия и степпера начинается раньше на [stepperInset] (поле цели «−»), название — с тем же отступом; крестик
  /// лежит поверх строки ([drawerRemoveTarget] в правом верхнем углу), название оставляет ему 28 + 8.
  Widget _drawerLine(
    BuildContext context,
    DsColors c, {
    required Widget sum,
    required IconData icon,
    required Color messageColor,
    required bool unavailable,
  }) {
    final bool error = tone == CartLineTone.error;
    final String? url = imageUrl;
    // Прототип: без фото — пустой бокс 54×48.
    final Widget photo = SizedBox.fromSize(
      size: drawerPhoto,
      child: url == null || url.isEmpty
          ? null
          : Opacity(
              opacity: unavailable ? 0.5 : 1,
              child: ProductImage(
                url: url,
                dimension: drawerPhoto.width,
                height: drawerPhoto.height,
                background: Colors.transparent,
                borderRadius: BorderRadius.zero,
                showPlaceholderLabel: false,
              ),
            ),
    );
    final Widget name = DsInteractive(
      onTap: onOpen,
      enabled: onOpen != null,
      builder: (BuildContext context, DsInteractionState st) => Text(
        title,
        maxLines: dense ? 1 : 2,
        overflow: TextOverflow.ellipsis,
        // 13/600 #16206A, строка 1,3 (прототип).
        style: context.text.label.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: unavailable ? c.textSecondary : c.catalogName,
          decoration: st.hovered ? TextDecoration.underline : null,
        ),
      ),
    );
    final Widget nameBlock = Padding(
      padding: EdgeInsetsDirectional.only(start: stepperInset, end: drawerRemoveSize + _drawerNameGap),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: drawerRemoveSize),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            name,
            if (variantLabel != null)
              if (onVariantTap == null && variantActionLabel == null)
                Text(
                  variantLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.caption.copyWith(color: c.primaryText),
                )
              else
                _VariantLink(label: variantLabel!, actionLabel: variantActionLabel, onTap: onVariantTap),
            if (subtitle != null)
              _spoken(
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // Нет в прототипе (паритет функций): `textSecondary`, как подписи компакт-строк (RC-07).
                  style: context.text.caption.copyWith(color: c.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        nameBlock,
        const SizedBox(height: _drawerStepperGap),
        // Сумма не помещается рядом со степпером — строкой ниже у конца, целиком (см. `sum` в [build]).
        TitleTrailingBar(spacing: context.space.s2, overflowSpacing: context.space.s1, title: quantity, trailing: sum),
        if (message != null) ...<Widget>[
          SizedBox(height: context.space.s1),
          Padding(
            padding: EdgeInsetsDirectional.only(start: stepperInset),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(icon, size: 16, color: messageColor),
                SizedBox(width: context.space.s1),
                Expanded(
                  child: Text(message!, style: context.text.caption.copyWith(color: messageColor)),
                ),
              ],
            ),
          ),
        ],
        if (actions.isNotEmpty)
          Padding(
            padding: EdgeInsetsDirectional.only(start: stepperInset),
            child: Wrap(spacing: context.space.s2, children: actions),
          ),
      ],
    );
    final Widget content = Padding(
      // Прототип: `padding: 12px 0` — нижнее поле 12 минус невидимые 5 под степпером (цель 44, вид 34).
      padding: EdgeInsetsDirectional.only(
        start: error ? context.space.s2 : 0,
        top: _drawerPadTop,
        bottom: _drawerPadBottom,
      ),
      // Колонка начинается в 12 − [stepperInset] от фото (поле цели «−» заходит в зазор и на 3 lp под фото); фото
      // рисуется и принимает касания поверх этого края.
      child: Stack(
        children: <Widget>[
          Padding(
            padding: EdgeInsetsDirectional.only(start: drawerPhoto.width + _drawerPhotoGap - stepperInset),
            child: column,
          ),
          PositionedDirectional(
            start: 0,
            top: 0,
            child: DsInteractive(
              onTap: onOpen,
              enabled: onOpen != null,
              // Фото и название ведут в карточку товара; в обходе Tab — только название.
              canRequestFocus: false,
              builder: (BuildContext context, DsInteractionState st) => photo,
            ),
          ),
        ],
      ),
    );
    final bool canRemove = onRemove != null || removeLabel.isNotEmpty;
    final Widget line = Container(
      decoration: BoxDecoration(
        color: tone == CartLineTone.warning ? c.warningContainer : c.surface,
        border: Border(
          bottom: DsHairline.side(context, c.rowDivider),
          left: error ? BorderSide(color: c.error, width: 3) : BorderSide.none,
        ),
      ),
      foregroundDecoration: selected ? BoxDecoration(border: Border.all(color: c.focus, width: 2)) : null,
      child: Stack(
        children: <Widget>[
          content,
          if (canRemove)
            PositionedDirectional(
              top: _drawerPadTop - (drawerRemoveTarget - drawerRemoveSize) / 2,
              end: 0,
              child: _DrawerRemoveButton(label: removeLabel, onPressed: onRemove),
            ),
        ],
      ),
    );
    return Semantics(
      container: true,
      label: semanticLabel,
      child: ColoredBox(
        color: c.surface,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s5),
          child: line,
        ),
      ),
    );
  }

  /// Верхнее поле строки drawer (прототип: 12).
  static const double _drawerPadTop = 12;

  /// Нижнее поле строки drawer: 12 прототипа минус 5 невидимых под степпером (цель 44, видимая часть 34).
  static const double _drawerPadBottom = 7;

  /// Зазор фото и колонки (прототип: `gap: 12px`).
  static const double _drawerPhotoGap = 12;

  /// Зазор названия и крестика (прототип: `gap: 8px`).
  static const double _drawerNameGap = 8;

  /// Зазор над строкой степпера: 8 прототипа минус 5 невидимых над степпером.
  static const double _drawerStepperGap = 3;
}

/// Подпись варианта как ссылка «Хром · 1/2" ›» (UI-20-007): цель нажатия ≥ 44 lp по высоте (A11Y-003),
/// disabled (`onTap == null`, офлайн) — `disabledText`.
class _VariantLink extends StatelessWidget {
  const _VariantLink({required this.label, required this.onTap, this.actionLabel});

  final String label;
  final String? actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: actionLabel == null ? label : '$label, $actionLabel',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey<String>('cart-line-variant'),
        onTap: onTap,
        borderRadius: BorderRadius.all(context.radii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            child: Text(
              '$label ›',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.caption.copyWith(
                color: enabled ? c.primaryText : c.disabledText,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Крестик «Удалить» строки drawer корзины (прототип): видимый квадрат 28×28 с радиусом `sm` 8, прозрачный (наведение
/// — `surfaceHover`, нажатие — `iconButtonPressed`), крест 14 `catalogMeta` линией 2,4; цель касания 44 × 44 — видимый
/// квадрат в её правом верхнем углу со сдвигом 8 вниз (A11Y-003); фокус — кольцо `focus`, тултип — подпись.
class _DrawerRemoveButton extends StatelessWidget {
  const _DrawerRemoveButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    const double inset = (CartLine.drawerRemoveTarget - CartLine.drawerRemoveSize) / 2;
    final Widget button = Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: DsInteractive(
        key: const ValueKey<String>('cart-line-remove'),
        enabled: onPressed != null,
        onTap: onPressed,
        builder: (BuildContext context, DsInteractionState s) => SizedBox.square(
          dimension: CartLine.drawerRemoveTarget,
          child: Align(
            alignment: AlignmentDirectional.topEnd,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(top: inset),
              child: DsFocusRing(
                visible: s.focused,
                borderRadius: radius,
                child: Container(
                  width: CartLine.drawerRemoveSize,
                  height: CartLine.drawerRemoveSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: s.pressed ? c.iconButtonPressed : (s.hovered ? c.surfaceHover : Colors.transparent),
                    borderRadius: radius,
                  ),
                  child: DsGlyph(
                    kind: DsGlyphKind.cross,
                    size: 14,
                    strokeWidth: 2.4,
                    color: s.enabled ? c.catalogMeta : c.disabledText,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return label.isEmpty ? button : AppTooltip(message: label, child: button);
  }
}

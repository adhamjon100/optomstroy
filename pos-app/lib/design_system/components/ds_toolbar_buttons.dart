// Кнопки контекстного меню поля шрифтом приложения (03 §16.5; 15 ADR-113 п. 1, уточнение 2026-11-08).
//
// Кнопки меню Flutter на Windows, Linux, macOS и iOS (`DesktopTextSelectionToolbarButton.text`,
// `CupertinoDesktopTextSelectionToolbarButton.text`, `CupertinoTextSelectionToolbarButton.buttonItem`) рисуют подпись
// стилем `TextStyle(inherit: false)` без семейства шрифта, на Android — стилем кнопки без семейства. В веб-сборке движок проверяет такой текст по пустому
// списку шрифтов, считает кириллицу «Вырезать / Копировать / Вставить / Выделить всё» непокрытой и запрашивает
// запасной шрифт Noto Sans SC с адреса сайта (`fontFallbackBaseUrl`) — в веб-демо это ответ 404 (шрифта на сайте нет,
// подпись при этом рисуется Roboto). Здесь — те же кнопки, тех же размеров и цветов, но с семейством Inter
// (`DsTypography.fontFamily`), поэтому запасной шрифт не нужен. На Android кнопка Flutter
// (`TextSelectionToolbarTextButton`) задаёт свой стиль текста без семейства — там тоже добавлено Inter.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Кнопки меню [items] для `AdaptiveTextSelectionToolbar(children: …)` — как
/// `AdaptiveTextSelectionToolbar.getAdaptiveButtons`, но подписи шрифтом приложения.
List<Widget> dsToolbarButtons(BuildContext context, List<ContextMenuButtonItem> items) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
      // `TextSelectionToolbarTextButton` задаёт кнопке свой `textStyle` (только вес 400) — семейство из темы до
      // подписи не доходит; здесь его добавляет `Text` (остальное — от кнопки).
      return <Widget>[
        for (int i = 0; i < items.length; i++)
          TextSelectionToolbarTextButton(
            padding: TextSelectionToolbarTextButton.getPadding(i, items.length),
            onPressed: items[i].onPressed,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              AdaptiveTextSelectionToolbar.getButtonLabel(context, items[i]),
              style: const TextStyle(fontFamily: DsTypography.fontFamily),
            ),
          ),
      ];
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      final Color color = Theme.of(context).colorScheme.brightness == Brightness.dark ? Colors.white : Colors.black87;
      return <Widget>[
        for (final ContextMenuButtonItem item in items)
          DesktopTextSelectionToolbarButton(
            onPressed: item.onPressed,
            child: Text(
              AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
              overflow: TextOverflow.ellipsis,
              style: _desktopLabel.copyWith(color: color),
            ),
          ),
      ];
    case TargetPlatform.macOS:
      return <Widget>[for (final ContextMenuButtonItem item in items) _MacToolbarButton(item: item)];
    case TargetPlatform.iOS:
      final Color color = const CupertinoDynamicColor.withBrightness(
        color: CupertinoColors.black,
        darkColor: CupertinoColors.white,
      ).resolveFrom(context);
      return <Widget>[
        for (final ContextMenuButtonItem item in items)
          // «Live Text» — значок без подписи: кнопка Flutter как есть.
          if (item.type == ContextMenuButtonType.liveTextInput)
            CupertinoTextSelectionToolbarButton.buttonItem(buttonItem: item)
          else
            CupertinoTextSelectionToolbarButton(
              onPressed: item.onPressed,
              child: Text(
                CupertinoTextSelectionToolbarButton.getButtonLabel(context, item),
                overflow: TextOverflow.ellipsis,
                style: _iosLabel.copyWith(color: item.onPressed != null ? color : CupertinoColors.inactiveGray),
              ),
            ),
      ];
  }
}

/// Подпись кнопки меню Windows, Linux и macOS — метрики Flutter (`_kToolbarButtonFontStyle`) и шрифт приложения.
const TextStyle _desktopLabel = TextStyle(
  inherit: false,
  fontFamily: DsTypography.fontFamily,
  fontSize: 14,
  letterSpacing: -0.15,
  fontWeight: FontWeight.w400,
);

/// Подпись кнопки меню iOS — метрики Flutter (`_kToolbarButtonFontStyle` Cupertino) и шрифт приложения.
const TextStyle _iosLabel = TextStyle(
  inherit: false,
  fontFamily: DsTypography.fontFamily,
  fontSize: 15,
  letterSpacing: -0.15,
  fontWeight: FontWeight.w400,
);

/// Кнопка меню macOS: при наведении подпись — `primaryContrastingColor` на заливке `primaryColor`, как у
/// `CupertinoDesktopTextSelectionToolbarButton.text`.
class _MacToolbarButton extends StatefulWidget {
  const _MacToolbarButton({required this.item});

  final ContextMenuButtonItem item;

  @override
  State<_MacToolbarButton> createState() => _MacToolbarButtonState();
}

class _MacToolbarButtonState extends State<_MacToolbarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: CupertinoDesktopTextSelectionToolbarButton(
      onPressed: widget.item.onPressed,
      child: Text(
        CupertinoTextSelectionToolbarButton.getButtonLabel(context, widget.item),
        overflow: TextOverflow.ellipsis,
        style: _desktopLabel.copyWith(
          color: _hovered
              ? CupertinoTheme.of(context).primaryContrastingColor
              : const CupertinoDynamicColor.withBrightness(
                  color: CupertinoColors.black,
                  darkColor: CupertinoColors.white,
                ).resolveFrom(context),
        ),
      ),
    ),
  );
}

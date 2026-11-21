import 'package:flutter/widgets.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

/// Предел ширины рабочего экрана на `large` (03 §8.5, §8.8; указание владельца 2026-11-18 «и экран нужно сделать
/// адаптивным… сделай всё это красиво», 15 §5.8 (3)): на окне ≥ 1600 lp содержимое экрана вне каталога — список,
/// таблица, карточка клиента — не шире `contentMaxLarge` (1200) плюс [sidePanel] (боковая панель экрана — фильтры,
/// сводка долга — остаётся рядом с контентом) и стоит по центру; остаток слева и справа — фон экрана. Уже 1600 lp и
/// при доступной ширине не больше предела ничего не меняется (раскладки compact, medium, expanded прежние). Шапка
/// экрана (`AppBar`) остаётся во всю ширину — предел ставится на тело.
class DsLargeContent extends StatelessWidget {
  /// Создаёт предел.
  const DsLargeContent({super.key, required this.child, this.sidePanel = 0});

  /// Тело экрана.
  final Widget child;

  /// Ширина боковой панели экрана, которая входит в предел (0 — панели нет).
  final double sidePanel;

  /// Предел ширины тела.
  double get maxWidth => DsBreakpoints.contentMaxLarge + sidePanel;

  @override
  Widget build(BuildContext context) {
    if (DsBreakpoints.of(context) != WindowClass.large) {
      return child;
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        if (!box.hasBoundedWidth || box.maxWidth <= maxWidth) {
          return child;
        }
        // Поля, а не `Center`: тело получает прежние (плотные) ограничения по высоте.
        final double side = (box.maxWidth - maxWidth) / 2; // money-double: allow — поле, lp
        return Padding(
          key: const ValueKey<String>('ds-large-content'),
          padding: EdgeInsets.symmetric(horizontal: side),
          child: child,
        );
      },
    );
  }
}

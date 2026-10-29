import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Счётчик результатов «Найдено: N» (02 UI-10-012, UI-11-003; `catalog_found_count`):
/// `caption textSecondary tnum`; смена значения — crossfade 200 мс (ANIM-010; reduce-motion —
/// мгновенно); `liveRegion` (polite). [text] `null` — скелетон 120×16.
///
/// [toolbar] — строка управления каталога medium+ (прототип 2026-10-29): `label 13 textTertiary`, одна строка.
class FoundCountText extends StatelessWidget {
  /// Создаёт счётчик.
  const FoundCountText({super.key, required this.text, this.toolbar = false});

  /// Локализованный текст («Найдено: 124 товара»); `null` — загрузка.
  final String? text;

  /// Вид строки управления (одна строка, `label textTertiary`).
  final bool toolbar;

  @override
  Widget build(BuildContext context) {
    final String? t = text;
    if (t == null) {
      return const SkeletonBox(width: 120, height: 16);
    }
    return Semantics(
      liveRegion: true,
      child: AnimatedSwitcher(
        duration: context.motion.of(context.motion.base),
        layoutBuilder: (Widget? current, List<Widget> previous) =>
            Stack(alignment: AlignmentDirectional.centerStart, children: <Widget>[...previous, ?current]),
        child: Text(
          t,
          key: ValueKey<String>(t),
          // Узкая строка инструментов (compact): перенос на вторую строку вместо обрезки числа (02 SCR-10.2).
          maxLines: toolbar ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: toolbar
              ? context.text.label.copyWith(color: context.colors.textTertiary, fontFeatures: DsTypography.numeric)
              : context.text.caption.copyWith(color: context.colors.textSecondary, fontFeatures: DsTypography.numeric),
        ),
      ),
    );
  }
}

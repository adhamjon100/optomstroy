// Карточка последнего результата SCR-17 (UI-17-005, -011, -012, -013, -014): `surface`,
// радиус `ds.radius.md`, `ds.elevation.2`, поля 16; тон `error` — «не найдено» (UI-17-012),
// `info` — тест/несколько вариантов. Появление — ANIM-027 (slide-up 8 lp + fade 150 мс;
// reduce motion — fade 80 мс).
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Тон карточки.
enum ScanResultTone {
  /// Обычная (`surface`).
  neutral,

  /// Успех (добавлено/распознано).
  success,

  /// Информация (тест, несколько вариантов).
  info,

  /// Ошибка (`errorContainer`/`error`).
  error,
}

/// Действие карточки.
final class ScanResultAction {
  /// Создаёт действие.
  const ScanResultAction(this.label, this.onPressed, {this.key});

  /// Подпись.
  final String label;

  /// Нажатие.
  final VoidCallback onPressed;

  /// Ключ кнопки (тесты).
  final Key? key;
}

/// Карточка результата скана.
class ScanResultCard extends StatelessWidget {
  /// Создаёт карточку.
  const ScanResultCard({
    super.key,
    required this.title,
    this.subtitle,
    this.note,
    this.tone = ScanResultTone.neutral,
    this.loading = false,
    this.actions = const <ScanResultAction>[],
  });

  /// Заголовок (название товара / сообщение).
  final String title;

  /// Вторая строка (артикул · код).
  final String? subtitle;

  /// Пометка («Поиск по сохранённому каталогу от …»).
  final String? note;

  /// Тон.
  final ScanResultTone tone;

  /// Идёт запрос.
  final bool loading;

  /// Действия.
  final List<ScanResultAction> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final s = context.space;
    final (Color bg, Color fg) = switch (tone) {
      ScanResultTone.neutral => (c.surface, c.textPrimary),
      ScanResultTone.success => (c.successContainer, c.textPrimary),
      ScanResultTone.info => (c.infoContainer, c.textPrimary),
      ScanResultTone.error => (c.errorContainer, c.error),
    };
    final motion = context.motion;
    return TweenAnimationBuilder<double /* money-double: allow — анимация UI */>(
      key: ValueKey<Object>(Object.hash(title, subtitle, tone)),
      tween: Tween<double>(begin: 0, end: 1), // money-double: allow — анимация UI
      duration: motion.reduceMotion ? motion.reducedCrossfade : motion.fast,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, motion.reduceMotion ? 0 : (1 - v) * 8), child: child),
      ),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.all(context.radii.md),
            boxShadow: context.elevation.e2,
          ),
          child: Padding(
            padding: EdgeInsets.all(s.s4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title,
                        style: t.title.copyWith(color: fg),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (loading) ...<Widget>[SizedBox(width: s.s2), const AppProgress.circular(size: 20)],
                  ],
                ),
                if (subtitle != null) ...<Widget>[
                  SizedBox(height: s.s1),
                  Text(subtitle!, style: t.body.copyWith(color: c.textSecondary), maxLines: 1),
                ],
                if (note != null) ...<Widget>[
                  SizedBox(height: s.s1),
                  Text(note!, style: t.caption.copyWith(color: c.textSecondary)),
                ],
                if (actions.isNotEmpty) ...<Widget>[
                  SizedBox(height: s.s3),
                  Wrap(
                    spacing: s.s2,
                    runSpacing: s.s2,
                    children: <Widget>[
                      for (final a in actions)
                        AppButton(
                          key: a.key,
                          label: a.label,
                          onPressed: a.onPressed,
                          variant: AppButtonVariant.tonal,
                          size: AppButtonSize.s,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// `ReportChart` — полосы долей для карточек отчётов SCR-48 (02 UI-48-002 «полосы по способам оплаты»,
// 03 §9.63 `AppProgress` определённый; анимация 0 → доля 300 мс `standardDecelerate`, reduce-motion — без анимации).
// Без сторонних пакетов: полоса — трек `primaryContainer` + заполнение тона. Доля передаётся целыми промилле
// (0…1000), чтобы вызывающий код не работал с плавающей точкой (деньги — тыйыны, D-19).
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Тон полосы.
enum ReportBarTone { primary, success, warning, error, neutral }

/// Полоса: подпись, значение (уже отформатировано) и доля в промилле.
@immutable
class ReportBar {
  /// Создаёт полосу.
  const ReportBar({
    required this.label,
    required this.valueLabel,
    required this.permille,
    this.tone = ReportBarTone.primary,
  });

  /// Подпись слева.
  final String label;

  /// Значение справа (`tnum`).
  final String valueLabel;

  /// Доля 0…1000 (значения вне диапазона обрезаются).
  final int permille;

  /// Тон заполнения.
  final ReportBarTone tone;

  /// Доля [part] от [whole] в промилле (целочисленно; [whole] ≤ 0 → 0).
  static int share(int part, int whole) {
    if (whole <= 0 || part <= 0) return 0;
    final int p = part * 1000 ~/ whole;
    return p > 1000 ? 1000 : p;
  }
}

/// Горизонтальные полосы долей.
class ReportChart extends StatelessWidget {
  /// Создаёт диаграмму.
  const ReportChart({super.key, required this.bars, this.labelWidth = 120, this.barHeight = 8});

  /// Полосы сверху вниз.
  final List<ReportBar> bars;

  /// Ширина колонки подписей.
  final double labelWidth;

  /// Толщина полосы.
  final double barHeight;

  static Color _fill(DsColors c, ReportBarTone tone) => switch (tone) {
    ReportBarTone.primary => c.primaryText,
    ReportBarTone.success => c.success,
    ReportBarTone.warning => c.warning,
    ReportBarTone.error => c.error,
    ReportBarTone.neutral => c.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final DsTypography t = context.text;
    final Duration d = context.motion.of(context.motion.slow);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final ReportBar bar in bars)
          Semantics(
            label: '${bar.label}: ${bar.valueLabel}',
            excludeSemantics: true,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s1),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: labelWidth,
                    child: Text(
                      bar.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                  ),
                  SizedBox(width: context.space.s2),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.all(context.radii.full),
                      child: Container(
                        height: barHeight,
                        color: c.primaryContainer,
                        alignment: AlignmentDirectional.centerStart,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: bar.permille.clamp(0, 1000) / 1000),
                          duration: d,
                          curve: context.motion.standardDecelerate,
                          builder: (BuildContext context, double v, Widget? child) => FractionallySizedBox(
                            widthFactor: v,
                            heightFactor: 1,
                            child: ColoredBox(color: _fill(c, bar.tone)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: context.space.s2),
                  Text(
                    bar.valueLabel,
                    textAlign: TextAlign.end,
                    style: t.caption.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

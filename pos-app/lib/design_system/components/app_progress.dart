import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Вид индикатора (03 §9.63).
enum AppProgressKind { circular, linear, stepped }

/// Индикатор ожидания `AppProgress` (03 §9.63; ядро §17.5).
///
/// `circular` — кольцо 16/20/24/48 (толщина 2/2/3/4), `linear` — полоса 2/4 px
/// (трек `primaryContainer`, индикатор `primaryText`), `stepped` — N сегментов 4 px.
/// Под reduce-motion неопределённый индикатор — статичное кольцо 75 % (полоса — 30 %).
class AppProgress extends StatefulWidget {
  /// Кольцо.
  const AppProgress.circular({
    super.key,
    this.size = 20,
    this.value,
    this.color,
    this.semanticLabel,
    this.showAfter = Duration.zero,
  }) : kind = AppProgressKind.circular,
       thin = false,
       steps = 0,
       completedSteps = 0,
       label = null;

  /// Полоса: [thin] — 2 px (под полем поиска), иначе 4 px.
  const AppProgress.linear({
    super.key,
    this.value,
    this.thin = false,
    this.color,
    this.semanticLabel,
    this.showAfter = Duration.zero,
  }) : kind = AppProgressKind.linear,
       size = 0,
       steps = 0,
       completedSteps = 0,
       label = null;

  /// Сегменты (загрузка каталога по сущностям): [completedSteps] из [steps], текущий — пульсирует.
  const AppProgress.stepped({
    super.key,
    required this.steps,
    required this.completedSteps,
    this.label,
    this.semanticLabel,
    this.showAfter = Duration.zero,
  }) : kind = AppProgressKind.stepped,
       size = 0,
       value = null,
       thin = false,
       color = null;

  /// Вид.
  final AppProgressKind kind;

  /// Диаметр кольца: 16, 20, 24 или 48.
  final double size;

  /// 0…1 для определённого индикатора; `null` — неопределённый.
  final double? value;

  /// Тонкая полоса 2 px.
  final bool thin;

  /// Цвет индикатора (по умолчанию `primaryText`; на `primary` — `onPrimary`,
  /// на `inverseSurface` — `onInverseSurface`).
  final Color? color;

  /// Число сегментов (`stepped`).
  final int steps;

  /// Завершённые сегменты (`stepped`).
  final int completedSteps;

  /// Подпись «Товары · 12 400 / 50 000» (`stepped`, `caption tnum`).
  final String? label;

  /// Подпись для screen reader («Загрузка»).
  final String? semanticLabel;

  /// Задержка показа (03 §9.63: 300 мс — чтобы не мигать при быстрых ответах).
  final Duration showAfter;

  @override
  State<AppProgress> createState() => _AppProgressState();
}

class _AppProgressState extends State<AppProgress> {
  Timer? _timer;
  late bool _visible = widget.showAfter == Duration.zero;

  @override
  void initState() {
    super.initState();
    if (!_visible) {
      _timer = Timer(widget.showAfter, () {
        if (mounted) {
          setState(() => _visible = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  double get _stroke => switch (widget.size) {
    <= 20 => 2,
    <= 24 => 3,
    _ => 4,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bool reduce = context.motion.reduceMotion;
    final Color color = widget.color ?? colors.primaryText;
    final double? value = widget.value?.clamp(0.0, 1.0);
    if (!_visible) {
      return switch (widget.kind) {
        AppProgressKind.circular => SizedBox.square(dimension: widget.size),
        AppProgressKind.linear => SizedBox(height: widget.thin ? 2 : 4),
        AppProgressKind.stepped => const SizedBox(height: 4),
      };
    }
    final Widget indicator = switch (widget.kind) {
      AppProgressKind.circular => SizedBox.square(
        dimension: widget.size,
        child: CircularProgressIndicator(
          value: value ?? (reduce ? 0.75 : null),
          strokeWidth: _stroke,
          color: color,
          backgroundColor: Colors.transparent,
          strokeCap: StrokeCap.round,
        ),
      ),
      AppProgressKind.linear => ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: value ?? (reduce ? 0.3 : null),
          minHeight: widget.thin ? 2 : 4,
          color: color,
          backgroundColor: colors.primaryContainer,
        ),
      ),
      AppProgressKind.stepped => _Stepped(
        steps: widget.steps,
        completed: widget.completedSteps,
        label: widget.label,
        reduceMotion: reduce,
      ),
    };
    final String? percent = value == null ? null : '${(value * 100).round()} %';
    return Semantics(
      label: widget.semanticLabel,
      value: percent,
      liveRegion: widget.label != null,
      child: ExcludeSemantics(child: indicator),
    );
  }
}

class _Stepped extends StatefulWidget {
  const _Stepped({required this.steps, required this.completed, required this.reduceMotion, this.label});

  final int steps;
  final int completed;
  final String? label;
  final bool reduceMotion;

  @override
  State<_Stepped> createState() => _SteppedState();
}

class _SteppedState extends State<_Stepped> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Stepped oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final bool animate = !widget.reduceMotion && widget.completed < widget.steps;
    if (animate && !_pulse.isAnimating) {
      unawaited(_pulse.repeat(reverse: true));
    } else if (!animate) {
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final List<Widget> segments = <Widget>[];
    for (int i = 0; i < widget.steps; i++) {
      if (i > 0) {
        segments.add(const SizedBox(width: 4));
      }
      final bool done = i < widget.completed;
      final bool current = i == widget.completed;
      Widget seg = Container(
        height: 4,
        decoration: BoxDecoration(
          color: done || current ? colors.primaryText : colors.primaryContainer,
          borderRadius: BorderRadius.circular(2),
        ),
      );
      if (current) {
        seg = FadeTransition(opacity: Tween<double>(begin: 0.4, end: 1).animate(_pulse), child: seg);
      }
      segments.add(Expanded(child: seg));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(children: segments),
        if (widget.label != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            widget.label!,
            style: context.text.caption.copyWith(color: colors.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        ],
      ],
    );
  }
}

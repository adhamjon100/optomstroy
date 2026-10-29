import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart' show dsTimeLabelOrFull;
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `SyncIndicator` (03 §9.40).
enum SyncIndicatorVariant {
  /// `sync` `textSecondary`, «обновлено 09:41».
  ok,

  /// Иконка вращается (ANIM-021, 1 с loop), «обновляем…»: с подписью — `primaryText`, только иконкой ([SyncIndicator.compact],
  /// шапка medium+) — `textSecondary` (оранжевый не означает статус — ядро §24.1, A11Y-004).
  syncing,

  /// `sync` `warning`, «данные от 08:10» (старше порога).
  stale,

  /// `sync_problem` `error`, «ошибка синхронизации».
  error,

  /// `cloud_off` `warning`, «нет сети».
  offline,

  /// «ещё не синхронизировано» `textSecondary` (первый запуск).
  never,
}

/// `SyncIndicator` (03 §9.40): иконка 20 + `caption` (`tnum`), высота строки 24; тап — SCR-43.
/// [compact] — только иконка с точкой-статусом (шапка на compact). [SyncIndicator.inline] — метка возраста
/// данных в таблицах и на карточках («данные от 09:41»; устаревшие — `warning` + `schedule`).
/// Цвета — только статусные токены: никогда `brandAccent` и заливка `primary` (ядро v1.9 §24.1).
///
/// Тексты — ARB: `ds_updated_at`, `ds_data_as_of`, `sync_never`, `sync_run_button_busy` («Обновляем…»),
/// `notification_kind_sync_error` («Ошибка синхронизации»), `global_offline_title` («Нет подключения к сети»).
class SyncIndicator extends StatefulWidget {
  /// Индикатор в шапке / на SCR-43.
  const SyncIndicator({
    super.key,
    required this.variant,
    this.time,
    this.compact = false,
    this.onTap,
    this.tooltip,
    this.now,
  }) : inline = false,
       label = null;

  /// Метка возраста данных (`inline`): «данные от {time}»; [stale] — `warning` + `schedule`. [label] — подпись
  /// экрана вместо «данные от …» (например, «Данные 1С на {time}» для снимков 1С — AC-UI-30-002).
  const SyncIndicator.inline({
    super.key,
    required DateTime this.time,
    bool stale = false,
    this.now,
    this.tooltip,
    this.label,
  }) : variant = stale ? SyncIndicatorVariant.stale : SyncIndicatorVariant.ok,
       inline = true,
       compact = false,
       onTap = null;

  /// Вариант.
  final SyncIndicatorVariant variant;

  /// Время для подписи (обновлено / данные от).
  final DateTime? time;

  /// Только иконка с точкой-статусом.
  final bool compact;

  /// Метка возраста данных.
  final bool inline;

  /// Тап → SCR-43 (или SS краткого статуса на expanded).
  final VoidCallback? onTap;

  /// Подробности по сущностям (hover на expanded).
  final String? tooltip;

  /// «Сейчас» (UTC, из `clockProvider`) для формата времени: в тот же день — «09:41», иначе с датой;
  /// без него — всегда с датой (компонент системные часы не читает).
  final DateTime? now;

  /// Подпись метки `inline` вместо стандартной (`null` — «данные от {time}»).
  final String? label;

  /// Ключ корневого элемента (тесты).
  static const Key indicatorKey = Key('sync-indicator');

  /// Ключ области нажатия (цель ≥ 44; тесты).
  static const Key tapTargetKey = Key('sync-indicator-tap');

  /// Иконка варианта.
  static IconData iconOf(SyncIndicatorVariant v, {bool inline = false}) => switch (v) {
    SyncIndicatorVariant.ok ||
    SyncIndicatorVariant.syncing ||
    SyncIndicatorVariant.never => inline ? Icons.schedule_rounded : Icons.sync_rounded,
    SyncIndicatorVariant.stale => inline ? Icons.schedule_rounded : Icons.sync_rounded,
    SyncIndicatorVariant.error => Icons.sync_problem_rounded,
    SyncIndicatorVariant.offline => Icons.cloud_off_rounded,
  };

  /// Цвет иконки и текста варианта. [iconOnly] — индикатор без подписи (`compact`): у `syncing` иконка
  /// `textSecondary` — при «Уменьшить анимации» вращения нет, и оранжевый стал бы единственным признаком состояния
  /// (ядро §24.1 «оранжевый не означает статус», A11Y-004, WCAG 1.4.1); состояние передают вращение, тултип и
  /// `Semantics`.
  static Color colorOf(DsColors c, SyncIndicatorVariant v, {bool iconOnly = false}) => switch (v) {
    SyncIndicatorVariant.ok || SyncIndicatorVariant.never => c.textSecondary,
    SyncIndicatorVariant.syncing => iconOnly ? c.textSecondary : c.primaryText,
    SyncIndicatorVariant.stale || SyncIndicatorVariant.offline => c.warning,
    SyncIndicatorVariant.error => c.error,
  };

  /// Подпись варианта.
  static String labelOf(
    BuildContext context,
    SyncIndicatorVariant v, {
    DateTime? time,
    bool inline = false,
    DateTime? now,
  }) {
    final l10n = AppLocalizations.of(context);
    String at(DateTime t) => dsTimeLabelOrFull(context, t, now);
    if (inline && time != null) return l10n.ds_data_as_of(at(time));
    return switch (v) {
      SyncIndicatorVariant.ok => time == null ? l10n.sync_never : l10n.ds_updated_at(at(time)),
      SyncIndicatorVariant.syncing => l10n.ds_sync_syncing,
      SyncIndicatorVariant.stale => time == null ? l10n.sync_never : l10n.ds_data_as_of(at(time)),
      SyncIndicatorVariant.error => l10n.ds_sync_error,
      SyncIndicatorVariant.offline => l10n.ds_sync_offline,
      SyncIndicatorVariant.never => l10n.sync_never,
    };
  }

  @override
  State<SyncIndicator> createState() => _SyncIndicatorState();
}

class _SyncIndicatorState extends State<SyncIndicator> with SingleTickerProviderStateMixin {
  AnimationController? _spin;

  void _syncSpin(bool reduceMotion) {
    final spinning = widget.variant == SyncIndicatorVariant.syncing && !reduceMotion;
    if (spinning) {
      _spin ??= AnimationController(vsync: this, duration: const Duration(seconds: 1));
      if (!_spin!.isAnimating) unawaited(_spin!.repeat());
    } else {
      _spin?.stop();
    }
  }

  @override
  void dispose() {
    _spin?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final reduceMotion = context.motion.reduceMotion;
    _syncSpin(reduceMotion);
    final v = widget.variant;
    final color = SyncIndicator.colorOf(colors, v, iconOnly: widget.compact);
    final label =
        widget.label ?? SyncIndicator.labelOf(context, v, time: widget.time, inline: widget.inline, now: widget.now);
    Widget icon = Icon(
      SyncIndicator.iconOf(v, inline: widget.inline),
      size: widget.inline ? 16 : 20,
      color: color,
    );
    final spin = _spin;
    if (spin != null && spin.isAnimating) icon = RotationTransition(turns: spin, child: icon);

    Widget content;
    if (widget.compact) {
      final dot = switch (v) {
        SyncIndicatorVariant.stale || SyncIndicatorVariant.offline => colors.warning,
        SyncIndicatorVariant.error => colors.error,
        _ => null,
      };
      content = SizedBox.square(
        dimension: 24,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: <Widget>[
            icon,
            if (dot != null)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: dot,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.surface, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      );
    } else {
      content = SizedBox(
        height: widget.inline ? 20 : 24,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            icon,
            SizedBox(width: context.space.s1),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.caption.copyWith(
                  color: v == SyncIndicatorVariant.ok || v == SyncIndicatorVariant.never ? colors.textSecondary : color,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final onTap = widget.onTap;
    Widget result = Semantics(
      key: SyncIndicator.indicatorKey,
      container: true,
      button: onTap != null,
      liveRegion: v == SyncIndicatorVariant.error,
      label: label,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator: жест DsInteractive из семантики исключён.
      onTap: onTap,
      child: content,
    );
    if (onTap != null) {
      // Цель ≥ 44; фокус клавиатуры — кольцо `focus` (03 §5.4.5), как у соседних кнопок шапки; hover — `surfaceHover`.
      final BorderRadius radius = BorderRadius.all(context.radii.sm);
      final Widget semantic = result;
      result = DsInteractive(
        key: SyncIndicator.tapTargetKey,
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
          visible: s.focused,
          borderRadius: radius,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            padding: EdgeInsets.symmetric(horizontal: context.space.s2),
            decoration: BoxDecoration(
              color: s.pressed ? colors.surfacePressed : (s.hovered ? colors.surfaceHover : Colors.transparent),
              borderRadius: radius,
            ),
            child: Center(widthFactor: 1, child: semantic),
          ),
        ),
      );
    }
    final tip = widget.tooltip;
    return tip == null ? result : AppTooltip(message: tip, child: result);
  }
}

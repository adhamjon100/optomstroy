import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart' show dsTimeLabel;
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `SyncIndicator` (03 §9.40).
enum SyncIndicatorVariant {
  /// `sync` `textSecondary`, «обновлено 09:41».
  ok,

  /// Иконка вращается (ANIM-021, 1 с loop) `primaryText`, «обновляем…».
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

  /// «Сейчас» для формата времени (тесты).
  final DateTime? now;

  /// Подпись метки `inline` вместо стандартной (`null` — «данные от {time}»).
  final String? label;

  /// Ключ корневого элемента (тесты).
  static const Key indicatorKey = Key('sync-indicator');

  /// Иконка варианта.
  static IconData iconOf(SyncIndicatorVariant v, {bool inline = false}) => switch (v) {
    SyncIndicatorVariant.ok ||
    SyncIndicatorVariant.syncing ||
    SyncIndicatorVariant.never => inline ? Icons.schedule_rounded : Icons.sync_rounded,
    SyncIndicatorVariant.stale => inline ? Icons.schedule_rounded : Icons.sync_rounded,
    SyncIndicatorVariant.error => Icons.sync_problem_rounded,
    SyncIndicatorVariant.offline => Icons.cloud_off_rounded,
  };

  /// Цвет иконки и текста варианта.
  static Color colorOf(DsColors c, SyncIndicatorVariant v) => switch (v) {
    SyncIndicatorVariant.ok || SyncIndicatorVariant.never => c.textSecondary,
    SyncIndicatorVariant.syncing => c.primaryText,
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
    String at(DateTime t) => dsTimeLabel(context, t, now: now);
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
    final color = SyncIndicator.colorOf(colors, v);
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

    Widget result = Semantics(
      key: SyncIndicator.indicatorKey,
      container: true,
      button: widget.onTap != null,
      liveRegion: v == SyncIndicatorVariant.error,
      label: label,
      excludeSemantics: true,
      child: content,
    );
    final onTap = widget.onTap;
    if (onTap != null) {
      result = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.all(context.radii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: context.space.s2),
            child: Center(widthFactor: 1, child: result),
          ),
        ),
      );
    }
    final tip = widget.tooltip;
    return tip == null ? result : AppTooltip(message: tip, child: result);
  }
}

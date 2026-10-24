import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `OfflineBanner` (03 §9.41).
enum OfflineBannerVariant {
  /// `warningContainer`/`warning`, `cloud_off`: «Нет сети. Показаны данные от 09:41. Заказы недоступны».
  offline,

  /// `infoContainer`/`info`, спиннер 16: «Подключаемся…».
  reconnecting,

  /// `successContainer`/`success`, `cloud_done`: «Сеть восстановлена. Отправляем изменения…» (скрывается через 3 с).
  backOnline,

  /// `errorContainer`/`error`: «Сервер недоступен · Повторить».
  serverDown,

  /// `warningContainer`/`warning` (staff): «1С недоступна: заказы будут отправлены позже…».
  onecDown,

  /// `infoContainer`/`info`: «Требуется обновление приложения · Обновить».
  updateRequired,
}

/// `OfflineBanner` (03 §9.41): глобальная полоса состояния сети под шапкой на всю ширину — иконка 20, текст
/// `label 500`, необязательная кнопка `text S`. Высота 40 (compact — 48, текст `caption` в 2 строки).
/// [variant] = `null` — баннер скрыт; появление/скрытие — slide-down 200 мс (ANIM-019; reduce-motion — сразу).
/// Баннер не перекрывает контент, а сдвигает его; пользователем не закрывается.
///
/// Тексты — ARB 03 §16: `ds_offline_banner`, `ds_reconnecting`, `ds_back_online`, `ds_server_down`,
/// `ds_onec_down`, `ds_update_required`; без метки данных вариант `offline` показывает `global_offline_title`.
class OfflineBanner extends StatelessWidget {
  /// Создаёт баннер.
  const OfflineBanner({
    super.key,
    required this.variant,
    this.dataAsOf,
    this.message,
    this.actionLabel,
    this.onAction,
    this.now,
  });

  /// Ключ полосы (тесты).
  static const Key bannerKey = Key('offline-banner');

  /// Вариант; `null` — скрыт.
  final OfflineBannerVariant? variant;

  /// Момент данных кэша («Показаны данные от {time}»).
  final DateTime? dataAsOf;

  /// Текст вместо текста варианта по умолчанию.
  final String? message;

  /// Кнопка «Повторить» / «Подробнее» / «Обновить».
  final String? actionLabel;
  final VoidCallback? onAction;

  /// «Сейчас» для формата времени (тесты); по умолчанию — часы устройства.
  final DateTime? now;

  /// Иконка варианта.
  static IconData iconOf(OfflineBannerVariant v) => switch (v) {
    OfflineBannerVariant.offline => Icons.cloud_off_rounded,
    OfflineBannerVariant.reconnecting => Icons.sync_rounded,
    OfflineBannerVariant.backOnline => Icons.cloud_done_rounded,
    OfflineBannerVariant.serverDown => Icons.cloud_off_rounded,
    OfflineBannerVariant.onecDown => Icons.sync_problem_rounded,
    OfflineBannerVariant.updateRequired => Icons.system_update_rounded,
  };

  /// Пара (фон, текст/иконка) варианта.
  static (Color, Color) colorsOf(DsColors c, OfflineBannerVariant v) => switch (v) {
    OfflineBannerVariant.offline || OfflineBannerVariant.onecDown => (c.warningContainer, c.warning),
    OfflineBannerVariant.reconnecting || OfflineBannerVariant.updateRequired => (c.infoContainer, c.info),
    OfflineBannerVariant.backOnline => (c.successContainer, c.success),
    OfflineBannerVariant.serverDown => (c.errorContainer, c.error),
  };

  /// Текст варианта по умолчанию.
  static String textOf(BuildContext context, OfflineBannerVariant v, DateTime? dataAsOf, {DateTime? now}) {
    final l10n = AppLocalizations.of(context);
    return switch (v) {
      OfflineBannerVariant.offline =>
        dataAsOf == null ? l10n.ds_sync_offline : l10n.ds_offline_banner(dsTimeLabel(context, dataAsOf, now: now)),
      OfflineBannerVariant.reconnecting => l10n.ds_reconnecting,
      OfflineBannerVariant.backOnline => l10n.ds_back_online,
      OfflineBannerVariant.serverDown => l10n.ds_server_down,
      OfflineBannerVariant.onecDown => l10n.ds_onec_down,
      OfflineBannerVariant.updateRequired => l10n.ds_update_required,
    };
  }

  @override
  Widget build(BuildContext context) {
    final motion = context.motion;
    final v = variant;
    final child = v == null ? const SizedBox(width: double.infinity) : _bar(context, v);
    // Reduce-motion: появление без анимации (AnimatedSize с нулевой длительностью не используется).
    if (motion.reduceMotion) return child;
    return AnimatedSize(
      duration: motion.base,
      curve: motion.standardDecelerate,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  Widget _bar(BuildContext context, OfflineBannerVariant v) {
    final (Color bg, Color fg) = colorsOf(context.colors, v);
    final compact = context.windowClass == WindowClass.compact;
    final text = message ?? textOf(context, v, dataAsOf, now: now);
    final style = (compact ? context.text.caption : context.text.label).copyWith(
      color: fg,
      fontWeight: FontWeight.w500,
    );
    final action = actionLabel;
    return Semantics(
      key: bannerKey,
      container: true,
      liveRegion: true,
      label: text,
      child: ColoredBox(
        color: bg,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: compact ? 48 : 40, minWidth: double.infinity),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s1),
            child: Row(
              children: <Widget>[
                if (v == OfflineBannerVariant.reconnecting)
                  SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: fg,
                      value: context.motion.reduceMotion ? 0.7 : null,
                    ),
                  )
                else
                  Icon(iconOf(v), size: 20, color: fg),
                SizedBox(width: context.space.s2),
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(text, maxLines: compact ? 2 : 1, overflow: TextOverflow.ellipsis, style: style),
                  ),
                ),
                if (action != null && onAction != null) ...<Widget>[
                  SizedBox(width: context.space.s2),
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: fg,
                      minimumSize: const Size(44, 36),
                      textStyle: context.text.label.copyWith(fontWeight: FontWeight.w600),
                    ),
                    child: Text(action),
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

/// Время метки данных: сегодня — «09:41», иначе — «12 окт., 09:41» (местное время устройства, Asia/Bishkek).
String dsTimeLabel(BuildContext context, DateTime at, {DateTime? now}) {
  final locale = Localizations.maybeLocaleOf(context)?.toLanguageTag() ?? 'ru';
  final local = at.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final sameDay = local.year == today.year && local.month == today.month && local.day == today.day;
  return DateFormat(sameDay ? 'HH:mm' : 'd MMM, HH:mm', locale).format(local);
}

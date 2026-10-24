import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Тон баннера уведомления.
enum NotificationBannerTone {
  /// `warningContainer` / `warning` — изменение цен и остатков в корзине.
  warning,

  /// `errorContainer` / `error` — продажа в долг заблокирована.
  error,

  /// `infoContainer` / `info`.
  info,
}

/// Баннер in-app уведомления в экране (D-41, RM-F-008; анатомия `ErrorState.banner` 03 §9.42): иконка вида 20
/// цветом тона + заголовок `body 600` + текст `caption textSecondary` (≤ 2 строк) + действие `AppButton` text S +
/// «Закрыть» (отметка о прочтении — у вызывающего); уже 480 — действие под текстом. Фон — контейнер тона,
/// радиус `md`. Появление — fade
/// `ds.motion.fast` (reduce-motion — мгновенно). Объявляется диктором (`liveRegion`).
/// Тексты передаёт вызывающий (ключи ARB; заголовок и текст уведомления формирует сервер).
class NotificationBanner extends StatelessWidget {
  /// Создаёт баннер.
  const NotificationBanner({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.tone = NotificationBannerTone.warning,
    this.actionLabel,
    this.onAction,
    this.onClose,
    this.closeLabel,
  });

  /// Иконка вида уведомления (`sell`, `inventory_2`, `block`).
  final IconData icon;

  /// Заголовок.
  final String title;

  /// Текст (без сумм и ПДн — правило сервера).
  final String? message;

  /// Тон.
  final NotificationBannerTone tone;

  /// Подпись действия («Открыть корзину»).
  final String? actionLabel;

  /// Действие.
  final VoidCallback? onAction;

  /// Закрыть баннер.
  final VoidCallback? onClose;

  /// Подпись «Закрыть» для диктора.
  final String? closeLabel;

  /// Ключ кнопки закрытия.
  static const Key closeKey = ValueKey<String>('notification-banner-close');

  /// Ключ действия.
  static const Key actionKey = ValueKey<String>('notification-banner-action');

  /// Пара (контейнер, цвет) тона.
  static (Color, Color) colorsOf(DsColors c, NotificationBannerTone t) => switch (t) {
    NotificationBannerTone.warning => (c.warningContainer, c.warning),
    NotificationBannerTone.error => (c.errorContainer, c.error),
    NotificationBannerTone.info => (c.infoContainer, c.info),
  };

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final (Color bg, Color fg) = colorsOf(c, tone);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: EdgeInsetsDirectional.only(
          start: context.space.s4,
          end: context.space.s1,
          top: context.space.s2,
          bottom: context.space.s2,
        ),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.all(context.radii.md)),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            // Узкая ширина (compact) — действие под текстом, чтобы не сжимать заголовок.
            final bool stacked = box.maxWidth < 480;
            final Widget? action = actionLabel != null && onAction != null
                ? AppButton(
                    key: actionKey,
                    label: actionLabel!,
                    onPressed: onAction,
                    variant: AppButtonVariant.text,
                    size: AppButtonSize.s,
                  )
                : null;
            return Row(
              crossAxisAlignment: stacked ? CrossAxisAlignment.start : CrossAxisAlignment.center,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.only(top: stacked ? context.space.s2 : 0),
                  child: Icon(icon, size: 20, color: fg),
                ),
                SizedBox(width: context.space.s3),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: stacked ? context.space.s1 : 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.body.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600),
                        ),
                        if (message != null && message!.isNotEmpty)
                          Text(
                            message!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.caption.copyWith(color: c.textSecondary),
                          ),
                        if (stacked && action != null)
                          Transform.translate(offset: Offset(-context.space.s3, 0), child: action),
                      ],
                    ),
                  ),
                ),
                if (!stacked && action != null) action,
                if (onClose != null)
                  AppIconButton(
                    key: closeKey,
                    icon: Icons.close_rounded,
                    iconSize: 20,
                    semanticLabel: closeLabel ?? '',
                    tooltip: closeLabel,
                    onPressed: onClose,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

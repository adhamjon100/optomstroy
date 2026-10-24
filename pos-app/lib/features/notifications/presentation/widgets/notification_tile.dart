// Строка уведомления UI-44-002 (02 SCR-44.3): 72 (экран) / 56 (popover); у непрочитанных — полоса 3 lp
// `primaryText` слева и точка 8; заголовок `body 600` (непрочит.) / `body 400`; текст `caption textSecondary` ≤ 2
// строк; время `caption tnum` справа; иконка и цвет — по виду; действие UI-44-009 — `AppButton` text S.
// Свайп влево (compact) — «Прочитано»; долгое нажатие — меню «Отметить прочитанным» (A11Y-017).
// Прочтение строки — ANIM-015 (150 мс; reduce-motion — мгновенно).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_kind_style.dart';

/// Действие в строке (UI-44-009).
final class NotificationTileAction {
  const NotificationTileAction(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;
}

class NotificationTile extends StatefulWidget {
  const NotificationTile({
    super.key,
    required this.notification,
    required this.read,
    required this.time,
    required this.onTap,
    required this.onMarkRead,
    this.action,
    this.dense = false,
    this.swipeToRead = false,
    this.expandOnTap = false,
  });

  final AppNotification notification;

  /// Прочитано (с учётом локальных отметок).
  final bool read;

  /// «09:41».
  final String time;
  final VoidCallback onTap;
  final VoidCallback onMarkRead;
  final NotificationTileAction? action;

  /// Popover: высота 56, текст в 1 строку.
  final bool dense;

  /// Свайп влево «Прочитано» (compact).
  final bool swipeToRead;

  /// Тап раскрывает полный текст (уведомление без цели перехода).
  final bool expandOnTap;

  static Key keyOf(String id) => ValueKey<String>('notification-$id');
  static Key unreadDotKey(String id) => ValueKey<String>('notification-unread-$id');
  static Key actionKey(String id) => ValueKey<String>('notification-action-$id');

  @override
  State<NotificationTile> createState() => _NotificationTileState();
}

class _NotificationTileState extends State<NotificationTile> {
  bool _expanded = false;

  Future<void> _menu(Offset at) async {
    if (widget.read) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final RenderBox? overlay = Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final bool? mark = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: <PopupMenuEntry<bool>>[PopupMenuItem<bool>(value: true, child: Text(l10n.notifications_mark_read))],
    );
    if (mark == true) widget.onMarkRead();
  }

  void _tap() {
    // Без цели — раскрыть полный текст (02 SCR-44.4); отметку и переход делает вызывающий.
    if (widget.expandOnTap) setState(() => _expanded = !_expanded);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final AppNotification n = widget.notification;
    final NotificationKindStyle style = NotificationKindStyle.of(context, n);
    final String kindLabel = NotificationLabels.kind(l10n, n.kind);
    final String text = n.body ?? kindLabel;
    final StatusChip? chip = widget.dense ? null : NotificationLabels.orderStatusChip(l10n, n);
    final Duration fade = context.motion.of(context.motion.fast);
    final bool unread = !widget.read;

    final Widget content = AnimatedContainer(
      duration: fade,
      constraints: BoxConstraints(minHeight: widget.dense ? 56 : 72),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(
          left: BorderSide(color: unread ? c.primaryText : c.surface, width: 3),
          bottom: BorderSide(color: c.border),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        context.space.s3,
        widget.dense ? context.space.s2 : context.space.s3,
        context.space.s4,
        widget.dense ? context.space.s2 : context.space.s3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Tooltip(
            message: kindLabel,
            excludeFromSemantics: true,
            child: Padding(
              padding: EdgeInsets.only(top: context.space.s1 / 2),
              child: Icon(style.icon, size: 24, color: style.color),
            ),
          ),
          SizedBox(width: context.space.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: AnimatedDefaultTextStyle(
                        duration: fade,
                        style: context.text.body.copyWith(
                          color: c.textPrimary,
                          fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                        ),
                        child: Text(n.title, maxLines: _expanded ? null : 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    SizedBox(width: context.space.s2),
                    Text(
                      widget.time,
                      style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                    ),
                    if (unread) ...<Widget>[
                      SizedBox(width: context.space.s2),
                      Padding(
                        padding: EdgeInsets.only(top: context.space.s1 + 2),
                        child: Container(
                          key: NotificationTile.unreadDotKey(n.id),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: c.primaryText, shape: BoxShape.circle),
                        ),
                      ),
                    ],
                  ],
                ),
                if (text.isNotEmpty) ...<Widget>[
                  SizedBox(height: context.space.s1 / 2),
                  Text(
                    text,
                    maxLines: _expanded ? null : (widget.dense ? 1 : 2),
                    overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                    style: context.text.caption.copyWith(color: c.textSecondary),
                  ),
                ],
                if (chip != null) ...<Widget>[SizedBox(height: context.space.s1), chip],
                if (widget.action != null && !widget.dense)
                  Padding(
                    padding: EdgeInsets.only(top: context.space.s1),
                    child: AppButton(
                      key: NotificationTile.actionKey(n.id),
                      label: widget.action!.label,
                      variant: AppButtonVariant.text,
                      size: AppButtonSize.s,
                      onPressed: widget.action!.onPressed,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    Widget tile = Semantics(
      button: true,
      label: unread ? l10n.notifications_item_unread_a11y(widget.time, n.title) : '${n.title}, ${widget.time}',
      excludeSemantics: false,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: NotificationTile.keyOf(n.id),
          onTap: _tap,
          onLongPress: unread ? () => unawaited(_menuAtCenter()) : null,
          onSecondaryTapUp: unread ? (TapUpDetails d) => unawaited(_menu(d.globalPosition)) : null,
          child: content,
        ),
      ),
    );
    if (widget.swipeToRead && unread) {
      tile = Dismissible(
        key: ValueKey<String>('notification-swipe-${n.id}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (_) async {
          widget.onMarkRead();
          return false;
        },
        background: ColoredBox(
          color: c.primaryContainer,
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: context.space.s4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.done_all_rounded, color: c.primaryText, size: 20),
                  SizedBox(width: context.space.s2),
                  Text(l10n.notifications_mark_read, style: context.text.label.copyWith(color: c.primaryText)),
                ],
              ),
            ),
          ),
        ),
        child: tile,
      );
    }
    return tile;
  }

  Future<void> _menuAtCenter() async {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    await _menu(box.localToGlobal(box.size.center(Offset.zero)));
  }
}

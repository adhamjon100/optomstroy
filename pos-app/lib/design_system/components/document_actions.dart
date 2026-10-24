import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Документ блока [DocumentActions].
@immutable
class DocumentActionItem {
  /// Создаёт строку документа.
  const DocumentActionItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.available = true,
    this.unavailableReason,
    this.onPreview,
    this.onPrint,
    this.onDownload,
    this.busy = false,
    this.icon = Icons.description_outlined,
  });

  /// Идентификатор (ключи виджетов: `doc-<id>`, `doc-<id>-preview|print|download`).
  final String id;

  /// «Счёт на оплату».
  final String title;

  /// «PDF, A4» / «Не является фискальным документом, 80 мм».
  final String? subtitle;

  /// Документ доступен (иначе кнопки скрыты, показана [unavailableReason]).
  final bool available;

  /// «Ожидает номер 1С», «После оплаты», «Печатается из 1С при отгрузке».
  final String? unavailableReason;

  /// «Просмотр» (`null` — кнопки нет).
  final VoidCallback? onPreview;

  /// «Печать» (`null` — кнопки нет).
  final VoidCallback? onPrint;

  /// «Скачать PDF» (`null` — кнопки нет).
  final VoidCallback? onDownload;

  /// Документ загружается (кнопки в `loading`/disabled — повторные нажатия игнорируются).
  final bool busy;

  /// Иконка 20 слева.
  final IconData icon;
}

/// Блок документов заказа (02 SCR-24 UI-24-009, SCR-22 UI-22-008; 03 §9.59 `PrintOptions.reprint` +
/// §9.68 `DocumentPreview`): строка на документ — иконка, название, подпись `caption`, справа действия
/// «Просмотр» / «Печать» / «Скачать PDF» (`AppButton.text S`); недоступный документ — без действий,
/// с причиной `caption textSecondary` (тултип на expanded). Подписи кнопок передаёт экран (ARB).
class DocumentActions extends StatelessWidget {
  /// Создаёт блок.
  const DocumentActions({
    super.key,
    required this.items,
    required this.previewLabel,
    required this.printLabel,
    this.downloadLabel,
    this.enabled = true,
  });

  /// Документы по порядку.
  final List<DocumentActionItem> items;

  /// «Просмотр».
  final String previewLabel;

  /// «Печать».
  final String printLabel;

  /// «Скачать PDF».
  final String? downloadLabel;

  /// Действия доступны (офлайн — нет).
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (int i = 0; i < items.length; i++) ...<Widget>[
        if (i > 0) Divider(height: 1, thickness: 1, color: context.colors.border),
        _DocumentRow(item: items[i], owner: this),
      ],
    ],
  );
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({required this.item, required this.owner});

  final DocumentActionItem item;
  final DocumentActions owner;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool active = item.available && owner.enabled;
    final String? reason = item.available ? null : item.unavailableReason;
    final List<Widget> buttons = <Widget>[
      if (item.available && item.onPreview != null)
        _button(context, 'preview', owner.previewLabel, Icons.visibility_outlined, item.onPreview!, active),
      if (item.available && item.onPrint != null)
        _button(context, 'print', owner.printLabel, Icons.print_outlined, item.onPrint!, active),
      if (item.available && item.onDownload != null && owner.downloadLabel != null)
        _button(context, 'download', owner.downloadLabel!, Icons.download_outlined, item.onDownload!, active),
    ];
    final Widget info = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(item.icon, size: 20, color: item.available ? c.textSecondary : c.disabledText),
        ),
        SizedBox(width: context.space.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                item.title,
                style: context.text.bodyMedium.copyWith(color: item.available ? c.textPrimary : c.textSecondary),
              ),
              if (item.subtitle != null)
                Text(item.subtitle!, style: context.text.caption.copyWith(color: c.textSecondary)),
              if (reason != null)
                AppTooltip(
                  message: reason,
                  child: Text(
                    reason,
                    key: ValueKey<String>('doc-${item.id}-reason'),
                    style: context.text.caption.copyWith(color: c.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    return Padding(
      key: ValueKey<String>('doc-${item.id}'),
      padding: EdgeInsets.symmetric(vertical: context.space.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          info,
          if (buttons.isNotEmpty)
            Padding(
              padding: EdgeInsetsDirectional.only(start: 20 + context.space.s3),
              child: Wrap(spacing: context.space.s1, runSpacing: 0, children: buttons),
            ),
        ],
      ),
    );
  }

  Widget _button(BuildContext context, String action, String label, IconData icon, VoidCallback onTap, bool active) =>
      AppButton(
        key: ValueKey<String>('doc-${item.id}-$action'),
        label: label,
        icon: icon,
        variant: AppButtonVariant.text,
        size: AppButtonSize.s,
        loading: item.busy && action == 'print',
        onPressed: active && !item.busy ? onTap : null,
      );
}

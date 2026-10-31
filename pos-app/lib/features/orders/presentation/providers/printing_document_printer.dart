// Печать и просмотр PDF документов заказа через пакет `printing` (RM-F-004; 02 SCR-24 UI-24-009, раздел 3.9):
// `PdfPreview` без «Поделиться» (Q-264), `Printing.layoutPdf` — системный диалог печати Windows/Android; байты — только
// память. Подключение — корень: `orderDocumentPrinterProvider.overrideWithValue(const PrintingOrderDocumentPrinter())`.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:printing/printing.dart';

/// Реализация через пакет `printing` (RM-F-004): `PdfPreview` без «Поделиться» и `Printing.layoutPdf`.
final class PrintingOrderDocumentPrinter implements OrderDocumentPrinter {
  /// Создаёт реализацию.
  const PrintingOrderDocumentPrinter();

  @override
  Future<void> preview(BuildContext context, OrderDocumentFile file) => showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => Dialog(
      child: SizedBox(
        width: 720,
        height: 860,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DocumentPreviewHeader(title: file.fileName, onClose: () => Navigator.of(ctx).pop()),
            Expanded(
              child: PdfPreview(
                build: (_) async => Uint8List.fromList(file.bytes),
                pdfFileName: file.fileName,
                allowSharing: false,
                canChangePageFormat: false,
                canChangeOrientation: false,
                canDebug: false,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Future<bool> print(OrderDocumentFile file) =>
      Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(file.bytes), name: file.fileName);
}

/// Шапка предпросмотра (03 §9.68 `DocumentPreview`: название документа и `AppIconButton` «Закрыть»; Esc тоже
/// закрывает). У панели `PdfPreview` своей кнопки закрытия нет — без шапки диалог закрывался только Esc (uiA-13).
class DocumentPreviewHeader extends StatelessWidget {
  /// Создаёт шапку.
  const DocumentPreviewHeader({required this.title, required this.onClose, super.key});

  /// Ключ кнопки «Закрыть».
  static const Key closeKey = ValueKey<String>('document-preview-close');

  /// Название (имя файла документа, например `receipt-POS-2026-000123.pdf`).
  final String title;

  /// «Закрыть».
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return SizedBox(
      height: 56,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: context.space.s4, end: context.space.s2),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.title.copyWith(fontWeight: FontWeight.w600, color: context.colors.textPrimary),
              ),
            ),
            AppIconButton(
              key: closeKey,
              icon: Icons.close_rounded,
              semanticLabel: l10n.ds_button_close,
              tooltip: l10n.ds_button_close,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

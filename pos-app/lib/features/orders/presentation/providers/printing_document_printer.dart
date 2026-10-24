// Печать и просмотр PDF документов заказа через пакет `printing` (RM-F-004; 02 SCR-24 UI-24-009, раздел 3.9):
// `PdfPreview` без «Поделиться» (Q-264), `Printing.layoutPdf` — системный диалог печати Windows/Android; байты — только
// память. Подключение — корень: `orderDocumentPrinterProvider.overrideWithValue(const PrintingOrderDocumentPrinter())`.
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
        child: PdfPreview(
          build: (_) async => Uint8List.fromList(file.bytes),
          pdfFileName: file.fileName,
          allowSharing: false,
          canChangePageFormat: false,
          canChangeOrientation: false,
          canDebug: false,
        ),
      ),
    ),
  );

  @override
  Future<bool> print(OrderDocumentFile file) =>
      Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(file.bytes), name: file.fileName);
}

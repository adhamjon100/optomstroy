// Печать PDF документов заказа через пакет `printing` (`Printing.layoutPdf`: системный диалог печати Windows /
// Android; PDF формирует backend — D-27, RM-F-004). Подключается в композиционном корне:
//   checkoutPrinterProvider.overrideWithValue(printingCheckoutPrinter)
// Отдельный файл: экраны и тесты не импортируют `printing` (FQ-CHK-07 — `image 4.11.0` несовместим с `archive 4.0.9`).
import 'dart:typed_data';

import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:printing/printing.dart';

/// Печать через системный диалог; `true` — документ отправлен на принтер.
Future<bool> printingCheckoutPrinter(OrderDocumentFile file) =>
    Printing.layoutPdf(name: file.fileName, onLayout: (_) async => Uint8List.fromList(file.bytes));

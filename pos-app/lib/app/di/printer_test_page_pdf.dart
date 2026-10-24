// PDF-образец тестовой печати A4 (02 UI-42-014, PRINT-010): «ТЕСТОВАЯ ПЕЧАТЬ · не является фискальным документом»,
// дата, устройство. Формируется локально (пакет `pdf`), шрифт — Inter из assets приложения (кириллица). Импортирует
// только корень (как `printing_document_printer.dart`), чтобы экраны и их тесты не компилировали `pdf`.
import 'package:flutter/services.dart' show rootBundle;
import 'package:optomstroy/app/di/printer_settings_port.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Путь шрифта (объявлен в pubspec `assets/fonts/`).
const String kTestPageFontAsset = 'assets/fonts/Inter/Inter-Regular.ttf';

/// Байты PDF A4.
Future<List<int>> buildA4TestPage(PrinterTestTexts texts, String stamp, String device) async {
  final pw.Font font = pw.Font.ttf(await rootBundle.load(kTestPageFontAsset));
  final pw.Document doc = pw.Document(title: texts.title);
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (pw.Context context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Text(texts.title, style: pw.TextStyle(font: font, fontSize: 18)),
          pw.SizedBox(height: 12),
          pw.Text(stamp, style: pw.TextStyle(font: font, fontSize: 12)),
          pw.Text(device, style: pw.TextStyle(font: font, fontSize: 12)),
        ],
      ),
    ),
  );
  return doc.save();
}

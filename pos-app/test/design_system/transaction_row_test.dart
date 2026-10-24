// `TransactionRow` (03 §9.38; ревью G-flutter-ui-12): цвет и знак суммы — по виду операции (заказ — `textPrimary`
// без знака, даже если сервер прислал `sign=plus`; платёж — `success` «+»; возврат/аннулирование — «−»), знак сервера —
// только для неизвестного вида; на compact заголовок с номером не обрезается (до 2 строк).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/design_system/components/transaction_row.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

Widget _wrap(Widget child, {double width = 360}) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  test('toneOf: вид операции важнее знака сервера', () {
    expect(TransactionRow.toneOf(TransactionKind.orderCreated, plus: true), TransactionRowAmountTone.neutral);
    expect(TransactionRow.toneOf(TransactionKind.creditSaleApproved, plus: true), TransactionRowAmountTone.neutral);
    expect(TransactionRow.toneOf(TransactionKind.discountOverride, plus: false), TransactionRowAmountTone.neutral);
    expect(TransactionRow.toneOf(TransactionKind.returnRequested, plus: false), TransactionRowAmountTone.neutral);
    expect(TransactionRow.toneOf(TransactionKind.paymentReceived, plus: false), TransactionRowAmountTone.incoming);
    expect(TransactionRow.toneOf(TransactionKind.manualQrConfirm), TransactionRowAmountTone.incoming);
    expect(TransactionRow.toneOf(TransactionKind.paymentVoided, plus: true), TransactionRowAmountTone.outgoing);
    expect(TransactionRow.toneOf(TransactionKind.refund), TransactionRowAmountTone.outgoing);
    expect(TransactionRow.toneOf(TransactionKind.orderCancelled), TransactionRowAmountTone.outgoing);
    expect(TransactionRow.toneOf(null, plus: true), TransactionRowAmountTone.incoming);
    expect(TransactionRow.toneOf(null, plus: false), TransactionRowAmountTone.outgoing);
    expect(TransactionRow.toneOf(null), TransactionRowAmountTone.neutral);
  });

  testWidgets('заказ создан (sign=plus) — сумма без «+» цветом textPrimary, не success', (WidgetTester t) async {
    await t.pumpWidget(
      _wrap(
        TransactionRow(
          kind: TransactionKind.orderCreated,
          title: 'Заказ создан № 1025',
          amountText: '16 007,50 сом',
          tone: TransactionRow.toneOf(TransactionKind.orderCreated, plus: true),
        ),
        width: 600,
      ),
    );
    final Text amount = t.widget<Text>(find.text('16 007,50 сом'));
    expect(amount.style?.color, DsColors.lightB.textPrimary);
    expect(find.text('+16 007,50 сом'), findsNothing);
  });

  testWidgets('платёж — «+» цветом success', (WidgetTester t) async {
    await t.pumpWidget(
      _wrap(
        TransactionRow(
          kind: TransactionKind.paymentReceived,
          title: 'Платёж получен № 1024',
          amountText: '16 007,50 сом',
          tone: TransactionRow.toneOf(TransactionKind.paymentReceived, plus: true),
        ),
        width: 600,
      ),
    );
    expect(t.widget<Text>(find.text('+16 007,50 сом')).style?.color, DsColors.lightB.success);
  });

  testWidgets('compact: заголовок с номером переносится на 2 строки, а не обрезается', (WidgetTester t) async {
    const String title = 'Платёж получен № 1024 · ОсОО «СтройМир Бишкек»';
    await t.pumpWidget(
      _wrap(
        const TransactionRow(
          kind: TransactionKind.paymentReceived,
          title: title,
          subtitle: '22.10.2026 09:42 · Абдулла',
          amountText: '16 007,50 сом',
          tone: TransactionRowAmountTone.incoming,
          compactWindow: true,
        ),
      ),
    );
    expect(t.widget<Text>(find.text(title)).maxLines, 2);
  });

  testWidgets('широкая строка — заголовок в одну строку', (WidgetTester t) async {
    await t.pumpWidget(
      _wrap(
        const TransactionRow(kind: TransactionKind.refund, title: 'Возврат № 7', amountText: '100,00 сом'),
        width: 900,
      ),
    );
    expect(t.widget<Text>(find.text('Возврат № 7')).maxLines, 1);
  });
}

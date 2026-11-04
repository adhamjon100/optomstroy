// Измерение ширины текста `dsTextWidth` / `dsTextWidthWith`: кэш и сброс при смене шрифтов (`systemFonts`) — номер
// набора шрифтов `dsTextMeasureEpoch` растёт, экраны перестраиваются (ревью R2C-12, R2C-14).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('смена шрифтов: запомненные ширины сбрасываются, dsTextMeasureEpoch растёт', () async {
    const TextStyle style = TextStyle(fontSize: 14);
    final double before = dsTextWidthWith('Каталог', style);
    expect(before, greaterThan(0));
    expect(dsTextWidthWith('Каталог', style), before, reason: 'из кэша — то же значение');
    final int epoch = dsTextMeasureEpoch.value;
    int notified = 0;
    void listener() => notified++;
    dsTextMeasureEpoch.addListener(listener);
    addTearDown(() => dsTextMeasureEpoch.removeListener(listener));
    // Платформа сообщает о смене набора шрифтов (как после поздней загрузки шрифта в вебе).
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.system.name,
      SystemChannels.system.codec.encodeMessage(<String, Object?>{'type': 'fontsChange'}),
      (ByteData? _) {},
    );
    expect(dsTextMeasureEpoch.value, epoch + 1);
    expect(notified, 1);
    expect(dsTextWidthWith('Каталог', style), before, reason: 'измерено заново тем же шрифтом');
  });

  test('масштаб шрифта входит в ключ: 1,3 — шире', () {
    const TextStyle style = TextStyle(fontSize: 14);
    expect(
      dsTextWidthWith('10 450,00 сом', style, scaler: const TextScaler.linear(1.3)),
      greaterThan(dsTextWidthWith('10 450,00 сом', style)),
    );
  });
}

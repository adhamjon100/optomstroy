// RM-E-010 п. 1: последовательность клавиш с суффиксом быстрее порога — скан; ручной ввод — нет;
// обрыв без суффикса. Автомат HidWedgeDetector — чистый Dart, время задаётся явно.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/hardware/barcode_value.dart';
import 'package:optomstroy/core/hardware/hid_wedge_detector.dart';
import 'package:optomstroy/core/hardware/scanner_wedge_config.dart';

const String ean = '4607012345678';

Duration ms(int v) => Duration(milliseconds: v);

/// Подаёт символы [text] с интервалом [step], начиная с [from]; возвращает время последнего символа.
(Duration, List<HidKeyOutcome>) type(HidWedgeDetector d, String text, {required Duration step, Duration? from}) {
  var at = from ?? Duration.zero;
  final out = <HidKeyOutcome>[];
  for (var i = 0; i < text.length; i++) {
    if (i > 0) at += step;
    out.add(d.onCharacter(text[i], at));
  }
  return (at, out);
}

void main() {
  group('скан с окончанием Enter (порог 50 мс)', () {
    test('символы через 10 мс + Enter через 10 мс → скан, символы 2…N — часть серии', () {
      final d = HidWedgeDetector();
      final (last, outs) = type(d, ean, step: ms(10));
      expect(outs.first.role, HidKeyRole.start);
      expect(outs.skip(1).every((o) => o.role == HidKeyRole.continuation), isTrue);
      final end = d.onSuffixKey(ScannerSuffix.enter, last + ms(10));
      expect(end.role, HidKeyRole.scanSuffix);
      expect(end.detection, const HidDetection(HidDetectionKind.scan, ean));
      expect(d.pendingLength, 0);
    });

    test('интервал 49 мс — ещё скан, 50 мс — уже ручной ввод (порог строгий)', () {
      final fast = HidWedgeDetector();
      final (last, _) = type(fast, '12345', step: ms(49));
      expect(fast.onSuffixKey(ScannerSuffix.enter, last + ms(5)).detection?.kind, HidDetectionKind.scan);

      final slow = HidWedgeDetector();
      final (last2, outs) = type(slow, '12345', step: ms(50));
      expect(outs.every((o) => o.role == HidKeyRole.start), isTrue);
      final end = slow.onSuffixKey(ScannerSuffix.enter, last2 + ms(5));
      expect(end.role, HidKeyRole.plainSuffix);
      expect(end.detection, isNull);
    });

    test('ручной ввод (120 мс между клавишами) + Enter — не скан, Enter проходит дальше', () {
      final d = HidWedgeDetector();
      final (last, outs) = type(d, '4607012', step: ms(120));
      expect(outs.map((o) => o.role).toSet(), <HidKeyRole>{HidKeyRole.start});
      expect(outs.every((o) => o.detection == null), isTrue);
      final end = d.onSuffixKey(ScannerSuffix.enter, last + ms(150));
      expect(end.role, HidKeyRole.plainSuffix);
      expect(end.detection, isNull);
    });

    test('порог из настроек: при 30 мс интервал 40 мс — ручной ввод', () {
      final d = HidWedgeDetector(const ScannerWedgeConfig(interKeyThreshold: Duration(milliseconds: 30)));
      final (last, _) = type(d, '123456', step: ms(40));
      expect(d.onSuffixKey(ScannerSuffix.enter, last + ms(5)).detection, isNull);
    });

    test('короче 3 символов — не скан', () {
      final d = HidWedgeDetector();
      final (last, _) = type(d, '12', step: ms(5));
      final end = d.onSuffixKey(ScannerSuffix.enter, last + ms(5));
      expect(end.role, HidKeyRole.plainSuffix);
      expect(end.detection, isNull);
    });

    test('ручной символ перед быстрой серией не попадает в значение', () {
      final d = HidWedgeDetector()..onCharacter('x', Duration.zero);
      final (last, _) = type(d, ean, step: ms(8), from: ms(400));
      expect(d.onSuffixKey(ScannerSuffix.enter, last + ms(8)).detection?.value, ean);
    });

    test('Enter без символов — обычная клавиша', () {
      final d = HidWedgeDetector();
      expect(d.onSuffixKey(ScannerSuffix.enter, ms(100)).role, HidKeyRole.plainSuffix);
    });

    test('прочая клавиша (стрелка) сбрасывает серию', () {
      final d = HidWedgeDetector();
      final (last, _) = type(d, '123456', step: ms(5));
      expect(d.onOtherKey(last + ms(5)).role, HidKeyRole.other);
      expect(d.onSuffixKey(ScannerSuffix.enter, last + ms(10)).detection, isNull);
    });
  });

  group('обрыв без суффикса', () {
    test('быстрая серия без Enter: до 300 мс — ждём, после — обрыв', () {
      final d = HidWedgeDetector();
      final (last, _) = type(d, ean, step: ms(10));
      expect(d.nextDeadline, last + ms(300));
      expect(d.onIdle(last + ms(299)), isNull);
      expect(d.onIdle(last + ms(300)), const HidDetection(HidDetectionKind.incomplete, ean));
      expect(d.pendingLength, 0);
      expect(d.nextDeadline, isNull);
    });

    test('Enter позже 300 мс после серии — обрыв, Enter не поглощается', () {
      final d = HidWedgeDetector();
      final (last, _) = type(d, ean, step: ms(10));
      final end = d.onSuffixKey(ScannerSuffix.enter, last + ms(350));
      expect(end.role, HidKeyRole.plainSuffix);
      expect(end.detection?.kind, HidDetectionKind.incomplete);
    });

    test('после серии пришёл медленный символ — серия завершена обрывом', () {
      final d = HidWedgeDetector();
      final (last, _) = type(d, ean, step: ms(10));
      final next = d.onCharacter('9', last + ms(200));
      expect(next.role, HidKeyRole.start);
      expect(next.detection, const HidDetection(HidDetectionKind.incomplete, ean));
    });

    test('ожидается Enter, а сканер прислал Tab — обрыв (подсказка SCR-42), Tab проходит дальше', () {
      final d = HidWedgeDetector();
      final (last, _) = type(d, ean, step: ms(10));
      final end = d.onSuffixKey(ScannerSuffix.tab, last + ms(10));
      expect(end.role, HidKeyRole.plainSuffix);
      expect(end.detection?.kind, HidDetectionKind.incomplete);
    });

    test('суффикс Tab в настройках: Tab завершает скан', () {
      final d = HidWedgeDetector(const ScannerWedgeConfig(suffix: ScannerSuffix.tab));
      final (last, _) = type(d, 'AB-1234', step: ms(10));
      expect(
        d.onSuffixKey(ScannerSuffix.tab, last + ms(10)).detection,
        const HidDetection(HidDetectionKind.scan, 'AB-1234'),
      );
    });
  });

  group('«Без суффикса»', () {
    test('серия завершается паузой 150 мс — скан', () {
      final d = HidWedgeDetector(const ScannerWedgeConfig(suffix: ScannerSuffix.none));
      final (last, _) = type(d, ean, step: ms(10));
      expect(d.nextDeadline, last + ms(150));
      expect(d.onIdle(last + ms(149)), isNull);
      expect(d.onIdle(last + ms(150)), const HidDetection(HidDetectionKind.scan, ean));
    });

    test('Enter сразу после серии тоже завершает скан и поглощается', () {
      final d = HidWedgeDetector(const ScannerWedgeConfig(suffix: ScannerSuffix.none));
      final (last, _) = type(d, ean, step: ms(10));
      final end = d.onSuffixKey(ScannerSuffix.enter, last + ms(10));
      expect(end.role, HidKeyRole.scanSuffix);
      expect(end.detection?.kind, HidDetectionKind.scan);
    });

    test('ручной ввод не даёт скана и по паузе', () {
      final d = HidWedgeDetector(const ScannerWedgeConfig(suffix: ScannerSuffix.none));
      final (last, _) = type(d, '12345', step: ms(200));
      expect(d.nextDeadline, isNull);
      expect(d.onIdle(last + ms(1000)), isNull);
    });
  });

  group('настройки и формат кода', () {
    test('JSON настроек: туда-обратно; битые и недопустимые значения — по умолчанию', () {
      const c = ScannerWedgeConfig(suffix: ScannerSuffix.tab, interKeyThreshold: Duration(milliseconds: 80));
      expect(ScannerWedgeConfig.fromJson(c.toJson()), c);
      expect(
        ScannerWedgeConfig.decode('{"suffix":"none","interKeyMs":7}'),
        const ScannerWedgeConfig(suffix: ScannerSuffix.none),
      );
      expect(ScannerWedgeConfig.decode('not json'), const ScannerWedgeConfig());
      expect(ScannerWedgeConfig.decode(null), const ScannerWedgeConfig());
      expect(ScannerSuffix.parse('tab'), ScannerSuffix.tab);
      expect(ScannerSuffix.parse('???'), ScannerSuffix.enter);
    });

    test('BarcodeValue: 3…64 символа [0-9A-Za-z-]', () {
      expect(BarcodeValue.isValid(ean), isTrue);
      expect(BarcodeValue.isValid('AB-12'), isTrue);
      expect(BarcodeValue.isValid(' 123 '), isTrue);
      expect(BarcodeValue.isValid('12'), isFalse);
      expect(BarcodeValue.isValid('1' * 65), isFalse);
      expect(BarcodeValue.isValid('12/34'), isFalse);
      expect(BarcodeValue.isValid('абв123'), isFalse);
    });
  });
}

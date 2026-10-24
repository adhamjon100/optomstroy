// Clock, Debouncer, AppVersion, PiiMasker.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/app_version.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/debouncer.dart';
import 'package:optomstroy/core/utils/pii_masker.dart';

void main() {
  group('Clock', () {
    test('SystemClock — UTC', () {
      final now = const SystemClock().nowUtc();
      expect(now.isUtc, isTrue);
      expect(DateTime.now().toUtc().difference(now).inSeconds.abs(), lessThan(5));
    });

    test('FixedClock: set, advance, nowMillis', () {
      final clock = FixedClock(DateTime.utc(2026, 10, 21, 9));
      expect(clock.nowUtc(), DateTime.utc(2026, 10, 21, 9));
      clock.advance(const Duration(minutes: 30));
      expect(clock.nowUtc(), DateTime.utc(2026, 10, 21, 9, 30));
      clock.set(DateTime.utc(2027));
      expect(clock.nowMillis(), DateTime.utc(2027).millisecondsSinceEpoch);
    });
  });

  group('Debouncer', () {
    testWidgets('выполняет только последний вызов после паузы', (tester) async {
      final debouncer = Debouncer(Debouncer.search);
      final calls = <int>[];
      debouncer(() => calls.add(1));
      await tester.pump(const Duration(milliseconds: 200));
      debouncer(() => calls.add(2));
      expect(debouncer.isPending, isTrue);
      await tester.pump(const Duration(milliseconds: 299));
      expect(calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(calls, [2]);
      expect(debouncer.isPending, isFalse);
      debouncer.dispose();
    });

    testWidgets('cancel отменяет запланированный вызов', (tester) async {
      final debouncer = Debouncer(Debouncer.cart);
      var called = false;
      debouncer(() => called = true);
      debouncer.cancel();
      await tester.pump(const Duration(seconds: 1));
      expect(called, isFalse);
      expect(debouncer.isPending, isFalse);
    });
  });

  group('AppVersion', () {
    test('разбор и сравнение', () {
      expect(AppVersion.tryParse('1.4.2+87'), const AppVersion(1, 4, 2));
      expect(AppVersion.tryParse('v2'), const AppVersion(2, 0, 0));
      expect(AppVersion.tryParse('1.2'), const AppVersion(1, 2, 0));
      expect(AppVersion.tryParse('x.y'), isNull);
      expect(const AppVersion(1, 2, 0) < const AppVersion(1, 10, 0), isTrue);
      expect(const AppVersion(1, 2, 3).compareTo(const AppVersion(1, 2, 3)), 0);
      expect(AppVersion.tryParse('1.2.0-rc.1')! < const AppVersion(1, 2, 0), isTrue);
      expect(const AppVersion(1, 2, 0).compareTo(AppVersion.tryParse('1.2.0-rc.1')!), 1);
      expect(AppVersion.tryParse('1.2.0-rc.1')! < AppVersion.tryParse('1.2.0-rc.2')!, isTrue);
      expect(AppVersion.tryParse('1.2.0-rc.1').toString(), '1.2.0-rc.1');
      expect(const AppVersion(1, 2, 0).hashCode, AppVersion.tryParse('1.2.0+5').hashCode);
    });

    test('platform=semver через запятую', () {
      final map = AppVersion.parseByPlatform('android=1.2.0, windows=1.3.0,bad,=1.0.0,ios=x,a=b=c');
      expect(map, {'android': const AppVersion(1, 2, 0), 'windows': const AppVersion(1, 3, 0)});
      expect(AppVersion.forPlatform('android=1.2.0,windows=1.3.0', 'windows'), const AppVersion(1, 3, 0));
      expect(AppVersion.forPlatform('1.5.0', 'android'), const AppVersion(1, 5, 0));
      expect(AppVersion.forPlatform('android=1.2.0', 'ios'), isNull);
      expect(AppVersion.forPlatform(null, 'android'), isNull);
      expect(AppVersion.forPlatform('  ', 'android'), isNull);
    });
  });

  group('PiiMasker', () {
    test('телефоны, токены, OTP', () {
      expect(PiiMasker.mask('phone +996 555 123 456 and 0700000005'), 'phone +996***3456 and +996***0005');
      expect(PiiMasker.mask('Authorization: Bearer abc.def-ghi'), 'Authorization: Bearer ***');
      expect(PiiMasker.mask('t=eyJhbGciOi.eyJzdWIi.sig'), 't=***');
      const sample = '{"refreshToken":"secret123","otp":"123456"}'; // check-secrets: allow (тест)
      expect(PiiMasker.mask(sample), '{"refreshToken":"***","otp":"***"}');
      expect(PiiMasker.mask('code 4821 sent'), 'code *** sent');
      expect(PiiMasker.mask('/catalog/products'), '/catalog/products');
    });
  });
}

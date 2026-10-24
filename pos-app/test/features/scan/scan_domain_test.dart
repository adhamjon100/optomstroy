// Домен фичи scan: фильтр кадров камеры (2 кадра подряд, подавление повтора 1,5 с; AC-UI-17-005),
// сценарий «штрихкод → товар» (сервер → NOT_FOUND → офлайн-кэш), разбор режима маршрута.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/scan/domain/camera_code_filter.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';

import 'support/scan_fakes.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  group('CameraCodeFilter', () {
    test('код принимается во 2-м кадре подряд; в одном кадре — нет', () {
      final f = CameraCodeFilter();
      expect(f.onFrame(<String>['A1234'], ms(0)), isNull);
      expect(f.onFrame(<String>['A1234'], ms(100)), 'A1234');
    });

    test('прерывание пустым кадром сбрасывает счёт кадров', () {
      final f = CameraCodeFilter();
      expect(f.onFrame(<String>['A1234'], ms(0)), isNull);
      expect(f.onFrame(const <String>[], ms(100)), isNull);
      expect(f.onFrame(<String>['A1234'], ms(200)), isNull);
      expect(f.onFrame(<String>['A1234'], ms(300)), 'A1234');
    });

    test('удержание того же кода 5 с — принят один раз; после 1,5 с без кода — снова', () {
      final f = CameraCodeFilter();
      var accepted = 0;
      for (var t = 0; t <= 5000; t += 100) {
        if (f.onFrame(<String>['A1234'], ms(t)) != null) accepted++;
      }
      expect(accepted, 1);
      for (var t = 5100; t <= 6600; t += 100) {
        expect(f.onFrame(const <String>[], ms(t)), isNull);
      }
      expect(f.onFrame(<String>['A1234'], ms(6700)), isNull);
      expect(f.onFrame(<String>['A1234'], ms(6800)), 'A1234');
    });

    test('другой код принимается сразу после первого', () {
      final f = CameraCodeFilter()
        ..onFrame(<String>['A1234'], ms(0))
        ..onFrame(<String>['A1234'], ms(100));
      expect(f.onFrame(<String>['B5678'], ms(200)), isNull);
      expect(f.onFrame(<String>['B5678'], ms(300)), 'B5678');
    });
  });

  group('LookupScannedBarcode', () {
    test('сервер нашёл → ScanFound', () async {
      final lookup = FakeScanLookup()..online[eanFound] = const Success<ScanLookupResult>(frap);
      final r = await LookupScannedBarcode(lookup)(eanFound);
      expect((r as ScanFound).result.productId, 'p-frap');
    });

    test('404 NOT_FOUND → ScanNotFound, кэш не спрашивается', () async {
      final lookup = FakeScanLookup()..cached[eanMissing] = frap;
      final r = await LookupScannedBarcode(lookup)(eanMissing);
      expect(r, isA<ScanNotFound>());
      expect((r as ScanNotFound).offline, isFalse);
    });

    test('нет сети → поиск по кэшу barcodes: найден / не найден', () async {
      final lookup = FakeScanLookup()
        ..online[eanFound] = const FailureResult<ScanLookupResult>(NetworkFailure(NetworkFailureKind.offline))
        ..online[eanMissing] = const FailureResult<ScanLookupResult>(NetworkFailure(NetworkFailureKind.timeout))
        ..cached[eanFound] = frap;
      expect(await LookupScannedBarcode(lookup)(eanFound), isA<ScanFound>());
      final miss = await LookupScannedBarcode(lookup)(eanMissing);
      expect((miss as ScanNotFound).offline, isTrue);
    });

    test('5xx → ScanLookupFailed (код сохраняется для «Повторить»)', () async {
      final lookup = FakeScanLookup()
        ..online[eanFound] = const FailureResult<ScanLookupResult>(ServerFailure(code: 'INTERNAL', status: 500));
      final r = await LookupScannedBarcode(lookup)(eanFound);
      expect((r as ScanLookupFailed).value, eanFound);
    });
  });

  test('ScanMode.parse: значения 02 §4.1, по умолчанию search', () {
    expect(ScanMode.parse('add'), ScanMode.add);
    expect(ScanMode.parse('order'), ScanMode.order);
    expect(ScanMode.parse('test'), ScanMode.test);
    expect(ScanMode.parse(null), ScanMode.search);
    expect(ScanMode.parse('x'), ScanMode.search);
    expect(ScanMode.order.looksUpProduct, isFalse);
  });
}

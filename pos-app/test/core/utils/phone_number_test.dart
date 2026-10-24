// Телефон +996 (R3 §10): нормализация вставки, E.164, шаблон «+996 XXX XXX XXX».
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/phone_number.dart';

void main() {
  group('PhoneNumber.tryParse', () {
    test('T-AUTH-023: варианты ввода нормализуются в E.164', () {
      for (final input in [
        '555123456',
        '0555123456',
        '996555123456',
        '+996555123456',
        '+996 555 123 456',
        '+996 (555) 12-34-56',
        ' 0 555 12 34 56 ',
      ]) {
        expect(PhoneNumber.tryParse(input)?.e164, '+996555123456', reason: input);
      }
    });

    test('отклоняются: длина, ведущий 0 в NSN, «+» не перед 996, пусто', () {
      for (final input in [
        '',
        '12345',
        '55512345',
        '5551234567',
        '+7 555 123 456',
        '+0555123456',
        '000000000',
        '99655512345',
      ]) {
        expect(PhoneNumber.tryParse(input), isNull, reason: input);
      }
    });

    test('шаблон показа, маска, NSN', () {
      final phone = PhoneNumber.tryParse('0700000005')!;
      expect(phone.nsn, '700000005');
      expect(phone.grouped, '+996 700 000 005');
      expect(phone.masked, '+996***0005');
      expect(phone.toString(), 'PhoneNumber(+996***0005)');
      expect(phone.toString(), isNot(contains('700000005')));
    });

    test('isMobile по метаданным libphonenumber (KG)', () {
      expect(PhoneNumber.tryParse('+996555123456')!.isMobile, isTrue);
      expect(PhoneNumber.tryParse('+996312123456')!.isMobile, isFalse); // Бишкек, стационарный
    });

    test('равенство по NSN', () {
      expect(PhoneNumber.tryParse('0555123456'), PhoneNumber.tryParse('+996 555 123 456'));
      expect(PhoneNumber.tryParse('0555123456').hashCode, PhoneNumber.tryParse('555123456').hashCode);
      expect(PhoneNumber.tryParse('0555123456') == PhoneNumber.tryParse('0555123457'), isFalse);
    });
  });

  test('tryParseE164 — только строгий формат API', () {
    expect(PhoneNumber.tryParseE164('+996555123456')?.nsn, '555123456');
    expect(PhoneNumber.tryParseE164('996555123456'), isNull);
    expect(PhoneNumber.tryParseE164('+996055123456'), isNull);
    expect(PhoneNumber.tryParseE164('+996 555 123 456'), isNull);
  });
}

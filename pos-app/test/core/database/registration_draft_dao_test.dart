// registration_draft без ПДн: белый список ключей и форм значений (07 §11.2, DATA-299; ревью C-MN-07).
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/registration_draft_dao.dart';

void main() {
  late AppDatabase db;
  late RegistrationDraftDao dao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = RegistrationDraftDao(db);
  });

  tearDown(() => db.close());

  test('шаг, согласия и сфера записываются и читаются', () async {
    await dao.write(RegistrationDraftDao.stepKey, 'consents');
    await dao.write(RegistrationDraftDao.consentsKey, <String, Object?>{'pdn_processing': true, 'marketing': false});
    await dao.write(RegistrationDraftDao.sphereKey, 'construction_company');
    expect(await dao.read(RegistrationDraftDao.stepKey), 'consents');
    expect(await dao.read(RegistrationDraftDao.consentsKey), {'pdn_processing': true, 'marketing': false});
    expect(await dao.read(RegistrationDraftDao.sphereKey), 'construction_company');
    await dao.clear();
    expect(await dao.read(RegistrationDraftDao.stepKey), isNull);
  });

  test('ключи ПДн и прочие ключи вне белого списка отклоняются до записи', () async {
    for (final key in ['full_name', 'birth_year', 'phone', 'pin', 'registration_token', 'otp']) {
      await expectLater(dao.write(key, 'x'), throwsA(isA<RegistrationDraftViolation>()), reason: key);
    }
    expect(() => dao.read('full_name'), throwsA(isA<RegistrationDraftViolation>()));
    expect(await db.select(db.registrationDraft).get(), isEmpty);
  });

  test('T-SESS-021 (часть): значения с ПДн не проходят по форме: телефон, год, ФИО, вложенные данные', () async {
    final bad = <(String, Object)>[
      (RegistrationDraftDao.stepKey, '+996700123456'),
      (RegistrationDraftDao.stepKey, '1990'),
      (RegistrationDraftDao.sphereKey, 'Иванов Иван'),
      (RegistrationDraftDao.sphereKey, <String, Object?>{'name': 'x'}),
      (RegistrationDraftDao.consentsKey, <String, Object?>{'pdn_processing': 'Иванов'}),
      (RegistrationDraftDao.consentsKey, <String, Object?>{'phone_996700123456': true}),
      (RegistrationDraftDao.consentsKey, 'all'),
    ];
    for (final (key, value) in bad) {
      await expectLater(dao.write(key, value), throwsA(isA<RegistrationDraftViolation>()), reason: key);
    }
    expect(await db.select(db.registrationDraft).get(), isEmpty);
    // сообщение исключения не содержит значения
    expect(
      () => RegistrationDraftDao.validate(RegistrationDraftDao.stepKey, '+996700123456'),
      throwsA(isA<RegistrationDraftViolation>().having((e) => e.toString(), 'text', isNot(contains('996')))),
    );
  });
}

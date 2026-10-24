// Черновик регистрации (09 §7.4; 02 §0.4, SCR-03.11; ядро §18.2 п.1, §19.3).
// - ФИО и год рождения (ПДн) — только flutter_secure_storage (`registration.full_name`, `registration.birth_year`),
//   значение — конверт `{"v": <значение>, "exp": <unix-ms>}`: срок 15 мин от последнего изменения;
// - состояние шагов без ПДн (шаг, отметки согласий, код сферы) — drift `registration_draft` через белый список
//   `RegistrationDraftDao`, если БД пользователя открыта; до входа (БД `pos_<user_id>.db` ещё нет) — память
//   процесса (D_spec_questions.md, RM-D-008 №1).
// PIN, номер телефона и `registration_token` сюда не попадают.
import 'dart:convert';

import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/registration_draft_dao.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';

final class RegistrationDraftRepositoryImpl implements RegistrationDraftRepository {
  RegistrationDraftRepositoryImpl({
    required SecureStorage storage,
    required Clock clock,
    AppDatabase? Function()? database,
    this.ttl = const Duration(minutes: 15),
  }) : _storage = storage,
       _clock = clock,
       _database = database ?? (() => null);

  final SecureStorage _storage;
  final Clock _clock;
  final AppDatabase? Function() _database;

  @override
  final Duration ttl;

  /// Состояние шагов до появления БД пользователя.
  _StepState? _memory;

  @override
  Future<RegistrationDraft?> load() async {
    final now = _clock.nowUtc();
    final name = _unwrap(await _storage.read(SecureKey.registrationFullName), now);
    final year = _unwrap(await _storage.read(SecureKey.registrationBirthYear), now);
    final steps = await _readSteps();
    if (name == null && year == null) {
      // Нет действующих ПДн черновика: просроченное удаляется целиком (AC-UI-03-013).
      await clear();
      return null;
    }
    final draft = RegistrationDraft(
      fullName: name ?? '',
      birthYear: year ?? '',
      activitySphere: steps?.sphere,
      personalDataAck: steps?.personalDataAck ?? false,
      activitySphereConsent: steps?.sphereConsent ?? false,
      step: steps?.step ?? RegistrationStep.data,
    );
    return draft.isEmpty ? null : draft;
  }

  @override
  Future<void> save(RegistrationDraft draft) async {
    final exp = _clock.nowUtc().add(ttl).millisecondsSinceEpoch;
    await _writeOrDelete(SecureKey.registrationFullName, draft.fullName.trim().isEmpty ? null : draft.fullName, exp);
    await _writeOrDelete(SecureKey.registrationBirthYear, draft.birthYear.isEmpty ? null : draft.birthYear, exp);
    final state = _StepState(
      step: draft.step,
      sphere: draft.activitySphere,
      personalDataAck: draft.personalDataAck,
      sphereConsent: draft.activitySphereConsent,
    );
    final db = _database();
    if (db == null) {
      _memory = state;
      return;
    }
    final dao = RegistrationDraftDao(db);
    await dao.write(RegistrationDraftDao.stepKey, state.step.code);
    await dao.write(RegistrationDraftDao.consentsKey, <String, Object?>{
      'personal_data': state.personalDataAck,
      'activity_sphere': state.sphereConsent,
    });
    if (state.sphere != null) {
      // Код `private` и другие — [a-z_], проходят белый список DAO.
      await dao.write(RegistrationDraftDao.sphereKey, state.sphere!.code);
    }
  }

  @override
  Future<void> clear() async {
    _memory = null;
    await _storage.deleteAll(SecureKey.registration);
    final db = _database();
    if (db != null) await RegistrationDraftDao(db).clear();
  }

  Future<void> _writeOrDelete(SecureKey key, String? value, int exp) async {
    if (value == null) {
      await _storage.delete(key);
    } else {
      await _storage.write(key, jsonEncode(<String, Object?>{'v': value, 'exp': exp}));
    }
  }

  String? _unwrap(String? raw, DateTime now) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      final value = json['v'];
      final exp = json['exp'];
      if (value is! String || exp is! int) return null;
      return now.millisecondsSinceEpoch < exp ? value : null;
    } on FormatException {
      return null;
    }
  }

  Future<_StepState?> _readSteps() async {
    final db = _database();
    if (db == null) return _memory;
    final dao = RegistrationDraftDao(db);
    final step = RegistrationStep.tryParse(await dao.read(RegistrationDraftDao.stepKey));
    final consents = await dao.read(RegistrationDraftDao.consentsKey);
    final sphere = ActivitySphere.tryParse(await dao.read(RegistrationDraftDao.sphereKey) as String?);
    if (step == null && consents == null && sphere == null) return _memory;
    final map = consents is Map ? consents : const <String, Object?>{};
    return _StepState(
      step: step ?? RegistrationStep.data,
      sphere: sphere,
      personalDataAck: map['personal_data'] == true,
      sphereConsent: map['activity_sphere'] == true,
    );
  }
}

final class _StepState {
  const _StepState({required this.step, required this.personalDataAck, required this.sphereConsent, this.sphere});

  final RegistrationStep step;
  final ActivitySphere? sphere;
  final bool personalDataAck;
  final bool sphereConsent;
}

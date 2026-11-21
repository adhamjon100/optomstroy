// Подключение этого устройства планшетом магазина (13 TAB-2-02; 02 SCR-54.4, SCR-54.11, AC-UI-54-004…AC-UI-54-006,
// AC-UI-54-009, AC-UI-54-016; FLOW-043.S3–S6, A6; 08 §3.17, §4.18.11, §4.18.15; 09 §8.9 п. 1, п. 7; 11 SEC-133
// (исключение), SEC-140; ADR-115 п. 20): форма → step-up → `POST /admin/store-tablets` с `Idempotency-Key` и
// `X-Step-Up-Token` → аварийный код один раз → «Готово» → на устройстве нет токенов, ключей и файла БД администратора
// (`device.id` сохранён), записаны признак и хэш кода, сохранены токены планшета, включено закрепление, сессия
// `kind=kiosk` без промежуточного `unauthenticated`. Сессия администратора, отозванная сервером в той же транзакции, до
// «Готово» не уводит на SCR-01. Контракт DTO SCR-54 — с OpenAPI 1.3.0.
// Трассировка: 12 T-KIOSK-001; 10 KIOSK-002, KIOSK-003. Данные тестовые: UUID-заглушки, без телефонов и ФИО.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/di/overrides.dart' show SessionAdminKioskDevice;
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/data/tablets/dio_admin_tablets_repository.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/presentation/tablets/admin_tablets_screen.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_edit_dialog.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_exit_code_dialog.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/openapi_schemas.dart';
import '../../kiosk/kiosk_lifecycle_support.dart';
import '../support/fake_admin_repository.dart' as admin;
import '../support/fake_admin_tablets.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

/// Администратор, вошедший на устройстве (`sub` access).
const String adminUserId = staffUserId;

/// Другой пользователь этого устройства: его файл БД не трогается.
const String otherUser = otherUserId;

/// Каталог поддержки приложения — временная папка теста.
final class _SupportDir extends PathProviderPlatform {
  _SupportDir(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

/// БД, которая помнит, существовал ли файл администратора в момент закрытия (удаление — только после закрытия).
final class _TrackedDb extends AppDatabase {
  _TrackedDb(this.owner, this.fileAtClose) : super(NativeDatabase.memory());

  final String owner;
  final bool Function() fileAtClose;
  bool? fileExistedAtClose;

  @override
  Future<void> close() {
    fileExistedAtClose ??= fileAtClose();
    return super.close();
  }
}

/// Пользователь сессии для БД — как `sessionUserIdProvider` корня: копия `SessionState.userId`, чтобы БД не зависела от
/// контроллера сессии (прямая зависимость — цикл провайдеров, app/di/overrides.dart `userDatabase`).
final class _UserId extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? id) => state = id;
}

final NotifierProvider<_UserId, String?> _userIdProvider = NotifierProvider<_UserId, String?>(_UserId.new);

/// Ответ подключения (как `201 KioskTokens`).
KioskEnrollment _enrollment() => KioskEnrollment(
  tablet: tablet(kioskTabletId, name: kioskTabletName),
  accessToken: kioskJwt(tag: 'enrolled'),
  refreshToken: 'rk-enrolled', // check-secrets: allow (тест)
  exitCode: kioskExitCode,
);

void main() {
  group('T-KIOSK-001 admin DB file and secrets removed', () {
    late Directory dir;
    late PathProviderPlatform original;

    setUp(() {
      // Две БД одного класса на такт смены пользователя — как у корня; прежняя закрывается после такта.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      original = PathProviderPlatform.instance;
      dir = Directory.systemTemp.createTempSync('wpa05_support_');
      PathProviderPlatform.instance = _SupportDir(dir.path);
    });

    tearDown(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
      PathProviderPlatform.instance = original;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    File dbFile(String userId, [String suffix = '']) =>
        File(p.join(dir.path, '${AppDatabase.fileNameFor(userId)}$suffix'));

    test('«Готово» (корневой порт → SessionController.becomeKiosk): токены, ключи и файл БД администратора удалены '
        '(device.id сохранён), признак и хэш кода записаны, токены планшета сохранены, закрепление включено', () async {
      for (final String suffix in <String>['', '-wal', '-shm']) {
        dbFile(adminUserId, suffix).writeAsStringSync('admin');
      }
      dbFile(otherUser).writeAsStringSync('other');
      final List<_TrackedDb> opened = <_TrackedDb>[];
      final FakeKioskLock lock = FakeKioskLock();
      final SessionHarness h = SessionHarness(
        (RequestOptions o) async {
          if (o.path.endsWith('/catalog/products')) return json(401, problem('SESSION_REVOKED', 401));
          if (o.path.endsWith('/settings/public')) return json(200, publicSettingsBody());
          return json(200, <String, Object?>{'ok': true});
        },
        overrides: <Override>[
          ...kioskOverrides(lock),
          // Как корень (`userDatabase`): файл — по пользователю сессии, прежний закрывается после такта.
          appDatabaseProvider.overrideWith((Ref ref) {
            final String? id = ref.watch(_userIdProvider);
            if (id == null) return null;
            final _TrackedDb db = _TrackedDb(id, () => dbFile(adminUserId).existsSync());
            opened.add(db);
            ref.onDispose(() => unawaited(Future<void>.delayed(Duration.zero, db.close)));
            return db;
          }),
        ],
      );
      addTearDown(h.dispose);
      final Provider<AdminKioskDevice> port = Provider<AdminKioskDevice>(SessionAdminKioskDevice.new);
      // Мост корня (`featureBridgesProvider`): пользователь сессии → БД пользователя.
      h.container.listen<String?>(
        sessionControllerProvider.select((SessionState s) => s.userId),
        (_, String? next) => h.container.read(_userIdProvider.notifier).set(next),
        fireImmediately: true,
      );
      h.start();
      await h.controller.establish(
        accessToken: fakeJwt(sub: adminUserId, tag: 'admin'),
        refreshToken: 'ra1',
      );
      expect(h.container.read(appDatabaseProvider), same(opened.single));
      h.container.read(authSessionProvider.notifier).signedIn(SessionProfile.unknown);
      h.storage.values
        ..[SecureKey.biometricsEnabled] = 'true'
        // Признак «Windows Hello перед PIN» администратора (вне ключей сессии; 09 BIO-034, BIO-037; 11 SEC-145).
        ..[SecureKey.helloGateUsers] = '["$adminUserId"]'
        ..[SecureKey.profileCache] = '{"roles":["admin"]}'
        ..[SecureKey.profileDisplayName] = 'Администратор (тест)'
        ..[SecureKey.registrationFullName] = 'Черновик (тест)'
        ..[SecureKey.registrationBirthYear] = '1990'
        ..[SecureKey.pendingLogout] = '{"sid":"s-old"}';

      final AdminKioskDevice device = h.container.read(port);
      device.holdSession();
      // Сервер уже отозвал сессию администратора: фоновый запрос получает 401 — до «Готово» на SCR-01 не уходим.
      await fails(h.dio.get<Object?>('/catalog/products'));
      await settle();
      expect(h.state.status, SessionStatus.authenticated);
      expect(h.state.userKind, UserKind.staff);
      expect(h.state.endReason, isNull);

      final List<SessionStatus> statuses = <SessionStatus>[];
      h.container.listen<SessionStatus>(
        sessionControllerProvider.select((SessionState s) => s.status),
        (_, SessionStatus next) => statuses.add(next),
      );
      // Ответ подключения — один экземпляр: `exp` access берётся от реальных часов (fakeJwt), второй вызов под
      // нагрузкой мог бы попасть в следующую секунду.
      final KioskEnrollment enrolled = _enrollment();
      await device.become(enrolled);
      await settle();

      // Переход администратор → планшет без промежуточного `unauthenticated` (иначе G-1 → SCR-01).
      expect(statuses, isNot(contains(SessionStatus.unauthenticated)));
      expect(h.state.isKioskSession, isTrue);
      expect(h.state.userId, kioskUserId);
      expect(h.state.kioskTabletId, kioskTabletId);
      expect(h.state.lock, isNull);
      expect(h.tokens.accessToken, enrolled.accessToken);

      final Map<SecureKey, String> kept = h.storage.values;
      expect(kept[SecureKey.deviceId], testDeviceId, reason: 'device.id сохраняется (08 §2.2)');
      expect(kept[SecureKey.refreshToken], 'rk-enrolled');
      for (final SecureKey k in <SecureKey>[
        SecureKey.biometricsEnabled,
        SecureKey.helloGateUsers,
        SecureKey.profileCache,
        SecureKey.profileDisplayName,
        SecureKey.registrationFullName,
        SecureKey.registrationBirthYear,
        SecureKey.pendingLogout,
      ]) {
        expect(kept.containsKey(k), isFalse, reason: '${k.storageKey}: ключ администратора удалён');
      }
      expect(kept[SecureKey.kioskTabletId], kioskTabletId);
      expect(kept[SecureKey.kioskTabletName], kioskTabletName);
      expect(kept[SecureKey.kioskUserId], kioskUserId);
      expect(kept[SecureKey.kioskExitHash], isNotEmpty);
      expect(kept[SecureKey.kioskExitSalt], isNotEmpty);
      expect(kept.values.any((String v) => v.contains(kioskExitCode)), isFalse, reason: 'код — только хэшем');

      // Файл БД администратора и его журналы удалены — после закрытия; чужой файл на месте.
      final _TrackedDb adminDb = opened.firstWhere((_TrackedDb d) => d.owner == adminUserId);
      expect(adminDb.fileExistedAtClose, isTrue, reason: 'файл удаляется после закрытия БД');
      for (final String suffix in <String>['', '-wal', '-shm']) {
        expect(dbFile(adminUserId, suffix).existsSync(), isFalse, reason: 'pos_<admin>.db$suffix');
      }
      expect(dbFile(otherUser).existsSync(), isTrue);
      expect(h.container.read(appDatabaseProvider), isA<_TrackedDb>().having((d) => d.owner, 'owner', kioskUserId));

      // Закрепление включено, `X-Kiosk-Lock: on`; профиль входа администратора (память фичи auth) сброшен.
      expect(lock.count('enable'), 1);
      await h.dio.get<Object?>('/settings/public');
      expect(h.adapter.requests.last.headers[ApiHeaders.kioskLock], 'on');
      expect(h.container.read(authSessionProvider).status, AuthSessionStatus.signedOut);
    });

    test('поздний 401 запроса администратора сразу после «Готово» сессию планшета не завершает; после окна — '
        '«Подключите заново»', () async {
      final FakeKioskLock lock = FakeKioskLock();
      final SessionHarness h = SessionHarness((RequestOptions o) async {
        if (o.path.endsWith('/late')) return json(401, problem('SESSION_REVOKED', 401));
        return json(200, <String, Object?>{'ok': true});
      }, overrides: kioskOverrides(lock));
      addTearDown(h.dispose);
      h.start();
      await h.controller.establish(
        accessToken: fakeJwt(sub: adminUserId),
        refreshToken: 'ra1',
      );
      h.controller.holdForKioskEnrollment();
      await h.controller.becomeKiosk(
        tabletId: kioskTabletId,
        tabletName: kioskTabletName,
        exitCode: kioskExitCode,
        accessToken: kioskJwt(tag: 'enrolled'),
        refreshToken: 'rk-enrolled', // check-secrets: allow (тест)
      );
      await fails(h.dio.get<Object?>('/late'));
      await settle();
      expect(h.state.isKioskSession, isTrue);
      expect(h.storage.values[SecureKey.refreshToken], 'rk-enrolled', reason: 'токены планшета восстановлены');

      h.clock.advance(const Duration(minutes: 1));
      await fails(h.dio.get<Object?>('/late'));
      await settle();
      expect(h.state.kioskReconnectNeeded, isTrue, reason: 'после окна — обычный SESSION_REVOKED планшета (G-0a)');
      expect(lock.count('disable'), 0, reason: 'закрепление не снимается');
    });

    test('подключение не состоялось: удержанный конец сессии администратора выполняется (SCR-01)', () async {
      final SessionHarness h = SessionHarness(
        (RequestOptions o) async => json(401, problem('SESSION_REVOKED', 401)),
        overrides: kioskOverrides(FakeKioskLock()),
      );
      addTearDown(h.dispose);
      h.start();
      await h.controller.establish(
        accessToken: fakeJwt(sub: adminUserId),
        refreshToken: 'ra1',
      );
      h.controller.holdForKioskEnrollment();
      await fails(h.dio.get<Object?>('/admin/store-tablets'));
      await settle();
      expect(h.state.status, SessionStatus.authenticated);
      h.controller.releaseKioskEnrollment();
      await settle();
      expect(h.state.status, SessionStatus.unauthenticated);
      expect(h.state.endReason, SessionEndReason.revoked);
      expect(h.storage.values.containsKey(SecureKey.kioskTabletId), isFalse);
    });

    test('access не kind=kiosk → ArgumentError, данные администратора не тронуты', () async {
      final SessionHarness h = SessionHarness(
        (RequestOptions o) async => json(200, <String, Object?>{}),
        overrides: kioskOverrides(FakeKioskLock()),
      );
      addTearDown(h.dispose);
      h.start();
      await h.controller.establish(
        accessToken: fakeJwt(sub: adminUserId),
        refreshToken: 'ra1',
      );
      h.storage.values[SecureKey.profileDisplayName] = 'Администратор (тест)';
      await expectLater(
        h.controller.becomeKiosk(
          tabletId: kioskTabletId,
          exitCode: kioskExitCode,
          accessToken: fakeJwt(sub: adminUserId),
          refreshToken: 'rk1',
        ),
        throwsArgumentError,
      );
      expect(h.storage.values[SecureKey.profileDisplayName], isNotNull);
      expect(h.storage.values[SecureKey.refreshToken], 'ra1');
      expect(h.state.userKind, UserKind.staff);
    });

    test('AppDatabase.deleteUserDatabase: файл и журналы пользователя удаляются, чужой файл — нет', () async {
      for (final String suffix in <String>['', '-wal', '-shm', '-journal']) {
        dbFile(adminUserId, suffix).writeAsStringSync('x');
      }
      dbFile(otherUser).writeAsStringSync('y');
      expect(await AppDatabase.deleteUserDatabase(adminUserId), isTrue);
      expect(dir.listSync().map((FileSystemEntity e) => p.basename(e.path)), <String>[
        AppDatabase.fileNameFor(otherUser),
      ]);
      expect(await AppDatabase.deleteUserDatabase(adminUserId), isTrue, reason: 'файлов нет — повтор без ошибки');
    });
  });

  group('T-KIOSK-001 SCR-54 подключение (widget)', () {
    Future<void> openForm(WidgetTester tester) async {
      await tester.tap(find.byKey(AdminTabletsScreen.enrollKey));
      await admin.settle(tester);
    }

    Finder nameField() => find.descendant(of: find.byKey(TabletFormDialog.nameKey), matching: find.byType(TextField));

    testWidgets('T-KIOSK-001 форма (склад кассы по умолчанию) → 403 STEP_UP_REQUIRED → StepUpDialog → повтор с '
        'тем же Idempotency-Key и X-Step-Up-Token → код один раз → «Готово» → режим планшета (AC-UI-54-004…006, '
        'AC-UI-54-016)', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository();
      final FakeKioskDevice device = FakeKioskDevice();
      final admin.FakeStepUpPrompter prompter = admin.FakeStepUpPrompter();
      await admin.pumpAdmin(
        tester,
        const AdminTabletsScreen(),
        overrides: tabletsOverrides(repo, device: device, prompter: prompter),
      );
      await admin.settle(tester);
      await openForm(tester);
      expect(find.text(l10n.kiosk_admin_name_label), findsOneWidget);
      expect(find.text('Основной'), findsOneWidget, reason: 'склад по умолчанию — склад кассы (isDefaultForPos)');
      expect(find.text('Закрытый'), findsNothing, reason: 'неактивные склады не предлагаются');

      await tester.enterText(nameField(), '  Планшет у входа ');
      await tester.tap(find.byKey(TabletFormDialog.submitKey));
      await admin.settle(tester);

      final List<admin.RepoCall> calls = repo.calls.where((admin.RepoCall c) => c.method == 'enroll').toList();
      expect(calls, hasLength(2));
      expect(calls.first.stepUpToken, isNull);
      expect(calls.last.stepUpToken, 'step-up-token');
      expect(calls.first.idempotencyKey, isNotNull);
      expect(calls.last.idempotencyKey, calls.first.idempotencyKey);
      expect(calls.last.args, <String, Object?>{'name': 'Планшет у входа', 'warehouseId': warehouseMainId});
      expect(prompter.challenges.single.operation, KioskAdminOperations.manage);
      expect(device.holds, 1, reason: 'сессия администратора удерживается до «Готово»');
      expect(device.releases, 0);

      // UI-54-014: код один раз, группами по 4, без выделения и копирования, под SecureContent; закрыть — только «Готово».
      final String code = repo.issuedCodes.single;
      expect(find.byKey(TabletExitCodeDialog.codeKey), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(TabletExitCodeDialog.codeKey)).data, KioskEnrollment.grouped(code));
      expect(find.byType(SelectableText), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      expect(
        find.ancestor(of: find.byKey(TabletExitCodeDialog.codeKey), matching: find.byType(SecureContent)),
        findsOneWidget,
      );
      expect(find.text(l10n.kiosk_admin_exit_code_keep), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await admin.settle(tester);
      expect(find.byType(TabletExitCodeDialog), findsOneWidget, reason: 'затемнение не закрывает');
      await tester.binding.handlePopRoute();
      await admin.settle(tester);
      expect(find.byType(TabletExitCodeDialog), findsOneWidget, reason: '«Назад» не закрывает');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await admin.settle(tester);
      expect(find.byType(TabletExitCodeDialog), findsOneWidget, reason: 'Esc не закрывает');
      expect(device.became, isEmpty);

      await tester.tap(find.byKey(TabletExitCodeDialog.doneKey));
      await admin.settle(tester);
      final KioskEnrollment became = device.became.single;
      expect(became.exitCode, code);
      expect(became.tablet.name, 'Планшет у входа');
      expect(became.toString(), isNot(contains(code)));
      expect(find.byType(TabletExitCodeDialog), findsNothing);
      expect(find.text(KioskEnrollment.grouped(code)), findsNothing, reason: 'повторно код не показать');
    });

    testWidgets('T-KIOSK-001 повтор после обрыва — тот же ключ (AC-UI-54-009); другое имя — новый ключ; ошибка '
        'склада 404 — у поля', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository()
        ..nextConnectFailure = const NetworkFailure(NetworkFailureKind.timeout);
      final FakeKioskDevice device = FakeKioskDevice();
      await admin.pumpAdmin(
        tester,
        const AdminTabletsScreen(),
        overrides: tabletsOverrides(repo, device: device, prompter: admin.FakeStepUpPrompter()),
      );
      await admin.settle(tester);
      await openForm(tester);
      await tester.enterText(nameField(), 'Планшет у входа');
      await tester.tap(find.byKey(TabletFormDialog.submitKey));
      await admin.settle(tester);
      expect(find.byKey(TabletFormDialog.errorKey), findsOneWidget, reason: 'обрыв — форма открыта, ошибка под ней');
      expect(device.releases, 1, reason: 'не состоялось — удержание снято');

      await tester.tap(find.byKey(TabletFormDialog.submitKey));
      await admin.settle(tester);
      final List<admin.RepoCall> calls = repo.calls.where((admin.RepoCall c) => c.method == 'enroll').toList();
      expect(calls.map((admin.RepoCall c) => c.idempotencyKey).toSet(), hasLength(1), reason: 'повтор — тот же ключ');
      expect(find.byType(TabletExitCodeDialog), findsOneWidget);
      expect(find.text(KioskEnrollment.grouped(repo.issuedCodes.single)), findsOneWidget);
      await tester.tap(find.byKey(TabletExitCodeDialog.doneKey));
      await admin.settle(tester);
      expect(device.became, hasLength(1));

      // Второе подключение с другим именем — новый ключ; 404 склада — ошибка у поля «Склад».
      repo.nextConnectFailure = const ServerFailure(code: 'NOT_FOUND', status: 404);
      await openForm(tester);
      await tester.enterText(nameField(), 'Планшет у кассы');
      await tester.tap(find.byKey(TabletFormDialog.submitKey));
      await admin.settle(tester);
      expect(find.text(l10n.error_not_found), findsOneWidget);
      expect(find.byKey(TabletFormDialog.errorKey), findsNothing);
      final Set<String?> keys = repo.calls
          .where((admin.RepoCall c) => c.method == 'enroll')
          .map((admin.RepoCall c) => c.idempotencyKey)
          .toSet();
      expect(keys, hasLength(2));
    });

    testWidgets('T-KIOSK-001 переход не удался — сессия отпущена, снекбар, диалог закрыт', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository();
      final FakeKioskDevice device = FakeKioskDevice()..failBecome = true;
      await admin.pumpAdmin(
        tester,
        const AdminTabletsScreen(),
        overrides: tabletsOverrides(repo, device: device, prompter: admin.FakeStepUpPrompter()),
      );
      await admin.settle(tester);
      await openForm(tester);
      await tester.enterText(nameField(), 'Планшет у входа');
      await tester.tap(find.byKey(TabletFormDialog.submitKey));
      await admin.settle(tester);
      await tester.tap(find.byKey(TabletExitCodeDialog.doneKey));
      await admin.settle(tester);
      expect(find.byType(TabletExitCodeDialog), findsNothing);
      expect(device.releases, 1);
      expect(find.text(l10n.error_internal), findsOneWidget);
    });
  });

  group('T-KIOSK-001 контракт DTO SCR-54 (OpenAPI 1.3.0)', () {
    final OpenApiSchemas? api = OpenApiSchemas.load(<String>[
      'StoreTablet',
      'KioskTokens',
      'KioskTabletsListResponse',
      'KioskTabletsEnrollRequest',
      'KioskTabletsUpdateRequest',
      'KioskTabletsRevokeRequest',
      'CatalogWarehouse',
      'CatalogWarehousesResponse',
    ]);
    final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

    test('ключи и обязательные поля == схемы', () {
      void matches(String name, Set<String> keys, Set<String> required) {
        expect(keys, api!.props(name), reason: '$name: ключи DTO ≠ properties');
        expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
      }

      matches('StoreTablet', StoreTabletDto.jsonKeys, StoreTabletDto.requiredKeys);
      matches('KioskTokens', KioskTokensDto.jsonKeys, KioskTokensDto.requiredKeys);
      matches('KioskTabletsListResponse', StoreTabletsListDto.jsonKeys, StoreTabletsListDto.requiredKeys);
      matches('CatalogWarehouse', TabletWarehouseDto.jsonKeys, TabletWarehouseDto.requiredKeys);
      expect(StoreTabletRequestDto.enrollKeys, api!.props('KioskTabletsEnrollRequest'));
      expect(StoreTabletRequestDto.enrollKeys, api.required('KioskTabletsEnrollRequest'));
      expect(StoreTabletRequestDto.updateKeys, api.props('KioskTabletsUpdateRequest'));
      expect(StoreTabletRequestDto.revokeKeys, api.props('KioskTabletsRevokeRequest'));
    }, skip: skip);

    test('примеры разбираются; код и токены — не в toString', () {
      final KioskEnrollment e = KioskTokensDto.fromJson(jsonCopy(api!.example('KioskTokens')));
      expect(KioskEnrollment.exitCodePattern.hasMatch(e.exitCode), isTrue);
      expect(e.toString(), isNot(contains(e.exitCode)));
      expect(e.toString(), isNot(contains(e.accessToken)));
      final List<StoreTablet> list = StoreTabletsListDto.fromJson(jsonCopy(api.example('KioskTabletsListResponse')));
      expect(list, isNotEmpty);
      final List<TabletWarehouse> wh = TabletWarehouseDto.listFromJson(
        jsonCopy(api.example('CatalogWarehousesResponse')),
      );
      expect(wh, isNotEmpty);
    }, skip: skip);

    test(
      'Dio: POST с Idempotency-Key и X-Step-Up-Token, reconnect `{}`, PATCH только изменённое, revoke со step-up',
      () async {
        final Map<String, Object?> tabletJson = <String, Object?>{
          'id': kioskTabletId,
          'name': 'Планшет у входа',
          'warehouseId': warehouseMainId,
          'status': 'active',
          'enrolledAt': '2026-11-04T09:00:00Z',
          'reconnectedAt': null,
          'revokedAt': null,
          'lastSeenAt': null,
          'lockTaskEnabled': null,
          'appVersion': null,
          'expiresAt': '2027-05-03T09:00:00Z',
        };
        final Map<String, Object?> tokens = <String, Object?>{
          'tablet': tabletJson,
          'accessToken': 'a.b.c',
          'accessExpiresIn': 900,
          'refreshToken': 'r1',
          'refreshExpiresAt': '2027-05-03T09:00:00Z',
          'sid': '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55',
          'exitCode': '24681357',
        };
        final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
          if (o.method == 'GET' && o.path.endsWith('/admin/store-tablets')) {
            return json(200, <String, Object?>{
              'items': <Object?>[tabletJson],
            });
          }
          if (o.method == 'POST' && (o.path.endsWith('/admin/store-tablets') || o.path.endsWith('/reconnect'))) {
            return json(o.path.endsWith('/reconnect') ? 200 : 201, tokens);
          }
          if (o.method == 'POST' && o.path.endsWith('/revoke')) {
            return json(200, <String, Object?>{
              ...tabletJson,
              'status': 'revoked',
              'revokedAt': '2026-11-05T09:00:00Z',
            });
          }
          if (o.method == 'PATCH') return json(200, <String, Object?>{...tabletJson, 'name': 'Планшет у кассы'});
          return json(404, problem('NOT_FOUND', 404));
        });
        final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;
        final DioAdminTabletsRepository repo = DioAdminTabletsRepository(dio);

        expect((await repo.list()).valueOrNull!.single.expiresAt, DateTime.utc(2027, 5, 3, 9));
        final KioskEnrollment e = (await repo.enroll(
          name: ' Планшет у входа ',
          warehouseId: warehouseMainId,
          idempotencyKey: 'k-1',
          stepUpToken: 'st-1', // check-secrets: allow (тест)
        )).valueOrNull!;
        expect(e.exitCode, '24681357');
        final ({String method, String path, Map<String, Object?> headers, Object? data}) post = adapter.requests.last;
        expect(post.path, '/admin/store-tablets');
        expect(post.headers[ApiHeaders.idempotencyKey], 'k-1');
        expect(post.headers[ApiHeaders.stepUpToken], 'st-1');
        expect(post.data, <String, Object?>{'name': 'Планшет у входа', 'warehouseId': warehouseMainId});

        await repo.reconnect(kioskTabletId, idempotencyKey: 'k-2', stepUpToken: 'st-1');
        expect(adapter.requests.last.path, '/admin/store-tablets/$kioskTabletId/reconnect');
        expect(adapter.requests.last.data, <String, Object?>{});
        expect(adapter.requests.last.headers[ApiHeaders.idempotencyKey], 'k-2');

        final StoreTablet updated = (await repo.update(kioskTabletId, name: 'Планшет у кассы')).valueOrNull!;
        expect(adapter.requests.last.method, 'PATCH');
        expect(adapter.requests.last.data, <String, Object?>{'name': 'Планшет у кассы'});
        expect(adapter.requests.last.headers.containsKey(ApiHeaders.stepUpToken), isFalse);
        expect(updated.name, 'Планшет у кассы');

        final StoreTablet revoked = (await repo.revoke(kioskTabletId, stepUpToken: 'st-1')).valueOrNull!;
        expect(adapter.requests.last.path, '/admin/store-tablets/$kioskTabletId/revoke');
        expect(adapter.requests.last.headers[ApiHeaders.stepUpToken], 'st-1');
        expect(revoked.status, StoreTabletStatus.revoked);

        // Неверный формат аварийного кода — ошибка контракта, а не «код».
        final FakeAdapter bad = FakeAdapter(
          (RequestOptions o) async => json(201, <String, Object?>{...tokens, 'exitCode': '1234'}),
        );
        final Result<KioskEnrollment> broken = await DioAdminTabletsRepository(
          Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = bad,
        ).enroll(name: 'Планшет', warehouseId: warehouseMainId, idempotencyKey: 'k-3');
        expect(broken.failureOrNull, isA<UnknownFailure>());
      },
    );
  });
}

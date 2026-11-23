// Аварийный выход планшета магазина — SCR-51 UI-51-017 (13 TAB-2-10; P-002 §8.9 п. 2; 04 FLOW-043.A1; 08 §4.25.5;
// 09 §8.9 п. 4–5; 11 SEC-140; ADR-115 п. 12, п. 28): со связью код проверяет сервер (`POST /kiosk/exit`), после отказа
// сервера код на устройстве не проверяется; без связи (нет сети, таймаут, `426`, `401 SESSION_REVOKED`,
// `403 KIOSK_DISABLED`, `403 KIOSK_NETWORK_DENIED`) — PBKDF2-HMAC-SHA256 на устройстве, счётчик и пауза 15 мин в
// защищённом хранилище переживают перезапуск. Выход: закрепление снято, признак, хэш и токены удалены, SCR-01.
// Трассировка: 12 T-KIOSK-004, T-KIOSK-033; 02 AC-UI-51-016, AC-UI-51-017.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/app_localizations_ru.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/session/kiosk_exit_code_hash.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/kiosk/data/dio_kiosk_lifecycle_repository.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_state_view.dart';

import '../../core/storage/in_memory_secure_storage.dart';
import 'kiosk_lifecycle_support.dart';

final AppLocalizationsRu _l10n = AppLocalizationsRu();

String _hex(List<int> bytes) => bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Сервер теста: `/auth/refresh` — новая пара планшета, `/kiosk/exit` — [exit], остальное — 200.
FakeHandler _server(ResponseBody Function(RequestOptions o) exit) => (RequestOptions o) async {
  if (o.path.endsWith('/auth/refresh')) return json(200, tokenPair(kioskJwt(tag: 'r'), 'rk2'));
  if (o.path.endsWith('/kiosk/exit')) return exit(o);
  return json(200, <String, Object?>{'ok': true});
};

/// Обвязка: сессия планшета (или без неё — [refresh] `null`), хэш аварийного кода, порт `POST /kiosk/exit`.
Future<SessionHarness> _tablet(
  FakeHandler handler, {
  required FakeKioskLock lock,
  String? refresh = 'rk1',
  bool server = true,
}) async {
  final SessionHarness h = kioskHarness(
    handler,
    lock: lock,
    refresh: refresh,
    overrides: <Override>[
      if (server)
        kioskLifecycleRepositoryProvider.overrideWith((ref) => DioKioskLifecycleRepository(ref.watch(dioProvider))),
    ],
  );
  h.start();
  await h.container.read(sessionStatusProvider.future);
  await rememberExitCode(h);
  return h;
}

KioskEmergencyExit _exit(SessionHarness h) => h.container.read(kioskEmergencyExitProvider);

/// Хранилище аварийного кода недоступно (сбой Keystore): любое чтение и запись бросают.
final class _BrokenStorage implements SecureStorage {
  @override
  Future<String?> read(SecureKey key) async => throw StateError('keystore');

  @override
  Future<void> write(SecureKey key, String value) async => throw StateError('keystore');

  @override
  Future<void> delete(SecureKey key) async => throw StateError('keystore');
}

/// Диалог UI-51-017 отдельно (без маршрутов), контейнер [h].
Future<void> _pumpDialog(WidgetTester tester, SessionHarness h) async {
  tester.view
    ..physicalSize = const Size(1280, 1000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: KioskEmergencyExitDialog()),
      ),
    ),
  );
  await tester.pump();
}

/// Набрать [code] экранными кнопками диалога и нажать «Выйти» (запрос и хэш — в реальном времени).
Future<void> _typeAndSubmit(WidgetTester tester, String code) async {
  for (final String d in code.split('')) {
    await tester.tap(find.byKey(KioskEmergencyExitDialog.keyFor(d)));
    await tester.pump();
  }
  final Finder submit = find.byKey(KioskEmergencyExitDialog.submitKey);
  await tester.ensureVisible(submit);
  await tester.pump();
  await tester.runAsync(() async {
    await tester.tap(submit);
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  await tester.pump();
}

String _errorShown(WidgetTester tester) => tester.widget<Text>(find.byKey(KioskEmergencyExitDialog.errorKey)).data!;

void main() {
  group('PBKDF2-HMAC-SHA256 (RFC 8018) и параметры', () {
    test('известные ответы (сверены с hashlib.pbkdf2_hmac)', () {
      List<int> b(String s) => utf8.encode(s);
      expect(
        _hex(pbkdf2HmacSha256(password: b('password'), salt: b('salt'), iterations: 1)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
      expect(
        _hex(pbkdf2HmacSha256(password: b('password'), salt: b('salt'), iterations: 2)),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
      expect(
        _hex(pbkdf2HmacSha256(password: b('password'), salt: b('salt'), iterations: 4096)),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
      expect(
        _hex(
          pbkdf2HmacSha256(
            password: b('passwordPASSWORDpassword'),
            salt: b('saltSALTsaltSALTsaltSALTsaltSALTsalt'),
            iterations: 4096,
            length: 40,
          ),
        ),
        '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9',
      );
      expect(
        _hex(pbkdf2HmacSha256(password: b('passwd'), salt: b('salt'), iterations: 1, length: 64)),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
      expect(() => pbkdf2HmacSha256(password: b('p'), salt: b('s'), iterations: 0), throwsArgumentError);
    });

    test('SEC-140 п. 4: ≥ 210 000 итераций, соль 16 байт на каждое подключение, кода в открытом виде нет', () async {
      expect(KioskExitCodeStore.defaultIterations, greaterThanOrEqualTo(210000));
      expect(KioskExitCodeStore.saltLength, 16);
      expect(KioskExitCodeStore.maxAttempts, 5);
      expect(KioskExitCodeStore.lockDuration, const Duration(minutes: 15));
      final InMemorySecureStorage storage = InMemorySecureStorage(<SecureKey, String>{});
      writeKioskMarker(storage.values);
      final KioskExitCodeStore store = KioskExitCodeStore(
        storage: storage,
        clock: FixedClock(t0),
        iterations: testExitIterations,
        runner: deriveKioskExitHashNow,
      );
      expect(KioskExitCodeStore(storage: storage, clock: FixedClock(t0)).iterations, 210000);
      await store.remember(code: kioskExitCode, tabletId: kioskTabletId);
      final String first = storage.values[SecureKey.kioskExitHash]!;
      final String salt1 = storage.values[SecureKey.kioskExitSalt]!;
      expect(base64Decode(salt1), hasLength(16));
      expect(first, startsWith('pbkdf2-sha256\$$testExitIterations\$'));
      expect(storage.values.values.where((String v) => v.contains(kioskExitCode)), isEmpty);
      // Подключение заново — новая соль, другой хэш того же кода.
      await store.remember(code: kioskExitCode, tabletId: kioskTabletId);
      expect(storage.values[SecureKey.kioskExitSalt], isNot(salt1));
      expect(storage.values[SecureKey.kioskExitHash], isNot(first));
      expect(await store.verify(kioskExitCode), isA<KioskDeviceExitAccepted>());
      // Хэш привязан к tablet_id: тот же код на другом планшете не подходит.
      storage.values[SecureKey.kioskTabletId] = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4fc9';
      expect(await store.verify(kioskExitCode), isA<KioskDeviceExitInvalid>());
      expect(() => store.remember(code: '1234', tabletId: kioskTabletId), throwsArgumentError);
    });

    test('без хэша на устройстве код не принимается (обхода проверки нет)', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage(<SecureKey, String>{});
      writeKioskMarker(storage.values);
      final KioskExitCodeStore store = KioskExitCodeStore(
        storage: storage,
        clock: FixedClock(t0),
        iterations: testExitIterations,
        runner: deriveKioskExitHashNow,
      );
      expect(await store.verify(kioskExitCode), const TypeMatcher<KioskDeviceExitInvalid>());
    });
  });

  group('T-KIOSK-004 offline device check, counter survives restart', () {
    test(
      'T-KIOSK-004: без связи — 5 неверных → пауза 15 мин, и после перезапуска; верный код после паузы → выход',
      () async {
        final FakeKioskLock lock = FakeKioskLock(locked: true);
        final SessionHarness h = await _tablet(
          _server((RequestOptions o) => transportError(o, DioExceptionType.connectionError)),
          lock: lock,
        );
        addTearDown(h.dispose);
        final KioskEmergencyExit exit = _exit(h);
        for (var left = 4; left >= 2; left--) {
          expect(((await exit.submit(wrongExitCode)) as KioskExitRejected).attemptsLeft, left);
        }
        // Перезапуск между попытками: счётчик в защищённом хранилище.
        final KioskExitCodeStore restarted = KioskExitCodeStore(
          storage: h.storage,
          clock: h.clock,
          iterations: testExitIterations,
          runner: deriveKioskExitHashNow,
        );
        expect(await restarted.verify(wrongExitCode), const TypeMatcher<KioskDeviceExitInvalid>());
        final KioskExitOutcome fifth = await exit.submit(wrongExitCode);
        expect(fifth, isA<KioskExitPaused>());
        expect((fifth as KioskExitPaused).until, t0.add(const Duration(minutes: 15)));
        // Пауза: даже верный код не принимается — и после перезапуска.
        expect(await exit.submit(kioskExitCode), isA<KioskExitPaused>());
        expect(await restarted.verify(kioskExitCode), isA<KioskDeviceExitLocked>());
        expect(await restarted.lockedUntil(), t0.add(const Duration(minutes: 15)));
        expect(h.state.isKioskSession, isTrue);
        expect(lock.locked, isTrue);

        h.clock.advance(const Duration(minutes: 15));
        expect(await exit.submit(kioskExitCode), isA<KioskExitDone>());
        await settle();
        expect(h.state.endReason, SessionEndReason.kioskExitedOffline);
        expect(lock.locked, isFalse, reason: 'закрепление снято');
        for (final SecureKey key in <SecureKey>[...SecureKey.kiosk, SecureKey.refreshToken]) {
          expect(h.storage.values[key], isNull, reason: key.storageKey);
        }
        expect(h.adapter.countPath('/kiosk/exit'), greaterThanOrEqualTo(1), reason: 'сначала — сервер');
      },
    );

    test('T-KIOSK-004: без сессии («Подключите заново») — сразу на устройстве, сервер не вызывается', () async {
      final FakeKioskLock lock = FakeKioskLock(locked: true);
      final SessionHarness h = await _tablet(
        _server((RequestOptions o) => json(200, <String, Object?>{})),
        lock: lock,
        refresh: null,
      );
      addTearDown(h.dispose);
      expect(h.state.kioskReconnectNeeded, isTrue);
      final KioskExitOutcome outcome = await _exit(h).submit(kioskExitCode);
      expect(outcome, isA<KioskExitDone>());
      expect((outcome as KioskExitDone).offline, isTrue);
      expect(h.adapter.countPath('/kiosk/exit'), 0);
      expect(lock.count('disable'), 1);
      expect(h.state.endReason, SessionEndReason.kioskExitedOffline);
    });

    test(
      'T-KIOSK-004: со связью — 200 → выход без проверки на устройстве; 422/423 — на устройстве не проверяется',
      () async {
        var answer = json(422, problem('KIOSK_EXIT_CODE_INVALID', 422, extra: <String, Object?>{'attemptsLeft': 3}));
        final FakeKioskLock lock = FakeKioskLock(locked: true);
        final SessionHarness h = await _tablet(_server((RequestOptions o) => answer), lock: lock);
        addTearDown(h.dispose);
        final KioskEmergencyExit exit = _exit(h);

        // Сервер отказал — устройство код не проверяет (даже верный по локальному хэшу).
        expect(((await exit.submit(kioskExitCode)) as KioskExitRejected).attemptsLeft, 3);
        expect(h.storage.values[SecureKey.kioskExitAttempts], isNull, reason: 'проверки на устройстве не было');

        answer = json(
          423,
          problem('KIOSK_EXIT_LOCKED', 423, extra: <String, Object?>{'retryAfter': 900}),
          headers: <String, String>{ApiHeaders.retryAfter: '900'},
        );
        final KioskExitOutcome paused = await exit.submit(kioskExitCode);
        expect((paused as KioskExitPaused).until, t0.add(const Duration(seconds: 900)));
        expect(h.state.isKioskSession, isTrue);

        answer = json(200, <String, Object?>{});
        expect(await exit.submit(kioskExitCode), isA<KioskExitDone>());
        await settle();
        expect(h.state.endReason, SessionEndReason.kioskExited);
        expect(lock.count('disable'), 1);
        expect(h.storage.values[SecureKey.kioskTabletId], isNull);
        final request = h.adapter.requests.lastWhere((r) => r.path == '/kiosk/exit');
        expect(request.method, 'POST');
        expect(request.data, <String, Object?>{'code': kioskExitCode});
        expect(request.headers.containsKey(ApiHeaders.idempotencyKey), isFalse, reason: 'x-idempotent: false');
        expect(h.adapter.countPath('/kiosk/exit'), 3, reason: 'без автоповтора');
      },
    );

    test('повтор после потерянного 200 → 401 KIOSK_REVOKED → выход завершается как выход', () async {
      final FakeKioskLock lock = FakeKioskLock(locked: true);
      final SessionHarness h = await _tablet(
        _server((RequestOptions o) => json(401, problem('KIOSK_REVOKED', 401))),
        lock: lock,
      );
      addTearDown(h.dispose);
      expect(await _exit(h).submit(kioskExitCode), isA<KioskExitDone>());
      await settle();
      expect(h.state.endReason, SessionEndReason.kioskExited, reason: 'выход, а не «Планшет отключён»');
      expect(h.state.holdsKioskRoute, isFalse);
      expect(lock.locked, isFalse);
    });
  });

  group('T-KIOSK-033 exit via device check on 403 KIOSK_DISABLED and KIOSK_NETWORK_DENIED', () {
    for (final String code in <String>['KIOSK_DISABLED', 'KIOSK_NETWORK_DENIED']) {
      test('T-KIOSK-033: POST /kiosk/exit → 403 $code → код проверен на устройстве, выход без связи', () async {
        final FakeKioskLock lock = FakeKioskLock(locked: true);
        final SessionHarness h = await _tablet(
          _server((RequestOptions o) => json(403, problem(code, 403))),
          lock: lock,
        );
        addTearDown(h.dispose);
        expect(((await _exit(h).submit(wrongExitCode)) as KioskExitRejected).attemptsLeft, 4);
        expect(h.storage.values[SecureKey.kioskExitAttempts], '1', reason: 'проверка на устройстве');
        final KioskExitOutcome done = await _exit(h).submit(kioskExitCode);
        expect((done as KioskExitDone).offline, isTrue);
        await settle();
        expect(h.state.endReason, SessionEndReason.kioskExitedOffline);
        expect(lock.locked, isFalse);
      });
    }

    test('426, таймаут и 401 SESSION_REVOKED — тоже проверка на устройстве', () async {
      final List<ResponseBody Function(RequestOptions o)> answers = <ResponseBody Function(RequestOptions o)>[
        (RequestOptions o) => json(426, problem('APP_UPDATE_REQUIRED', 426)),
        (RequestOptions o) => transportError(o, DioExceptionType.receiveTimeout),
        (RequestOptions o) => json(401, problem('SESSION_REVOKED', 401, extra: <String, Object?>{'reason': 'expired'})),
      ];
      for (final ResponseBody Function(RequestOptions o) answer in answers) {
        final FakeKioskLock lock = FakeKioskLock(locked: true);
        final SessionHarness h = await _tablet(_server(answer), lock: lock);
        final KioskExitOutcome done = await _exit(h).submit(kioskExitCode);
        expect((done as KioskExitDone).offline, isTrue);
        await settle();
        expect(h.state.endReason, SessionEndReason.kioskExitedOffline);
        expect(lock.locked, isFalse);
        await h.dispose();
      }
    });

    test('разбор ответов POST /kiosk/exit', () async {
      Future<KioskServerExitResult> outcome(ResponseBody Function(RequestOptions o) answer) async {
        final SessionHarness h = SessionHarness(_server(answer), access: kioskJwt(), refresh: 'rk1');
        try {
          return await DioKioskLifecycleRepository(h.dio).exit(kioskExitCode);
        } finally {
          await h.dispose();
        }
      }

      expect(await outcome((RequestOptions o) => json(200, <String, Object?>{})), isA<KioskServerExitAccepted>());
      expect(
        ((await outcome(
                  (RequestOptions o) =>
                      json(422, problem('KIOSK_EXIT_CODE_INVALID', 422, extra: <String, Object?>{'attemptsLeft': 2})),
                ))
                as KioskServerExitInvalid)
            .attemptsLeft,
        2,
      );
      expect(
        ((await outcome(
                  (RequestOptions o) =>
                      json(423, problem('KIOSK_EXIT_LOCKED', 423, extra: <String, Object?>{'retryAfter': 600})),
                ))
                as KioskServerExitLocked)
            .retryAfter,
        const Duration(minutes: 10),
      );
      expect(
        await outcome((RequestOptions o) => json(401, problem('KIOSK_REVOKED', 401))),
        isA<KioskServerExitAccepted>(),
      );
      for (final ResponseBody Function(RequestOptions o) other in <ResponseBody Function(RequestOptions o)>[
        (RequestOptions o) => json(403, problem('KIOSK_DISABLED', 403)),
        (RequestOptions o) => json(403, problem('KIOSK_NETWORK_DENIED', 403)),
        (RequestOptions o) => json(503, null),
        (RequestOptions o) => transportError(o, DioExceptionType.connectionTimeout),
      ]) {
        expect(await outcome(other), isA<KioskServerExitNotChecked>());
      }
    });
  });

  group('диалог UI-51-017', () {
    testWidgets('UI-51-017 п. 2–3: сбой хранилища при проверке на устройстве — «Не удалось выполнить. Повторите», а не '
        '«Осталось попыток: 0»; клавиатура доступна, диалог открыт; следующая цифра снимает текст', (
      WidgetTester tester,
    ) async {
      final SessionHarness h = SessionHarness(
        _server((RequestOptions o) => json(200, <String, Object?>{})),
        overrides: <Override>[
          kioskLockProvider.overrideWithValue(FakeKioskLock()),
          kioskExitCodeStoreProvider.overrideWith(
            (ref) => KioskExitCodeStore(storage: _BrokenStorage(), clock: ref.watch(clockProvider)),
          ),
          publicSettingsAutoRefreshProvider.overrideWithValue(false),
        ],
      );
      writeKioskMarker(h.storage.values);
      addTearDown(h.dispose);
      h.start();
      await tester.runAsync(() => h.container.read(sessionStatusProvider.future));
      expect(h.state.kioskReconnectNeeded, isTrue, reason: 'сессии нет — код проверяется на устройстве');
      await _pumpDialog(tester, h);
      await _typeAndSubmit(tester, kioskExitCode);
      expect(_errorShown(tester), _l10n.error_internal);
      expect(find.textContaining('Осталось попыток'), findsNothing);
      expect(find.byKey(KioskEmergencyExitDialog.dialogKey), findsOneWidget);
      expect(tester.widget<KioskKeypad>(find.byType(KioskKeypad)).enabled, isTrue);
      await tester.tap(find.byKey(KioskEmergencyExitDialog.keyFor('1')));
      await tester.pump();
      expect(find.byKey(KioskEmergencyExitDialog.errorKey), findsNothing);
    });

    testWidgets(
      'UI-51-017: 422 KIOSK_EXIT_CODE_INVALID без attemptsLeft — «Неверный аварийный код», без числа попыток',
      (WidgetTester tester) async {
        final SessionHarness h = kioskHarness(
          _server((RequestOptions o) => json(422, problem('KIOSK_EXIT_CODE_INVALID', 422))),
          lock: FakeKioskLock(),
          overrides: <Override>[
            kioskLifecycleRepositoryProvider.overrideWith((ref) => DioKioskLifecycleRepository(ref.watch(dioProvider))),
          ],
        );
        addTearDown(h.dispose);
        h.start();
        await tester.runAsync(() async {
          await h.container.read(sessionStatusProvider.future);
          await rememberExitCode(h);
        });
        await _pumpDialog(tester, h);
        await _typeAndSubmit(tester, wrongExitCode);
        expect(_errorShown(tester), _l10n.error_kiosk_exit_code_invalid);
        expect(find.textContaining('Осталось попыток'), findsNothing);
        expect(h.adapter.countPath('/kiosk/exit'), 1);
      },
    );

    testWidgets(
      'UI-51-017, T-ANIM-012 (указание владельца 2026-11-18): после неверного кода первая цифра — поле обычное: обводка '
      '`border`, точки цифр `textPrimary`, текст ошибки снят (как точки `PinField`, 03 §9.6 ред. 1.24)',
      (WidgetTester tester) async {
        final SessionHarness h = kioskHarness(
          _server((RequestOptions o) => json(422, problem('KIOSK_EXIT_CODE_INVALID', 422))),
          lock: FakeKioskLock(),
          overrides: <Override>[
            kioskLifecycleRepositoryProvider.overrideWith((ref) => DioKioskLifecycleRepository(ref.watch(dioProvider))),
          ],
        );
        addTearDown(h.dispose);
        h.start();
        await tester.runAsync(() async {
          await h.container.read(sessionStatusProvider.future);
          await rememberExitCode(h);
        });
        await _pumpDialog(tester, h);
        final DsColors c = tester.element(find.byKey(KioskEmergencyExitDialog.dialogKey)).colors;
        final Finder slots = find.byWidgetPredicate(
          (Widget w) => w is Semantics && (w.properties.value ?? '').endsWith('/ ${KioskEmergencyExit.codeLength}'),
        );
        Color border() =>
            ((tester.widget<Container>(find.descendant(of: slots, matching: find.byType(Container)).first).decoration!
                            as BoxDecoration)
                        .border!
                    as Border)
                .top
                .color;
        Text slotText() => tester.widget<Text>(find.descendant(of: slots, matching: find.byType(Text)));

        await _typeAndSubmit(tester, wrongExitCode);
        expect(_errorShown(tester), _l10n.error_kiosk_exit_code_invalid);
        expect(border(), c.error, reason: 'момент ошибки');
        expect(slotText().data, isNot(contains('•')), reason: 'поле очищено');

        await tester.tap(find.byKey(KioskEmergencyExitDialog.keyFor('1')));
        await tester.pump();
        expect(border(), c.border, reason: 'новая цифра — обычное поле');
        expect(slotText().data, startsWith('•'));
        expect(slotText().style!.color, c.textPrimary);
        expect(find.byKey(KioskEmergencyExitDialog.errorKey), findsNothing);
      },
    );

    testWidgets('kiosk_exit_locked: «Повторите через {minutes} мин» убывает, пока диалог открыт; пауза прошла — текста '
        'нет, клавиатура доступна', (WidgetTester tester) async {
      final SessionHarness h = kioskHarness(
        _server((RequestOptions o) => json(200, <String, Object?>{})),
        lock: FakeKioskLock(),
        refresh: null,
      );
      addTearDown(h.dispose);
      h.storage.values[SecureKey.kioskExitLockedUntil] = h.clock
          .nowUtc()
          .add(const Duration(minutes: 15))
          .toIso8601String();
      h.start();
      await tester.runAsync(() => h.container.read(sessionStatusProvider.future));
      await _pumpDialog(tester, h);
      await tester.pump();
      expect(_errorShown(tester), _l10n.kiosk_exit_locked(15));
      expect(tester.widget<KioskKeypad>(find.byType(KioskKeypad)).enabled, isFalse);

      h.clock.advance(const Duration(minutes: 2));
      await tester.pump(const Duration(minutes: 2));
      expect(_errorShown(tester), _l10n.kiosk_exit_locked(13));

      h.clock.advance(const Duration(minutes: 13, seconds: 1));
      await tester.pump(const Duration(minutes: 13, seconds: 1));
      expect(find.byKey(KioskEmergencyExitDialog.errorKey), findsNothing);
      expect(tester.widget<KioskKeypad>(find.byType(KioskKeypad)).enabled, isTrue);
    });

    testWidgets('долгое нажатие 5 с на логотип открывает диалог; 2 с — нет; неверный код → «Осталось попыток»', (
      WidgetTester tester,
    ) async {
      final FakeKioskLock lock = FakeKioskLock(locked: true);
      final SessionHarness h = kioskHarness(
        _server((RequestOptions o) => json(200, <String, Object?>{})),
        lock: lock,
        refresh: null,
      );
      addTearDown(h.dispose);
      h.start();
      await tester.runAsync(() async {
        await h.container.read(sessionStatusProvider.future);
        await rememberExitCode(h);
      });
      final GoRouter router = kioskGuardRouter(h.container, initialLocation: '/kiosk');
      addTearDown(router.dispose);
      await tester.pumpWidget(kioskTestApp(h.container, router));
      await tester.pumpAndSettle();
      expect(find.byKey(KioskStateView.logoKey), findsOneWidget);

      final Offset logo = tester.getCenter(find.byKey(KioskStateView.logoKey));
      TestGesture gesture = await tester.startGesture(logo);
      await tester.pump(const Duration(seconds: 2));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(KioskEmergencyExitDialog.dialogKey), findsNothing, reason: '2 с мало');

      gesture = await tester.startGesture(logo);
      await tester.pump(KioskEmergencyExitTrigger.holdDuration);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(KioskEmergencyExitDialog.dialogKey), findsOneWidget);
      expect(find.text(_l10n.kiosk_exit_title), findsOneWidget);
      expect(find.byType(EditableText), findsNothing, reason: 'код — только экранными кнопками');

      Future<void> type(String code) async {
        for (final String d in code.split('')) {
          await tester.tap(find.byKey(KioskEmergencyExitDialog.keyFor(d)));
          await tester.pump();
        }
      }

      final Finder submit = find.byKey(KioskEmergencyExitDialog.submitKey);
      await type(wrongExitCode.substring(0, 7));
      expect(tester.widget<AppButton>(submit).onPressed, isNull);
      await type(wrongExitCode.substring(7));
      expect(tester.widget<AppButton>(submit).onPressed, isNotNull);
      // Клавиши `KioskKeypad` 88 × 64 (A11Y-023): в окне теста 800 × 600 диалог прокручивается до кнопки.
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(submit);
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pump();
      expect(find.text(_l10n.kiosk_exit_code_invalid(4)), findsOneWidget);

      // Esc — закрыть без сброса.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(KioskEmergencyExitDialog.dialogKey), findsNothing);
      expect(h.state.kioskReconnectNeeded, isTrue);
    });
  });
}

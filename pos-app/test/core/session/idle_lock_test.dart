// Idle-блокировка 30 мин и блокировка из фона 5 мин (T-SESS-015; 09 §8.8; SESS-024, SESS-025).
// Таймеры — fake async (`testWidgets` + `tester.pump(duration)`), время фона — FixedClock.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/session/idle_lock_monitor.dart';
import 'package:optomstroy/core/session/session_policy.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';

import 'session_harness.dart';

void main() {
  group('IdleLockMonitor', () {
    late FixedClock clock;
    late List<SessionLockReason> locks;

    IdleLockMonitor monitor(SessionPolicy policy) {
      clock = FixedClock(t0);
      locks = <SessionLockReason>[];
      return IdleLockMonitor(policy: policy, clock: clock, onLock: locks.add);
    }

    testWidgets('30 мин без ввода → блокировка idle; ввод на 29-й минуте сбрасывает отсчёт', (tester) async {
      final m = monitor(const SessionPolicy())..start();
      await tester.pump(const Duration(minutes: 29));
      expect(locks, isEmpty);
      m.activity();
      await tester.pump(const Duration(minutes: 29));
      expect(locks, isEmpty);
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect(locks, [SessionLockReason.idle]);
      expect(m.isActive, isFalse);
      m.dispose();
    });

    testWidgets('Android: фон 6 мин → блокировка background; фон 4 мин → нет', (tester) async {
      final m = monitor(SessionPolicy.forPlatform(TargetPlatform.android))..start();
      m.backgrounded();
      clock.advance(const Duration(minutes: 4));
      await tester.pump(const Duration(minutes: 4));
      m.foregrounded();
      expect(locks, isEmpty);
      m.backgrounded();
      clock.advance(const Duration(minutes: 6));
      m.foregrounded();
      expect(locks, [SessionLockReason.background]);
      m.dispose();
    });

    testWidgets('Windows: возврат из фона не блокирует (только idle 30 мин)', (tester) async {
      final m = monitor(SessionPolicy.forPlatform(TargetPlatform.windows))..start();
      m.backgrounded();
      clock.advance(const Duration(minutes: 20));
      await tester.pump(const Duration(minutes: 20));
      m.foregrounded();
      expect(locks, isEmpty);
      await tester.pump(const Duration(minutes: 10));
      expect(locks, [SessionLockReason.idle]);
      m.dispose();
    });

    testWidgets('после stop таймер не срабатывает', (tester) async {
      final m = monitor(const SessionPolicy())..start();
      m.stop();
      await tester.pump(const Duration(hours: 1));
      expect(locks, isEmpty);
    });
  });

  group('SessionController: idle-блокировка', () {
    testWidgets('staff: 30 мин простоя → overlay SCR-08, access очищен, stepUp очищен', (tester) async {
      final h = SessionHarness((o) async => json(200, {}));
      final c = h.start();
      final established = c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await tester.pump();
      await established;
      expect(h.tokens.accessToken, isNotNull);
      await tester.pump(const Duration(minutes: 15));
      c.recordActivity();
      await tester.pump(const Duration(minutes: 29));
      expect(h.state.isLocked, isFalse);
      await tester.pump(const Duration(minutes: 1));
      expect(h.state.lock, SessionLockReason.idle);
      expect(h.tokens.accessToken, isNull);
      expect(h.storage.values[SecureKey.refreshToken], 'r1');
      await h.dispose();
    });

    testWidgets('customer: idle-блокировка в R1 не применяется (09 §8.8)', (tester) async {
      final h = SessionHarness((o) async => json(200, {}));
      final c = h.start();
      final established = c.establish(
        accessToken: fakeJwt(kind: 'customer'),
        refreshToken: 'r1',
      );
      await tester.pump();
      await established;
      await tester.pump(const Duration(hours: 2));
      expect(h.state.isLocked, isFalse);
      c.lock(SessionLockReason.manual);
      expect(h.state.lock, SessionLockReason.manual);
      await h.dispose();
    });

    testWidgets('фон > 5 мин на Android → блокировка background', (tester) async {
      final h = SessionHarness((o) async => json(200, {}), policy: SessionPolicy.forPlatform(TargetPlatform.android));
      final c = h.start();
      final established = c.establish(accessToken: fakeJwt(), refreshToken: 'r1');
      await tester.pump();
      await established;
      c.appBackgrounded();
      h.clock.advance(const Duration(minutes: 6));
      c.appForegrounded();
      expect(h.state.lock, SessionLockReason.background);
      await h.dispose();
    });
  });
}

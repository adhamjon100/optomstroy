// stepUpToken: многоразовый 15 мин в своей области (08 §2.12; ядро §18.2 п.6), только память;
// claims access JWT без проверки подписи — только для UX (exp, kind, sub).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/network/interceptors/access_token_claims.dart';
import 'package:optomstroy/core/session/step_up_token_cache.dart';
import 'package:optomstroy/core/utils/clock.dart';

import 'session_harness.dart';

void main() {
  group('StepUpTokenCache', () {
    test('область: операция и коды scope; другая операция — нет', () {
      final clock = FixedClock(t0);
      final cache = StepUpTokenCache(clock: clock)
        ..put(
          StepUpGrant(
            token: 'su-1',
            operation: 'customer.receivables.read.detail',
            expiresAt: t0.add(const Duration(minutes: 15)),
            method: 'pin',
            scope: const <String>['customer.receivables.read.detail'],
          ),
        );
      expect(cache.tokenFor('customer.receivables.read.detail'), 'su-1');
      expect(cache.tokenFor('payment.void'), isNull);
    });

    test('истечение с запасом 15 с; discard и clear', () {
      final clock = FixedClock(t0);
      final cache = StepUpTokenCache(clock: clock)
        ..put(StepUpGrant(token: 'a', operation: 'op', expiresAt: t0.add(const Duration(minutes: 15)), method: 'otp'));
      clock.advance(const Duration(minutes: 14, seconds: 44));
      expect(cache.tokenFor('op'), 'a');
      clock.advance(const Duration(seconds: 2));
      expect(cache.tokenFor('op'), isNull);
      expect(cache.length, 0);

      cache
        ..put(
          StepUpGrant(
            token: 'b',
            operation: 'op',
            expiresAt: clock.nowUtc().add(const Duration(minutes: 15)),
            method: 'pin',
          ),
        )
        ..discard('b');
      expect(cache.tokenFor('op'), isNull);
      cache
        ..put(
          StepUpGrant(
            token: 'c',
            operation: 'op',
            expiresAt: clock.nowUtc().add(const Duration(minutes: 15)),
            method: 'pin',
          ),
        )
        ..clear();
      expect(cache.length, 0);
    });

    test('разбор ответа 200 POST /auth/step-up; toString без токена', () {
      final grant = StepUpGrant.fromJson(
        stepUpToken('secret-token', 'session.logout_all'),
        operation: 'session.logout_all',
      );
      expect(grant.token, 'secret-token');
      expect(grant.method, 'pin');
      expect(grant.covers('session.logout_all'), isTrue);
      expect(grant.toString(), isNot(contains('secret-token')));
    });
  });

  group('AccessTokenClaims', () {
    test('payload JWT: sub, kind, exp; не JWT — null', () {
      final exp = DateTime.utc(2026, 10, 22, 10);
      final claims = AccessTokenClaims.tryParse(fakeJwt(kind: 'customer', exp: exp))!;
      expect(claims.subject, staffUserId);
      expect(claims.kind, 'customer');
      expect(claims.expiresAt, exp);
      expect(claims.expiresWithin(const Duration(seconds: 60), exp.subtract(const Duration(seconds: 30))), isTrue);
      expect(claims.expiresWithin(const Duration(seconds: 60), exp.subtract(const Duration(minutes: 5))), isFalse);
      expect(AccessTokenClaims.tryParse('opaque'), isNull);
      expect(AccessTokenClaims.tryParse('a.%%%.c'), isNull);
      expect(AccessTokenClaims.tryParse(null), isNull);
    });
  });
}

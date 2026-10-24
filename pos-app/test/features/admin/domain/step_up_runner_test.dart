// StepUpRunner: step-up по ответу 403 и заранее, повтор тем же вызовом, отмена, кэш токена 15 мин.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';

void main() {
  late DateTime now;
  late List<Duration> slept;
  late StepUpRunner runner;
  late List<StepUpChallenge> asked;
  late List<String?> sentTokens;

  StepUpGrant grant([String token = 'tok-1']) =>
      StepUpGrant(token: token, expiresAt: now.add(const Duration(minutes: 15)), method: StepUpMethod.pin);

  Future<StepUpGrant?> obtainOk(StepUpChallenge c) async {
    asked.add(c);
    return grant();
  }

  Future<StepUpGrant?> obtainCancel(StepUpChallenge c) async {
    asked.add(c);
    return null;
  }

  /// «Сервер»: без токена tok-* — 403 STEP_UP_REQUIRED с operation [op].
  Future<Result<int>> Function(String?) server(String op) => (token) async {
    sentTokens.add(token);
    if (token == null || !token.startsWith('tok')) {
      return FailureResult(AuthFailure(AuthReason.stepUpRequired, stepUpOperation: op));
    }
    return const Success(42);
  };

  setUp(() {
    now = DateTime.utc(2026, 10, 22, 9);
    slept = [];
    asked = [];
    sentTokens = [];
    runner = StepUpRunner(
      nowUtc: () => now,
      sleep: (d) async {
        slept.add(d);
      },
    );
  });

  test('403 STEP_UP_REQUIRED → диалог с operation из ответа → один повтор с токеном', () async {
    final r = await runner.run(operation: 'users.roles.assign', call: server('users.roles.assign'), obtain: obtainOk);
    expect(r, isA<ActionDone<int>>());
    expect(r.valueOrNull, 42);
    expect(sentTokens, [null, 'tok-1']);
    expect(asked.single.operation, 'users.roles.assign');
    expect(asked.single.allowedMethods, [StepUpMethod.pin, StepUpMethod.otp]);
  });

  test('operation берётся из ответа сервера без изменений', () async {
    await runner.run(operation: 'users.manage', call: server('session.revoke.any'), obtain: obtainOk);
    expect(asked.single.operation, 'session.revoke.any');
  });

  test('отмена диалога → ActionCancelled, повтора нет', () async {
    final r = await runner.run(operation: 'users.manage', call: server('users.manage'), obtain: obtainCancel);
    expect(r, isA<ActionCancelled<int>>());
    expect(sentTokens, [null]);
  });

  test('токен многоразовый в области 15 мин: второй вызов без диалога; после истечения — снова диалог', () async {
    await runner.run(operation: 'users.manage', call: server('users.manage'), obtain: obtainOk);
    sentTokens.clear();
    await runner.run(operation: 'users.manage', call: server('users.manage'), obtain: obtainOk);
    expect(asked, hasLength(1));
    expect(sentTokens, ['tok-1']);
    now = now.add(const Duration(minutes: 16));
    expect(runner.tokenFor('users.manage'), isNull);
    await runner.run(operation: 'users.manage', call: server('users.manage'), obtain: obtainOk);
    expect(asked, hasLength(2));
  });

  test('clear() забывает токены (сворачивание приложения)', () async {
    await runner.run(operation: 'users.manage', call: server('users.manage'), obtain: obtainOk);
    runner.clear();
    expect(runner.tokenFor('users.manage'), isNull);
  });

  test('proactive (аварийный код): диалог ДО запроса, только PIN, запрос один', () async {
    final r = await runner.run(
      operation: 'users.emergency_code.issue',
      call: server('users.emergency_code.issue'),
      obtain: obtainOk,
      proactive: true,
      methods: const [StepUpMethod.pin],
    );
    expect(r.valueOrNull, 42);
    expect(sentTokens, ['tok-1']);
    expect(asked.single.allowedMethods, [StepUpMethod.pin]);
  });

  test('proactive + отмена → запрос не отправляется', () async {
    final r = await runner.run(
      operation: 'users.emergency_code.issue',
      call: server('users.emergency_code.issue'),
      obtain: obtainCancel,
      proactive: true,
    );
    expect(r, isA<ActionCancelled<int>>());
    expect(sentTokens, isEmpty);
  });

  test('повторный STEP_UP_REQUIRED после токена — ошибка без бесконечного цикла', () async {
    Future<Result<int>> alwaysStepUp(String? t) async {
      sentTokens.add(t);
      return const FailureResult(AuthFailure(AuthReason.stepUpRequired, stepUpOperation: 'users.manage'));
    }

    final r = await runner.run(operation: 'users.manage', call: alwaysStepUp, obtain: obtainOk);
    expect(r, isA<ActionFailed<int>>());
    expect(sentTokens, hasLength(2));
  });

  test('IDEMPOTENCY_IN_PROGRESS → ожидание Retry-After (по умолчанию 2 с) и один повтор', () async {
    var n = 0;
    Future<Result<int>> busy(String? t) async {
      n++;
      if (n == 1) return const FailureResult(ConflictFailure(ConflictKind.idempotencyInProgress));
      return const Success(1);
    }

    final r = await runner.run(operation: 'x', call: busy, obtain: obtainOk);
    expect(r.valueOrNull, 1);
    expect(slept, [const Duration(seconds: 2)]);
  });

  test('StepUpGrant.toString не содержит токен', () {
    expect(grant('secret-token').toString(), isNot(contains('secret-token')));
  });
}

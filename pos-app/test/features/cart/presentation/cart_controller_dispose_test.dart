// CartController: провайдер уничтожен во время сверки с сервером (выход, смена пользователя, закрытие приложения) —
// ответ `GET /cart` после этого не трогает `state` (найдено integration_test/auth_flow_test.dart на этапе F:
// UnmountedRefException из `_restore` после завершения теста).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';

import '../../../support/f_fakes.dart';
import '../support/cart_test_support.dart';

void main() {
  test('ответ сверки после уничтожения провайдера не обращается к state', () async {
    final FakeCartRepository repo = FakeCartRepository();
    final Completer<Result<Cart>> fetch = Completer<Result<Cart>>();
    repo.onFetch = () => fetch.future;
    final ProviderContainer c = ProviderContainer(
      overrides: cartOverrides(sync: FakeCartSync(repo), repo: repo),
    );
    final ProviderSubscription<CartState> sub = c.listen(cartControllerProvider, (_, _) {});
    await pumpEventQueue();
    expect(repo.calls.map((FakeCall x) => x.method), contains('fetch'), reason: 'восстановление начало сверку');
    sub.close();
    c.dispose();
    fetch.complete(Success<Cart>(canonCart()));
    await pumpEventQueue();
    // Необработанная ошибка в зоне теста (UnmountedRefException) провалила бы тест.
  });
}

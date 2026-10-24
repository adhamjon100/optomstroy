// RM-F-011 (интеграция F): реестр обработчиков outbox на собранном корне (`appOverrides`) и взаимная ссылка
// «очередь ↔ обработчик `cart.sync`» без `CircularDependencyError` (найдено integration_test/pos_flow_test.dart:
// первый `CartSync.refresh()` читал `outboxQueueProvider` из провайдера, от которого очередь зависит через реестр).
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';

final class _Net implements NetworkSignalSource {
  @override
  Future<bool> hasNetwork() async => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

/// Сервер недоступен: любой запрос завершается ошибкой соединения без сети.
Dio _downDio() {
  final Dio dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9/api/v1'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (RequestOptions o, RequestInterceptorHandler h) =>
          h.reject(DioException.connectionError(requestOptions: o, reason: 'test: server down')),
    ),
  );
  return dio;
}

ProviderContainer _root() {
  final ProviderContainer c = ProviderContainer(
    overrides: [
      ...appOverrides,
      connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(_Net())),
      dioProvider.overrideWithValue(_downDio()),
      clientMetaProvider.overrideWithValue(
        const ClientMeta(
          appVersion: '0.1.0+1',
          platform: ClientPlatform.windows,
          deviceId: '3f2b8c1e-5d4a-4b6c-9e7f-0a1b2c3d4e5f',
        ),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('реестр outbox корня: избранное, недавние, auth.logout, cart.sync, notification.read, profile.settings', () {
    final ProviderContainer c = _root();
    final Set<String> types = <String>{for (final OutboxActionHandler h in c.read(outboxHandlersProvider)) ...h.types};
    expect(types, containsAll(<String>['cart.sync', 'notification.read', 'profile.settings', 'auth.logout']));
    expect(types.length, greaterThanOrEqualTo(6), reason: '+ избранное и «очистить недавние» core/sync');
  });

  test('CartSync.refresh() при живой очереди: очередь читается без CircularDependencyError', () async {
    final ProviderContainer c = _root();
    final ProviderSubscription<OutboxQueue> queue = c.listen(outboxQueueProvider, (_, _) {});
    addTearDown(queue.close);
    final Result<Cart> r = await c.read(cartSyncProvider).refresh();
    expect(r, isA<FailureResult<Cart>>(), reason: 'сервер недоступен — ошибка сети, а не исключение графа');
  });
}

// Этап F (основа), 06 §6.10 L-8: bindings фич cart, orders, checkout, customers, notifications разрешают провайдеры
// портов в реализации data (кодеки вложенных Customer/Cart/Order — через порты фич, FL-06); фейки test/support/f_fakes.dart
// подменяют те же провайдеры для widget-тестов экранов.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/data/cart_bindings.dart';
import 'package:optomstroy/features/cart/data/repositories/dio_cart_repository.dart';
import 'package:optomstroy/features/checkout/checkout_providers.dart';
import 'package:optomstroy/features/checkout/data/checkout_bindings.dart';
import 'package:optomstroy/features/checkout/data/repositories/dio_checkout_repository.dart';
import 'package:optomstroy/features/checkout/data/repositories/drift_checkout_draft_repository.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/data/customers_bindings.dart';
import 'package:optomstroy/features/customers/data/repositories/dio_customers_repository.dart';
import 'package:optomstroy/features/notifications/data/notifications_bindings.dart';
import 'package:optomstroy/features/notifications/data/repositories/notifications_repository_impl.dart';
import 'package:optomstroy/features/notifications/notifications_providers.dart';
import 'package:optomstroy/features/orders/data/orders_bindings.dart';
import 'package:optomstroy/features/orders/data/repositories/dio_orders_repository.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

import '../support/f_fakes.dart';

void main() {
  test('bindings этапа F: каждый порт → реализация data', () {
    final ProviderContainer c = ProviderContainer(
      overrides: [
        dioProvider.overrideWithValue(Dio()),
        ...customersBindings,
        ...cartBindings,
        ...ordersBindings,
        ...checkoutBindings,
        ...notificationsBindings,
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(customersRepositoryProvider), isA<DioCustomersRepository>());
    expect(c.read(customerJsonDecoderProvider), isA<CustomerDtoDecoder>());
    expect(c.read(cartRepositoryProvider), isA<DioCartRepository>());
    expect(c.read(cartJsonDecoderProvider), isA<CartDtoDecoder>());
    expect(c.read(ordersRepositoryProvider), isA<DioOrdersRepository>());
    expect(c.read(paymentsRepositoryProvider), isA<DioPaymentsRepository>());
    expect(c.read(orderJsonDecoderProvider), isA<OrderDtoDecoder>());
    expect(c.read(checkoutRepositoryProvider), isA<DioCheckoutRepository>());
    expect(c.read(checkoutDraftRepositoryProvider), isA<DriftCheckoutDraftRepository>());
    expect(c.read(notificationsRepositoryProvider), isA<NotificationsRepositoryImpl>());
  });

  test('без bindings порт сообщает, что подключить', () {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    expect(() => c.read(cartRepositoryProvider), throwsA(anything));
  });

  test('фейки: те же провайдеры, неподменённый метод → UnknownFailure, вызовы пишутся', () async {
    final FFakes fakes = FFakes();
    final ProviderContainer c = ProviderContainer(overrides: fakes.overrides);
    addTearDown(c.dispose);
    fakes.cart.onFetch = () async => Success(emptyCart(rowVersion: 7));
    expect((await c.read(cartRepositoryProvider).fetch()).valueOrNull!.rowVersion, 7);
    expect((await c.read(ordersRepositoryProvider).get('o-1')).failureOrNull, isA<UnknownFailure>());
    expect(fakes.orders.calls.single.method, 'get');
    final String k1 = (await c.read(checkoutDraftRepositoryProvider).ensureOrderKey('cart-1')).valueOrNull!;
    final String k2 = (await c.read(checkoutDraftRepositoryProvider).ensureOrderKey('cart-1')).valueOrNull!;
    expect(k1, k2);
  });
}

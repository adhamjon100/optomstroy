// `CartRepository` поверх единственного Dio-клиента (08 §4.7). Ошибки → Failure только через ErrorMapper (06 §6.8);
// ответ не по контракту (`DtoFormatException`) → `UnknownFailure`. Тела и ответы не логируются (LoggingInterceptor
// пишет метод, путь, статус). Цены клиент не передаёт (D-23): в теле только количество, упаковка, rowVersion и
// `priceSnapshot` (для предупреждения).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/features/cart/data/dto/cart_dtos.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';

/// Пути API корзины (08 §4.7).
abstract final class CartApiPaths {
  static const String cart = '/cart';
  static const String customer = '/cart/customer';
  static const String discount = '/cart/discount';
  static const String park = '/cart/park';
  static const String parked = '/cart/parked';
  static const String checkoutPreview = '/cart/checkout-preview';
  static String item(String variantId) => '/cart/items/${Uri.encodeComponent(variantId)}';
  static String parkedCart(String id) => '/cart/parked/${Uri.encodeComponent(id)}';
  static String resume(String id) => '/cart/parked/${Uri.encodeComponent(id)}/resume';
}

final class DioCartRepository implements CartRepository {
  DioCartRepository(this._dio, {CustomerDecoder customer = minimalCustomer}) : _customer = customer;

  final Dio _dio;
  final CustomerDecoder _customer;

  static Options _opts({String? idempotencyKey, String? stepUpToken}) {
    final Options o = apiOptions(idempotencyKey: idempotencyKey);
    if (stepUpToken != null) o.headers![ApiHeaders.stepUpToken] = stepUpToken; // check-secrets: allow (имя заголовка)
    return o;
  }

  Cart _cart(Response<Object?> r) => CartDto.fromJson(jsonObject(r.data), customer: _customer);

  @override
  Future<Result<Cart>> fetch({bool revalidate = true}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      CartApiPaths.cart,
      queryParameters: <String, Object?>{if (!revalidate) 'revalidate': false},
      options: _opts(),
    );
    return _cart(r);
  });

  @override
  Future<Result<Cart>> putItem(String variantId, CartItemPut put, {String? idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.put<Object?>(
          CartApiPaths.item(variantId),
          data: CartRequestDto.putItem(put),
          options: _opts(idempotencyKey: idempotencyKey),
        );
        return _cart(r);
      });

  @override
  Future<Result<Cart>> deleteItem(String variantId, {String? packagingId, String? idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.delete<Object?>(
          CartApiPaths.item(variantId),
          queryParameters: <String, Object?>{'packagingId': ?packagingId},
          options: _opts(idempotencyKey: idempotencyKey),
        );
        return _cart(r);
      });

  @override
  Future<Result<Cart>> clear({required int rowVersion}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.delete<Object?>(
      CartApiPaths.cart,
      queryParameters: <String, Object?>{'rowVersion': rowVersion},
      options: _opts(),
    );
    return _cart(r);
  });

  @override
  Future<Result<Cart>> setWarehouse(String warehouseId, {required int rowVersion, String? idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.patch<Object?>(
          CartApiPaths.cart,
          data: CartRequestDto.update(warehouseId, rowVersion),
          options: _opts(idempotencyKey: idempotencyKey),
        );
        return _cart(r);
      });

  @override
  Future<Result<Cart>> setCustomer(
    String customerId, {
    required int rowVersion,
    Receiver? receiver,
    String? idempotencyKey,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      CartApiPaths.customer,
      data: CartRequestDto.customer(customerId, rowVersion, receiver),
      options: _opts(idempotencyKey: idempotencyKey),
    );
    return _cart(r);
  });

  @override
  Future<Result<Cart>> clearCustomer({String? idempotencyKey}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.delete<Object?>(
      CartApiPaths.customer,
      options: _opts(idempotencyKey: idempotencyKey),
    );
    return _cart(r);
  });

  @override
  Future<Result<Cart>> applyDiscount(CartDiscountInput input, {String? idempotencyKey, String? stepUpToken}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.post<Object?>(
          CartApiPaths.discount,
          data: CartRequestDto.discount(input),
          options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
        );
        return _cart(r);
      });

  @override
  Future<Result<CartParkResult>> park({required int rowVersion, String? name, required String idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.post<Object?>(
          CartApiPaths.park,
          data: CartRequestDto.park(rowVersion, name),
          options: _opts(idempotencyKey: idempotencyKey),
        );
        return CartParkResponseDto.fromJson(jsonObject(r.data), customer: _customer);
      });

  @override
  Future<Result<PageResult<CartParkedSummary>>> listParked({
    ParkedScope scope = ParkedScope.own,
    String? cursor,
    int limit = 50,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      CartApiPaths.parked,
      queryParameters: <String, Object?>{'scope': scope.value, 'limit': limit, 'cursor': ?cursor},
      options: _opts(),
    );
    return PageDto.fromJson(jsonObject(r.data), (JsonMap j) => CartParkedSummaryDto.fromJson(j, customer: _customer));
  });

  @override
  Future<Result<Cart>> resumeParked(String cartId, {bool replaceActive = false, String? idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.post<Object?>(
          CartApiPaths.resume(cartId),
          data: CartRequestDto.resume(replaceActive: replaceActive),
          options: _opts(idempotencyKey: idempotencyKey),
        );
        return _cart(r);
      });

  @override
  Future<Result<void>> deleteParked(String cartId) => ErrorMapper.guard(() async {
    await _dio.delete<Object?>(CartApiPaths.parkedCart(cartId), options: _opts());
  });

  @override
  Cart? conflictCurrent(Failure failure) {
    if (failure is! ConflictFailure || failure.kind != ConflictKind.versionConflict) return null;
    final Object? current = failure.details['current'];
    if (current is! Map) return null;
    try {
      return CartDto.fromJson(current.cast<String, dynamic>(), customer: _customer);
    } on Object {
      return null; // `current` другого ресурса (профиль, настройки) или не по контракту
    }
  }

  @override
  List<CartConflict> problemConflicts(Failure failure) {
    final Map<String, Object?> details = switch (failure) {
      ConflictFailure(:final Map<String, Object?> details) => details,
      _ => const <String, Object?>{},
    };
    return CartConflictDto.listOf(details['conflicts']);
  }
}

// Привязка портов фичи customers к реализациям data (06 §6.14, L-8). Подключение — `app/di/overrides.dart`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/data/dto/customer_dtos.dart';
import 'package:optomstroy/features/customers/data/repositories/dio_customer_g_repositories.dart';
import 'package:optomstroy/features/customers/data/repositories/dio_customers_repository.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customer_json_decoder.dart';

/// [CustomerJsonDecoder] на кодеке `CustomerDto`.
final class CustomerDtoDecoder implements CustomerJsonDecoder {
  const CustomerDtoDecoder();

  @override
  Customer decode(Map<String, dynamic> json) => CustomerDto.fromJson(json);
}

final List<Override> customersBindings = <Override>[
  customersRepositoryProvider.overrideWith((Ref ref) => DioCustomersRepository(ref.watch(dioProvider))),
  customerJsonDecoderProvider.overrideWithValue(const CustomerDtoDecoder()),
  // Этап G (основа): справочник, долги (память финансов сессии), избранные клиенты.
  customerDirectoryRepositoryProvider.overrideWith((Ref ref) => DioCustomerDirectoryRepository(ref.watch(dioProvider))),
  receivablesRepositoryProvider.overrideWith(
    (Ref ref) => DioReceivablesRepository(ref.watch(dioProvider), ref.watch(customerFinanceMemoryProvider)),
  ),
  favoriteCustomersRepositoryProvider.overrideWith((Ref ref) => DioFavoriteCustomersRepository(ref.watch(dioProvider))),
];

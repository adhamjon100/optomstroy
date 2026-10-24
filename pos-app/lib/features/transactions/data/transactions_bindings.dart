// Привязка портов фичи transactions к реализациям data (06 §6.14, L-8). Подключение — `app/di/overrides.dart`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/transactions/data/repositories/dio_transactions_repository.dart';
import 'package:optomstroy/features/transactions/transactions_providers.dart';

final List<Override> transactionsBindings = <Override>[
  transactionsRepositoryProvider.overrideWith((Ref ref) => DioTransactionsRepository(ref.watch(dioProvider))),
];

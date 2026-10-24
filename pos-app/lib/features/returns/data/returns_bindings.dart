// Привязка портов фичи returns к реализациям data (06 §6.14, L-8). Подключение — `app/di/overrides.dart`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/returns/data/repositories/dio_returns_repository.dart';
import 'package:optomstroy/features/returns/returns_providers.dart';

final List<Override> returnsBindings = <Override>[
  returnsRepositoryProvider.overrideWith((Ref ref) => DioReturnsRepository(ref.watch(dioProvider))),
];

// Привязка портов фичи profile к реализациям data (06 §6.14, L-8). Подключение — `app/di/overrides.dart`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/profile/data/repositories/dio_profile_repository.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';

final List<Override> profileBindings = <Override>[
  profileRepositoryProvider.overrideWith((Ref ref) => DioProfileRepository(ref.watch(dioProvider))),
];

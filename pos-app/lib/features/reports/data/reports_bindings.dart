// Привязка портов фичи reports к реализациям data (06 §6.14, L-8). Подключение — `app/di/overrides.dart`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/reports/data/repositories/dio_reports_repository.dart';
import 'package:optomstroy/features/reports/reports_providers.dart';

final List<Override> reportsBindings = <Override>[
  reportsRepositoryProvider.overrideWith((Ref ref) => DioReportsRepository(ref.watch(dioProvider))),
];

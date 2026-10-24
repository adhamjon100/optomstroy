// Публичный контракт фичи reports (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап G (основа): порт отчётов руководителя SCR-48. Реализацию подключает `app/di/overrides.dart` списком
// `reportsBindings` (data/reports_bindings.dart, L-8). В widget-тестах — `reportsRepositoryProvider.overrideWithValue`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/reports/domain/repositories/reports_repository.dart';

/// Отчёты руководителя (только онлайн).
final reportsRepositoryProvider = Provider<ReportsRepository>(
  (ref) => throw UnimplementedError('reportsRepositoryProvider: подключите reportsBindings в app/di/overrides.dart'),
);

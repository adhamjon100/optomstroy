// Публичный контракт фичи home (06 §6.1 L-3 (2), §6.14; FL-07): SCR-50 «Главный экран клиента».
//
// Содержимое SCR-50 строится провайдерами и карточками фичи catalog (06 MOD-029), а ребра
// `home → catalog` в DAG 06 §6.1 / `scripts/check_layers.py` нет (E_spec_questions EQ-FEF-07, EQ-HOME-01).
// Поэтому фича home не импортирует catalog: экран получает построитель содержимого через порт
// [customerHomeBodyProvider]; привязку к `CustomerHomeView` (features/catalog) делает композиционный корень
// (`app/router/shells/customer_mode_bindings.dart` → `appOverrides`), в тестах — `overrideWithValue`.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Параметры маршрута SCR-50 `/home?view=&sort=` (только path/query, 06 §6.4).
@immutable
final class CustomerHomeArgs {
  const CustomerHomeArgs({this.view, this.sort});

  /// Вид: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API.
  final String? sort;

  @override
  bool operator ==(Object other) => other is CustomerHomeArgs && other.view == view && other.sort == sort;

  @override
  int get hashCode => Object.hash(view, sort);
}

/// Построитель содержимого SCR-50.
typedef CustomerHomeBodyBuilder = Widget Function(BuildContext context, CustomerHomeArgs args);

/// Содержимое SCR-50; `null` — корень не подключил каталог (экран показывает пустой фон).
final customerHomeBodyProvider = Provider<CustomerHomeBodyBuilder?>((ref) => null);

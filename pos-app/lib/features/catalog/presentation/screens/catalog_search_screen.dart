// SCR-11 Результаты поиска (`/catalog/search?q=&view=&sort=`, staff и customer; 02 ч. B).
//
// Имя класса, путь файла и параметры конструктора фиксированы основой маршрутов (routes.dart).
// Реализация — [CatalogWorkspace] в режиме `search`: debounce 300 мс, минимум 2 символа (цифры — 1),
// Enter — сразу; ответы устаревших запросов отбрасываются (AC-UI-11-001, AC-UI-11-002, AC-UI-11-007).
import 'package:flutter/widgets.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_workspace.dart';

/// SCR-11 — Результаты поиска.
class CatalogSearchScreen extends StatelessWidget {
  const CatalogSearchScreen({this.q, this.categoryId, this.view, this.sort, super.key});

  /// ID экрана по 02 §4.1.
  static const String screenId = 'SCR-11';

  /// Строка поиска.
  final String? q;

  /// Категория, в которой начат поиск (SCR-12): «Назад» возвращает в неё (02 SCR-11.6).
  final String? categoryId;

  /// Вид: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API (`relevance:desc` …).
  final String? sort;

  @override
  Widget build(BuildContext context) => CatalogWorkspace(
    key: const ValueKey<String>('stub-$screenId'),
    mode: CatalogScreenMode.search,
    q: q,
    categoryId: categoryId,
    view: view,
    sort: sort,
  );
}

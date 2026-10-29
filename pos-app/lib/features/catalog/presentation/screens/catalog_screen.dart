// SCR-10 Рабочее пространство продавца / Каталог (`/catalog?preset=&view=&sort=`, staff; 02 ч. B).
//
// Имя класса, путь файла и параметры конструктора фиксированы основой маршрутов (routes.dart).
// Реализация — общее рабочее пространство каталога [CatalogWorkspace] в режиме `root` (compact; на
// medium/expanded/large — [CatalogWorkspaceScreen], общий для SCR-10/11/12). Ключ `stub-SCR-10` — маркер внутри него.
import 'package:flutter/widgets.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_workspace.dart';

/// SCR-10 — Рабочее пространство продавца / Каталог.
class CatalogScreen extends StatelessWidget {
  const CatalogScreen({this.preset, this.view, this.sort, super.key});

  /// ID экрана по 02 §4.1.
  static const String screenId = 'SCR-10';

  /// `preset=recent` — подборка «Недавние» (02 §4.1).
  final String? preset;

  /// Вид: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API (`price:asc` …).
  final String? sort;

  @override
  Widget build(BuildContext context) => CatalogWorkspace(
    key: CatalogWorkspace.stableKey,
    mode: CatalogScreenMode.root,
    preset: preset,
    view: view,
    sort: sort,
  );
}

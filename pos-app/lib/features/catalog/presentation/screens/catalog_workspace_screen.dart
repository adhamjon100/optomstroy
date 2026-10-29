// Рабочее пространство каталога на medium/expanded/large: один экран для SCR-10 `/catalog`, SCR-12 `/catalog/c/{id}`
// и SCR-11 `/catalog/search` (переходы `go` и `push` поверх семейства). Страница `/catalog` строит [CatalogWorkspace]
// в режиме верхней записи (app/router/catalog_family.dart), дочерние записи — [PassThroughPage] без содержимого. Смена
// категории обновляет тот же экземпляр (`didUpdateWidget`): шапка, сайдбар, панель инструментов и CP не
// пересоздаются, страница не анимируется (02 SCR-10.5/SCR-12.5 ANIM-024: SB и CP не анимируются; заказчик
// 2026-10-28 — «мигает весь экран»). Ключи `stub-SCR-10/11/12` — маркеры внутри [CatalogWorkspace].
import 'package:flutter/widgets.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_workspace.dart';

export 'package:optomstroy/features/catalog/presentation/widgets/catalog_workspace.dart' show CatalogScreenMode;

/// SCR-10/11/12 на medium/expanded/large — общий экран семейства каталога.
class CatalogWorkspaceScreen extends StatelessWidget {
  const CatalogWorkspaceScreen({
    required this.mode,
    this.categoryId,
    this.preset,
    this.view,
    this.sort,
    this.f,
    this.q,
    this.stackDepth,
    super.key,
  });

  /// Режим по адресу: корень, категория, поиск.
  final CatalogScreenMode mode;

  /// SCR-12 — категория (path); SCR-11 — категория, в которой начат поиск (query).
  final String? categoryId;

  /// SCR-10 `preset=recent`.
  final String? preset;

  /// Вид: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API.
  final String? sort;

  /// SCR-12 — сериализованные фильтры.
  final String? f;

  /// SCR-11 — строка поиска.
  final String? q;

  /// Число записей `push` семейства над записью `go` ([CatalogWorkspace.stackDepth]).
  final int? stackDepth;

  @override
  Widget build(BuildContext context) => CatalogWorkspace(
    key: CatalogWorkspace.stableKey,
    mode: mode,
    categoryId: categoryId,
    preset: preset,
    view: view,
    sort: sort,
    f: f,
    q: q,
    stackDepth: stackDepth,
  );
}

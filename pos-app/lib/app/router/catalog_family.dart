// Семейство каталога SCR-10/11/12 на medium/expanded/large — один экран в странице `/catalog`.
//
// Страница `/catalog` строит [CatalogWorkspaceScreen] в режиме верхней записи семейства ([CatalogFamilyHost]), а
// записи `/catalog/c/{id}` и `/catalog/search` — и из `go`, и из `push` поверх неё (поиск в категории, CQ-STAB-03;
// подкатегория на medium) — [PassThroughPage] без содержимого. Смена категории, поиск и «Назад» обновляют один
// экземпляр [CatalogWorkspace]: шапка, колонка категорий, панель управления и CP не пересоздаются (02 SCR-10.5,
// SCR-12.5 ANIM-024; заказчик 2026-10-28 — «мигает весь экран»). Форма страниц одинакова для medium, expanded и
// large: смена класса окна между ними (поворот планшета, Snap окна Windows) не меняет тип страниц и виджета
// экрана — набранный текст, прокрутка, черновик фильтров сохраняются. compact — обычные страницы ветки.
//
// Состав стека читается из `RouteMatchList` (`routerDelegate.currentConfiguration`): запись `push` —
// [ImperativeRouteMatch] (формат `pageKey` go_router не используется: `replace` сохраняет ключ заменяемой записи).
// Записи семейства, открытые `push` не прямо над ним (например, поиск из SCR-14), — своя страница.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_workspace_screen.dart';

/// Шаблоны путей семейства каталога, которые рисует страница `/catalog`.
const Set<String> _familyPaths = <String>{'/catalog', '/catalog/c/:categoryId', '/catalog/search'};

/// Состав стека ветки «Каталог»: что рисует страница `/catalog` и какие записи над ней — без содержимого.
@immutable
final class CatalogFamilyStack {
  const CatalogFamilyStack._({
    required this.fullPath,
    required this.uri,
    required this.pathParameters,
    required this.depth,
    required this.passThrough,
  });

  /// Из состояния страницы `/catalog` (стек не прочитан): только записи `go`.
  factory CatalogFamilyStack.fromState(GoRouterState state) => CatalogFamilyStack._(
    fullPath: state.fullPath ?? '/catalog',
    uri: state.uri,
    pathParameters: state.pathParameters,
    depth: 0,
    passThrough: const <ValueKey<String>>{},
  );

  /// Шаблон пути верхней записи семейства.
  final String fullPath;

  /// Адрес верхней записи семейства.
  final Uri uri;

  /// Параметры пути верхней записи (раскодированы).
  final Map<String, String> pathParameters;

  /// Число записей `push` семейства над записью `go` (0 — верхняя запись открыта `go`).
  final int depth;

  /// Ключи страниц, которые рисует страница `/catalog` ([PassThroughPage]).
  final Set<ValueKey<String>> passThrough;

  /// Последний прочитанный состав по роутеру (ветка «Каталог» активна) — для пересборки страниц неактивной ветки.
  static final Expando<CatalogFamilyStack> _last = Expando<CatalogFamilyStack>('catalog-family');

  /// Состав по текущему стеку роутера; `null` — ветка «Каталог» не активна (берётся последний прочитанный).
  static CatalogFamilyStack? of(GoRouter? router) {
    if (router == null) {
      return null;
    }
    final CatalogFamilyStack? s = _read(router.routerDelegate.currentConfiguration);
    if (s != null) {
      _last[router] = s;
    }
    return s ?? _last[router];
  }

  static CatalogFamilyStack? _read(RouteMatchList config) {
    final List<RouteMatchBase>? branch = _catalogBranch(config.matches);
    if (branch == null) {
      return null;
    }
    String fullPath = config.fullPath;
    Uri uri = config.uri;
    Map<String, String> params = config.pathParameters;
    int depth = 0;
    final Set<ValueKey<String>> keys = <ValueKey<String>>{};
    bool contiguous = _familyPaths.contains(fullPath);
    for (final RouteMatchBase m in branch.skip(1)) {
      if (m is ImperativeRouteMatch) {
        final String fp = m.matches.isError ? '' : m.matches.fullPath;
        if (contiguous && _familyPaths.contains(fp)) {
          keys.add(m.pageKey);
          fullPath = fp;
          uri = m.matches.uri;
          params = m.matches.pathParameters;
          depth++;
        } else {
          contiguous = false;
        }
      } else if (contiguous) {
        // Запись `go` под `/catalog` (`c/:categoryId`, `search`).
        keys.add(m.pageKey);
      }
    }
    return CatalogFamilyStack._(fullPath: fullPath, uri: uri, pathParameters: params, depth: depth, passThrough: keys);
  }

  /// Записи ветки «Каталог» (первая — `/catalog` из `go`), если ветка в стеке.
  static List<RouteMatchBase>? _catalogBranch(List<RouteMatchBase> matches) {
    for (final RouteMatchBase m in matches) {
      if (m is ShellRouteMatch) {
        final List<RouteMatchBase> inner = m.matches;
        final RouteMatchBase? first = inner.isEmpty ? null : inner.first;
        if (first is RouteMatch && first is! ImperativeRouteMatch && first.route.path == '/catalog') {
          return inner;
        }
        final List<RouteMatchBase>? nested = _catalogBranch(inner);
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  /// Экран семейства для верхней записи.
  Widget screen() {
    final Map<String, String> qp = uri.queryParameters;
    return switch (fullPath) {
      '/catalog/c/:categoryId' => CatalogWorkspaceScreen(
        mode: CatalogScreenMode.category,
        categoryId: pathParameters['categoryId'],
        view: qp['view'],
        sort: qp['sort'],
        f: qp['f'],
        stackDepth: depth,
      ),
      '/catalog/search' => CatalogWorkspaceScreen(
        mode: CatalogScreenMode.search,
        q: qp['q'],
        categoryId: qp['categoryId'],
        view: qp['view'],
        sort: qp['sort'],
        stackDepth: depth,
      ),
      _ => CatalogWorkspaceScreen(
        mode: CatalogScreenMode.root,
        preset: qp['preset'],
        view: qp['view'],
        sort: qp['sort'],
        stackDepth: depth,
      ),
    };
  }
}

/// Запись семейства на medium+ рисуется страницей `/catalog` (без собственного содержимого).
bool catalogEntryPassesThrough(BuildContext context, GoRouterState state) =>
    CatalogFamilyStack.of(GoRouter.maybeOf(context))?.passThrough.contains(state.pageKey) ?? false;

/// Содержимое страницы `/catalog` на medium+: экран верхней записи семейства.
class CatalogFamilyHost extends StatelessWidget {
  /// Создаёт экран по состоянию страницы `/catalog` ([state] — запасной вариант, если стек не прочитан).
  const CatalogFamilyHost({required this.state, super.key});

  /// Состояние страницы `/catalog`.
  final GoRouterState state;

  @override
  Widget build(BuildContext context) =>
      (CatalogFamilyStack.of(GoRouter.maybeOf(context)) ?? CatalogFamilyStack.fromState(state)).screen();
}

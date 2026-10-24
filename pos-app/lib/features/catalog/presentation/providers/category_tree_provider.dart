// Дерево категорий для сайдбара SCR-10/12, полосы подкатегорий и листа «Все категории»
// (02 SCR-10.9 `categoryTreeProvider`; CAT-009): сначала кэш drift (≤ 100 мс), затем
// `GET /catalog/categories` (ETag). Ошибка сети при наличии кэша — показывается кэш.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';

final class CategoryTreeState {
  const CategoryTreeState({this.tree, this.loading = true, this.failure, this.source = DataSource.network});

  final CategoryTree? tree;

  /// Идёт загрузка (кэш или сеть).
  final bool loading;

  /// Последняя ошибка (при показанном кэше — не блокирует).
  final Failure? failure;
  final DataSource source;

  /// Дерево есть и не пустое.
  bool get hasData => tree != null && !tree!.isEmpty;

  /// Дерево загружено с сервера (для «Категория больше не существует» UI-12-009).
  bool get authoritative => tree != null && source == DataSource.network && !loading;

  CategoryTreeState copyWith({
    CategoryTree? tree,
    bool? loading,
    Failure? failure,
    bool clearFailure = false,
    DataSource? source,
  }) => CategoryTreeState(
    tree: tree ?? this.tree,
    loading: loading ?? this.loading,
    failure: clearFailure ? null : (failure ?? this.failure),
    source: source ?? this.source,
  );
}

final categoryTreeProvider = NotifierProvider<CategoryTreeController, CategoryTreeState>(CategoryTreeController.new);

final class CategoryTreeController extends Notifier<CategoryTreeState> {
  int _generation = 0;

  @override
  CategoryTreeState build() {
    unawaited(Future<void>.microtask(refresh));
    return const CategoryTreeState();
  }

  bool _alive(int gen) => ref.mounted && gen == _generation;

  /// Ошибка реализации порта (в т. ч. без привязки) — `UnknownFailure`, сайдбар показывает ошибку.
  Future<Result<CategoryTree>> _guard(Future<Result<CategoryTree>> Function(CatalogRepository repo) call) async {
    try {
      return await call(ref.read(catalogRepositoryProvider));
    } on Object catch (e) {
      return FailureResult<CategoryTree>(UnknownFailure(cause: e));
    }
  }

  /// Кэш → сеть. Повтор («Обновить») — тот же вызов.
  Future<void> refresh() async {
    final int gen = ++_generation;
    state = state.copyWith(loading: true, clearFailure: true);
    if (!state.hasData) {
      final Result<CategoryTree> cached = await _guard((CatalogRepository repo) => repo.cachedCategories());
      if (!_alive(gen)) {
        return;
      }
      final CategoryTree? tree = cached.valueOrNull;
      if (tree != null && !tree.isEmpty) {
        state = state.copyWith(tree: tree, source: DataSource.cache);
      }
    }
    final Result<CategoryTree> network = await _guard((CatalogRepository repo) => repo.categories());
    if (!_alive(gen)) {
      return;
    }
    state = switch (network) {
      Success<CategoryTree>(:final CategoryTree value) => CategoryTreeState(tree: value, loading: false),
      FailureResult<CategoryTree>(:final Failure failure) => state.copyWith(loading: false, failure: failure),
    };
  }
}

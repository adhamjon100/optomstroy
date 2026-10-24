// Единая модель состояния экрана с кэшем (06 §6.11, ARCH-027).
// AsyncValue Riverpod — для простых чтений; ScreenState<T> — для экранов с кэшем.
// Чистый Dart (FL-01): доступен presentation через core/error (L-9).
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';

/// Источник показанных данных.
enum DataSource { cache, network }

sealed class ScreenState<T> {
  const ScreenState();

  /// Строит состояние по результату загрузки (переходы диаграммы 06 §6.11 из Loading/Retrying).
  ///
  /// [isEmpty] — признак пустого результата; [cached]/[cachedAt] — локальные данные
  /// (drift) для перехода в Stale/Offline при `NetworkFailure`; [staleAfter] — порог
  /// устаревания единой шкалы 05 §7.4 (передаёт вызывающий), [now] — текущее время (Clock).
  static ScreenState<T> fromResult<T>(
    Result<T> result, {
    required DateTime now,
    bool Function(T value)? isEmpty,
    DataSource source = DataSource.network,
    DateTime? snapshotAt,
    T? cached,
    DateTime? cachedAt,
    Duration? staleAfter,
  }) {
    switch (result) {
      case Success<T>(:final value):
        if (isEmpty != null && isEmpty(value)) return ScreenEmpty<T>();
        return ScreenData<T>(value, source: source, snapshotAt: snapshotAt);
      case FailureResult<T>(:final failure):
        if (failure is PermissionFailure) return ScreenNoPermission<T>(failure.reason);
        if (failure is NetworkFailure) {
          if (cached == null) return ScreenOffline<T>();
          final stale = cachedAt == null || (staleAfter != null && now.difference(cachedAt) > staleAfter);
          if (stale) return ScreenStale<T>(cached, snapshotAt: cachedAt);
          return ScreenData<T>(cached, source: DataSource.cache, snapshotAt: cachedAt);
        }
        return ScreenError<T>(failure);
    }
  }

  /// Значение, которое можно показать (data/stale/offline с кэшем), иначе `null`.
  T? get visibleValue => switch (this) {
    ScreenData<T>(:final value) => value,
    ScreenStale<T>(:final value) => value,
    ScreenOffline<T>(:final cached) => cached,
    _ => null,
  };

  /// Идёт запрос: кнопки действий блокируются (06 §6.11 в).
  bool get isBusy => this is ScreenLoading<T> || this is ScreenRetrying<T>;
}

final class ScreenLoading<T> extends ScreenState<T> {
  const ScreenLoading();
}

final class ScreenData<T> extends ScreenState<T> {
  const ScreenData(this.value, {this.source = DataSource.network, this.snapshotAt});

  final T value;
  final DataSource source;

  /// Момент снимка данных (`X-Data-As-Of` / `sync_meta.as_of`).
  final DateTime? snapshotAt;
}

/// Данные из кэша старше порога — показывается SyncIndicator.
final class ScreenStale<T> extends ScreenState<T> {
  const ScreenStale(this.value, {this.snapshotAt});

  final T value;
  final DateTime? snapshotAt;
}

final class ScreenEmpty<T> extends ScreenState<T> {
  const ScreenEmpty();
}

final class ScreenError<T> extends ScreenState<T> {
  const ScreenError(this.failure);

  final Failure failure;
}

/// Нет сети; [cached] — что есть в кэше (может отсутствовать).
final class ScreenOffline<T> extends ScreenState<T> {
  const ScreenOffline([this.cached]);

  final T? cached;
}

final class ScreenNoPermission<T> extends ScreenState<T> {
  const ScreenNoPermission(this.reason);

  final PermissionReason reason;
}

/// Повтор после ошибки: предыдущая ошибка остаётся видимой, «Повторить» заблокирована.
final class ScreenRetrying<T> extends ScreenState<T> {
  const ScreenRetrying(this.previousFailure);

  final Failure previousFailure;
}

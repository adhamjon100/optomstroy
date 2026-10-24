// Результат операции domain/data: Success | FailureResult (06 §6.8).
// Use cases возвращают `Future<Result<T>>`; исключения из domain не выбрасываются.
import 'package:optomstroy/core/error/failure.dart';

sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;

  /// Значение или `null` при ошибке.
  T? get valueOrNull => switch (this) {
    Success<T>(:final value) => value,
    FailureResult<T>() => null,
  };

  /// Ошибка или `null` при успехе.
  Failure? get failureOrNull => switch (this) {
    Success<T>() => null,
    FailureResult<T>(:final failure) => failure,
  };

  R fold<R>(R Function(T value) onSuccess, R Function(Failure failure) onFailure) => switch (this) {
    Success<T>(:final value) => onSuccess(value),
    FailureResult<T>(:final failure) => onFailure(failure),
  };

  Result<R> map<R>(R Function(T value) transform) => switch (this) {
    Success<T>(:final value) => Success<R>(transform(value)),
    FailureResult<T>(:final failure) => FailureResult<R>(failure),
  };

  Future<Result<R>> flatMap<R>(Future<Result<R>> Function(T value) next) async => switch (this) {
    Success<T>(:final value) => next(value),
    FailureResult<T>(:final failure) => FailureResult<R>(failure),
  };
}

final class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;

  @override
  bool operator ==(Object other) => other is Success<T> && other.value == value;

  @override
  int get hashCode => Object.hash(Success, value);

  @override
  String toString() => 'Success<$T>';
}

final class FailureResult<T> extends Result<T> {
  const FailureResult(this.failure);

  final Failure failure;

  @override
  String toString() => 'FailureResult<$T>($failure)';
}

// Координатор step-up (08 §2.12; 09 §8.8; 02 SCR-90 зона B): `403 STEP_UP_REQUIRED` → StepUpDialog
// (presentation features/session_ui регистрирует презентер) → `stepUpToken` в кэш области на 15 мин →
// AuthInterceptor повторяет исходный запрос. Параллельные запросы одной операции ждут один диалог.
import 'dart:async';

import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:optomstroy/core/session/step_up_token_cache.dart';

export 'package:optomstroy/core/network/interceptors/session_hooks.dart' show StepUpChallenge;
export 'package:optomstroy/core/session/step_up_token_cache.dart' show StepUpGrant;

/// Показ StepUpDialog: [StepUpGrant] после успешного `POST /auth/step-up` или `null` — «Отмена».
typedef StepUpPresenter = Future<StepUpGrant?> Function(StepUpChallenge challenge);

final class StepUpCoordinator {
  StepUpCoordinator(this._cache);

  final StepUpTokenCache _cache;
  StepUpPresenter? _presenter;
  final Map<String, Future<String?>> _inflight = <String, Future<String?>>{};

  /// Кэш токенов (только память процесса).
  StepUpTokenCache get cache => _cache;

  /// Есть ли зарегистрированный презентер (смонтирован SessionGate).
  bool get hasPresenter => _presenter != null;

  /// Зарегистрировать презентер (SessionGate при монтировании).
  void attach(StepUpPresenter presenter) => _presenter = presenter;

  /// Снять презентер (только если он текущий).
  void detach(StepUpPresenter presenter) {
    if (identical(_presenter, presenter)) _presenter = null;
  }

  /// Действующий токен для [operation].
  String? tokenFor(String operation) => _cache.tokenFor(operation);

  /// Токен отвергнут сервером.
  void discard(String token) => _cache.discard(token);

  /// Получить токен для [challenge]: кэш → диалог (один на операцию). Без презентера — `null`.
  Future<String?> obtain(StepUpChallenge challenge) {
    final cached = _cache.tokenFor(challenge.operation);
    if (cached != null) return Future<String?>.value(cached);
    final presenter = _presenter;
    if (presenter == null) return Future<String?>.value();
    // `removeWhere` (void), а не `remove`: тот вернул бы этот же Future, и whenComplete ждал бы сам себя.
    return _inflight[challenge.operation] ??= _present(
      presenter,
      challenge,
    ).whenComplete(() => _inflight.removeWhere((operation, _) => operation == challenge.operation));
  }

  Future<String?> _present(StepUpPresenter presenter, StepUpChallenge challenge) async {
    final grant = await presenter(challenge);
    if (grant == null) return null;
    _cache.put(grant);
    return grant.token;
  }

  /// Выход / завершение / блокировка.
  void clear() => _cache.clear();
}

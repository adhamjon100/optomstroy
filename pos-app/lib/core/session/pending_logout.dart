// Отложенный выход после офлайн-выхода (перенос RM-E RC-1 / SS-07; ядро §19.4 — тип outbox `auth.logout`;
// 02 SCR-41 UI-41-005 «Выйти (офлайн)» п. 1–5, AC-UI-41-007, AC-UI-41-014; 09 §8.6, SESS-020; 08 §4.1.3, §4.1.4,
// §4.1.6).
//
// Порядок:
// 1. Выход без сети (или без ответа сервера): до локальной очистки refresh-токен сессии переносится в отдельную
//    запись secure storage `pending_logout` ([SecureKey.pendingLogout]) вместе с `sid` и временем выхода. Запись —
//    не сессия: TokenStore, AuthInterceptor и холодный старт её не читают, войти по ней нельзя.
// 2. При появлении сети (сигнал ConnectivityWatcher, старт приложения, повтор по таймеру, перед входом другого
//    пользователя) [PendingLogoutService.deliver] выполняет `POST /auth/refresh` с этим токеном → полученный
//    access используется только для `POST /auth/logout` → запись удаляется. Полученные токены живут только в памяти
//    вызова; ротированный refresh перезаписывает запись, пока logout не подтверждён.
// 3. Секрет удаляется во всех исходах: `204`; `401`/иные `4xx` на refresh или logout (сессия уже отозвана, reuse,
//    `DEVICE_MISMATCH`); истечение срока записи ([PendingLogoutService.maxAge]); повреждённая запись.
// 4. `401 UNLOCK_REQUIRED` на refresh (Windows, staff, D-48) или исчерпание попыток при ответах `5xx`: запись
//    помечается `fallback` и ждёт входа того же пользователя — обработчик outbox `auth.logout` в его сессии
//    отзывает старую сессию `DELETE /auth/sessions/{sid}` ([PendingLogoutService.settle]) и удаляет запись.
//
// Вход нового пользователя доставке не мешает: запись не входит в [SecureKey.session] и не удаляется очисткой
// сессии. Токены, `sid` и время в логи не пишутся.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/auth/token_refresher.dart';
import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:optomstroy/core/network/models/auth_token_pair.dart';
import 'package:optomstroy/core/network/models/problem.dart';
import 'package:optomstroy/core/session/session_api.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/sync/outbox_payloads.dart';
import 'package:optomstroy/core/utils/clock.dart';

final Logger _log = Logger('session.pending_logout');

/// Запись `pending_logout`: только `sid`, refresh прежней сессии, момент выхода и служебные признаки доставки.
final class PendingLogoutEntry {
  const PendingLogoutEntry({
    required this.refreshToken,
    required this.createdAt,
    this.sessionId,
    this.attempts = 0,
    this.fallback = false,
  });

  /// Разбор элемента записи; неполный элемент → `null` (удаляется).
  static PendingLogoutEntry? tryParse(Object? json) {
    if (json is! Map) return null;
    final Object? token = json['refreshToken'];
    final Object? at = json['createdAtMs'];
    if (token is! String || token.isEmpty || at is! int) return null;
    final Object? sid = json['sid'];
    final Object? attempts = json['attempts'];
    return PendingLogoutEntry(
      refreshToken: token,
      createdAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      sessionId: sid is String && sid.isNotEmpty ? sid : null,
      attempts: attempts is int ? attempts : 0,
      fallback: json['fallback'] == true,
    );
  }

  /// `sid` прежней сессии (claim access-токена или ответ refresh); `null` — неизвестен.
  final String? sessionId;

  /// Refresh-токен прежней сессии (kind `standard`) — только для `POST /auth/refresh` этой доставки.
  final String refreshToken; // check-secrets: allow — поле модели, значение не литерал

  /// Момент офлайн-выхода (UTC, точность — мс); совпадает с `AuthLogoutPayload.requestedAt` записи outbox.
  final DateTime createdAt;

  /// Ответов сервера с ошибкой (`5xx`, `429`) подряд; сбой без ответа не считается (как outbox, 07 §11.2).
  final int attempts;

  /// Refresh невозможен (`UNLOCK_REQUIRED` / исчерпаны попытки) — ждёт `DELETE /auth/sessions/{sid}` из новой
  /// сессии того же пользователя.
  final bool fallback;

  /// Запись outbox `auth.logout` относится к этой записи (по `sid`, иначе по моменту выхода).
  bool matches(AuthLogoutPayload payload) {
    final String? sid = payload.sessionId;
    if (sid != null && sessionId != null) return sid == sessionId;
    return payload.requestedAt.millisecondsSinceEpoch == createdAt.millisecondsSinceEpoch;
  }

  PendingLogoutEntry copyWith({String? refreshToken, String? sessionId, int? attempts, bool? fallback}) =>
      PendingLogoutEntry(
        refreshToken: refreshToken ?? this.refreshToken,
        createdAt: createdAt,
        sessionId: sessionId ?? this.sessionId,
        attempts: attempts ?? this.attempts,
        fallback: fallback ?? this.fallback,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'sid': ?sessionId,
    'refreshToken': refreshToken,
    'createdAtMs': createdAt.millisecondsSinceEpoch,
    if (attempts > 0) 'attempts': attempts,
    if (fallback) 'fallback': true,
  };

  @override
  String toString() => 'PendingLogoutEntry(***, attempts: $attempts, fallback: $fallback)';
}

/// Итог доставки одной записи.
enum PendingLogoutResult {
  /// `POST /auth/logout` → `204` (или `DELETE /auth/sessions/{sid}` → `204`): сессия отозвана, запись удалена.
  delivered,

  /// Сессия уже недействительна (`401`/`4xx` на refresh или logout, `404` на DELETE) — запись удалена.
  alreadyEnded,

  /// Нет сети / нет ответа сервера — запись сохранена, повтор позже.
  deferred,

  /// Ответ сервера с временной ошибкой (`5xx`, `429`) — запись сохранена, попытка учтена.
  failed,

  /// Refresh невозможен: запись ждёт входа владельца (`DELETE /auth/sessions/{sid}`).
  fallback,

  /// Записи нет (уже доставлена) — для обработчика outbox это успех.
  notFound,
}

/// Итог прохода [PendingLogoutService.deliver].
final class PendingLogoutReport {
  const PendingLogoutReport({this.delivered = 0, this.removed = 0, this.remaining = 0, this.deferred = false});

  /// Отозвано сервером в этом проходе.
  final int delivered;

  /// Удалено без отзыва (сессия уже завершена, срок, повреждение).
  final int removed;

  /// Осталось записей (ожидают сети или входа владельца).
  final int remaining;

  /// Проход упёрся в отсутствие связи / временную ошибку — запланирован повтор.
  final bool deferred;

  @override
  String toString() =>
      'PendingLogoutReport(delivered: $delivered, removed: $removed, remaining: $remaining, deferred: $deferred)';
}

/// Хранилище и доставка `pending_logout`.
final class PendingLogoutService {
  PendingLogoutService({
    required SecureStorage storage,
    required Dio Function() dio,
    required Clock clock,
    bool autoRetry = true,
  }) : _storage = storage,
       _dio = dio,
       _clock = clock,
       _autoRetry = autoRetry;

  final SecureStorage _storage;
  final Dio Function() _dio;
  final Clock _clock;
  final bool _autoRetry;

  /// Записи старше — удаляются без отправки: абсолютный срок standard-сессии 7 дней (09 §8.3) + запас.
  static const Duration maxAge = Duration(days: 8);

  /// Ответов сервера с ошибкой до перехода в `fallback` (как `outbox_actions`, 07 §11.2).
  static const int maxAttempts = 10;

  /// Не больше записей одновременно (каждый офлайн-выход — одна запись; старые вытесняются).
  static const int maxEntries = 5;

  /// Путь отзыва своей нетекущей сессии (08 §4.1.6).
  static String sessionPath(String sid) => '/auth/sessions/${Uri.encodeComponent(sid)}';

  /// Операция step-up `DELETE /auth/sessions/{id}` для нетекущей сессии (08 §2.12).
  static const String revokeOperation = 'session.revoke.other';

  Future<void> _tail = Future<void>.value();
  Future<PendingLogoutReport>? _inflight;
  Timer? _retry;
  int _retryRound = 0;
  StreamSubscription<void>? _network;
  bool _disposed = false;

  /// Задержка повтора после [round] неудачных проходов: 30 с · 2^(n−1), не более 15 мин.
  static Duration backoff(int round) {
    final int n = round < 1 ? 1 : (round > 10 ? 10 : round);
    final Duration d = Duration(seconds: 30 * (1 << (n - 1)));
    const Duration cap = Duration(minutes: 15);
    return d > cap ? cap : d;
  }

  /// Сохранённые записи (повреждённые и просроченные отбрасываются при следующей записи).
  Future<List<PendingLogoutEntry>> entries() => _serial(_read);

  /// Есть ли что доставлять.
  Future<bool> hasPending() async => (await entries()).isNotEmpty;

  /// Офлайн-выход: сохранить запись (до локальной очистки токенов сессии).
  Future<void> remember(PendingLogoutEntry entry) => _serial(() async {
    final List<PendingLogoutEntry> all = <PendingLogoutEntry>[...await _read(), entry];
    await _write(all.length > maxEntries ? all.sublist(all.length - maxEntries) : all);
  });

  /// Подписка на «сеть появилась» (ConnectivityWatcher) — немедленная доставка.
  void watchNetwork(Stream<void> restored) {
    unawaited(_network?.cancel());
    _network = restored.listen((_) => unawaited(deliver()));
  }

  /// Доставить все записи без `fallback` (single-flight; исключений не бросает).
  Future<PendingLogoutReport> deliver() => _inflight ??= _serial(_deliverAll).whenComplete(() => _inflight = null);

  /// Обработчик outbox `auth.logout` в сессии владельца ([revokeWithSession] — вызов `DELETE /auth/sessions/{sid}`
  /// с Bearer текущей сессии): запись не найдена — уже доставлена; иначе refresh → logout, а если refresh
  /// невозможен — отзыв из текущей сессии.
  Future<PendingLogoutResult> settle(
    AuthLogoutPayload payload, {
    required Future<PendingLogoutResult> Function(String sid) revokeWithSession,
  }) => _serial(() async {
    final List<PendingLogoutEntry> all = await _read();
    final int index = all.indexWhere((PendingLogoutEntry e) => e.matches(payload));
    if (index < 0) return PendingLogoutResult.notFound;
    PendingLogoutEntry entry = all[index];
    if (!entry.fallback) {
      final _Step step = await _deliverOne(entry);
      await _replace(entry, step.next);
      if (step.result != PendingLogoutResult.fallback) return step.result;
      entry = step.next!;
    }
    final String? sid = entry.sessionId ?? payload.sessionId;
    if (sid == null) {
      // Отозвать нечем: refresh недоступен, `sid` неизвестен — секрет не хранится дальше (сессия истечёт сама).
      await _replace(entry, null);
      _log.info('pending_logout: sid неизвестен — запись удалена без отзыва');
      return PendingLogoutResult.alreadyEnded;
    }
    final PendingLogoutResult revoked = await revokeWithSession(sid);
    if (revoked == PendingLogoutResult.delivered || revoked == PendingLogoutResult.alreadyEnded) {
      await _replace(entry, null);
    }
    return revoked;
  });

  /// `DELETE /auth/sessions/{sid}` через основной Dio (Bearer текущей сессии владельца). StepUpDialog из фона не
  /// показывается: используется только действующий `stepUpToken` области `session.revoke.other` из кэша.
  static Future<PendingLogoutResult> revokeOwnSession(Dio dio, String sid) async {
    final Options options = apiOptions(retry: RetryProfile.none);
    options.extra!
      ..[SessionRequestExtra.stepUpOperation] = revokeOperation
      ..[SessionRequestExtra.stepUpPrompted] = true;
    try {
      await dio.delete<Object?>(sessionPath(sid), options: options);
      return PendingLogoutResult.delivered;
    } on DioException catch (e) {
      final int? status = e.response?.statusCode;
      // 404 — сессии уже нет. 401 относится к текущей сессии (её обслуживает AuthInterceptor) — повтор позже.
      if (status == 404) return PendingLogoutResult.alreadyEnded;
      if (status == 401) return PendingLogoutResult.deferred;
      return _transient(e) ? _deferredOrFailed(e) : PendingLogoutResult.failed;
    }
  }

  /// Удалить все записи (только для тестов и полного сброса устройства).
  Future<void> clear() => _serial(() => _storage.delete(SecureKey.pendingLogout));

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _retry = null;
    unawaited(_network?.cancel());
    _network = null;
  }

  // --- Внутреннее ---

  Future<PendingLogoutReport> _deliverAll() async {
    var delivered = 0;
    var removed = 0;
    var deferred = false;
    final List<PendingLogoutEntry> left = <PendingLogoutEntry>[];
    List<PendingLogoutEntry> all;
    try {
      all = await _read();
    } on Object catch (e) {
      _log.fine('pending_logout: хранилище недоступно (${e.runtimeType})');
      return const PendingLogoutReport();
    }
    if (all.isEmpty) {
      _retryRound = 0;
      // Просроченные / повреждённые записи отброшены чтением — секрет удаляется и с диска.
      final bool stale = _stale;
      if (stale) {
        try {
          await _write(const <PendingLogoutEntry>[]);
        } on Object catch (e) {
          _log.fine('pending_logout: удаление не выполнено (${e.runtimeType})');
        }
      }
      return PendingLogoutReport(removed: stale ? 1 : 0);
    }
    for (final PendingLogoutEntry entry in all) {
      if (deferred || entry.fallback) {
        left.add(entry);
        continue;
      }
      final _Step step = await _deliverOne(entry);
      switch (step.result) {
        case PendingLogoutResult.delivered:
          delivered++;
        case PendingLogoutResult.alreadyEnded || PendingLogoutResult.notFound:
          removed++;
        case PendingLogoutResult.deferred || PendingLogoutResult.failed:
          deferred = true;
          left.add(step.next!);
        case PendingLogoutResult.fallback:
          left.add(step.next!);
      }
    }
    try {
      await _write(left);
    } on Object catch (e) {
      _log.warning('pending_logout: запись не сохранена (${e.runtimeType})');
    }
    if (deferred) {
      _scheduleRetry();
    } else {
      _retryRound = 0;
    }
    final PendingLogoutReport report = PendingLogoutReport(
      delivered: delivered,
      removed: removed,
      remaining: left.length,
      deferred: deferred,
    );
    _log.info('pending_logout: $report');
    return report;
  }

  /// refresh → logout для одной записи. [_Step.next] — запись после шага (`null` — удалить).
  Future<_Step> _deliverOne(PendingLogoutEntry entry) async {
    final Dio dio;
    try {
      dio = _dio();
    } on Object catch (e) {
      _log.fine('pending_logout: сеть не готова (${e.runtimeType})');
      return _Step(PendingLogoutResult.deferred, entry);
    }
    // 1. POST /auth/refresh (тело — refresh записи; без Bearer и без интерсептора авторизации).
    final AuthTokenPair pair;
    try {
      final Response<Map<String, dynamic>> r = await dio.post<Map<String, dynamic>>(
        DioTokenRefresher.path,
        data: <String, Object?>{'refreshToken': entry.refreshToken},
        options: apiOptions(skipAuth: true, retry: RetryProfile.none),
      );
      pair = AuthTokenPair.fromJson(r.data!);
    } on DioException catch (e) {
      if (_transient(e)) return _countFailure(entry, e);
      if (Problem.codeOf(e.response?.data) == 'UNLOCK_REQUIRED') {
        return _Step(PendingLogoutResult.fallback, entry.copyWith(fallback: true));
      }
      // SESSION_REVOKED (отозвана, истекла, reuse), DEVICE_MISMATCH, VALIDATION_FAILED — сессии нет.
      return const _Step(PendingLogoutResult.alreadyEnded, null);
    } on Object catch (e) {
      // Неразборчивый ответ refresh — сбой без ответа сервера: запись остаётся.
      _log.fine('pending_logout: refresh (${e.runtimeType})');
      return _Step(PendingLogoutResult.deferred, entry);
    }
    // Ротация: новый refresh заменяет прежний в записи, пока logout не подтверждён.
    final PendingLogoutEntry rotated = entry.copyWith(
      refreshToken: pair.refreshToken,
      sessionId: entry.sessionId ?? pair.sid,
      attempts: 0,
    );
    // 2. POST /auth/logout с access этой доставки (только память вызова).
    final Options options = apiOptions(skipAuth: true, retry: RetryProfile.none);
    options.headers![ApiHeaders.authorization] = 'Bearer ${pair.accessToken}';
    try {
      await dio.post<Object?>(SessionApi.logoutPath, options: options);
      return const _Step(PendingLogoutResult.delivered, null);
    } on DioException catch (e) {
      if (_transient(e)) return _countFailure(rotated, e);
      // 401 SESSION_REVOKED и прочие 4xx — сессия уже недействительна или запрос неисправим: секрет не храним.
      return const _Step(PendingLogoutResult.alreadyEnded, null);
    }
  }

  _Step _countFailure(PendingLogoutEntry entry, DioException e) {
    final PendingLogoutResult r = _deferredOrFailed(e);
    if (r == PendingLogoutResult.deferred) return _Step(r, entry);
    final int attempts = entry.attempts + 1;
    if (attempts >= maxAttempts) {
      return _Step(PendingLogoutResult.fallback, entry.copyWith(attempts: attempts, fallback: true));
    }
    return _Step(r, entry.copyWith(attempts: attempts));
  }

  /// Нет ответа сервера (сеть, таймаут, 502–504) / временная ошибка сервера (`5xx`, `429`).
  static bool _transient(DioException e) {
    if (e.type != DioExceptionType.badResponse) return true;
    final int status = e.response?.statusCode ?? 0;
    return status >= 500 || status == 429 || status == 408;
  }

  static PendingLogoutResult _deferredOrFailed(DioException e) {
    final int status = e.response?.statusCode ?? 0;
    final bool responded = e.type == DioExceptionType.badResponse && status != 502 && status != 503 && status != 504;
    return responded ? PendingLogoutResult.failed : PendingLogoutResult.deferred;
  }

  void _scheduleRetry() {
    if (!_autoRetry || _disposed) return;
    _retry?.cancel();
    _retryRound++;
    _retry = Timer(backoff(_retryRound), () {
      _retry = null;
      if (!_disposed) unawaited(deliver());
    });
  }

  Future<void> _replace(PendingLogoutEntry old, PendingLogoutEntry? next) async {
    final List<PendingLogoutEntry> all = await _read();
    final List<PendingLogoutEntry> out = <PendingLogoutEntry>[
      for (final PendingLogoutEntry e in all)
        if (e.createdAt == old.createdAt && e.sessionId == old.sessionId) ?next else e,
    ];
    await _write(out);
  }

  /// Последнее чтение отбросило элементы (просрочены / повреждены) — запись на диске нужно переписать.
  bool _stale = false;

  Future<List<PendingLogoutEntry>> _read() async {
    _stale = false;
    final String? raw = await _storage.read(SecureKey.pendingLogout);
    if (raw == null || raw.isEmpty) return const <PendingLogoutEntry>[];
    final DateTime oldest = _clock.nowUtc().subtract(maxAge);
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) {
        _stale = true;
        return const <PendingLogoutEntry>[];
      }
      final List<PendingLogoutEntry> out = <PendingLogoutEntry>[
        for (final Object? item in decoded)
          if (PendingLogoutEntry.tryParse(item) case final PendingLogoutEntry e when e.createdAt.isAfter(oldest)) e,
      ];
      _stale = out.length != decoded.length;
      return out;
    } on FormatException {
      _stale = true;
      return const <PendingLogoutEntry>[];
    }
  }

  Future<void> _write(List<PendingLogoutEntry> entries) async {
    if (entries.isEmpty) {
      await _storage.delete(SecureKey.pendingLogout);
      return;
    }
    await _storage.write(
      SecureKey.pendingLogout,
      jsonEncode(<Map<String, Object?>>[for (final PendingLogoutEntry e in entries) e.toJson()]),
    );
  }

  /// Последовательное выполнение операций над записью (доставка, outbox, новый офлайн-выход).
  Future<T> _serial<T>(Future<T> Function() action) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await action());
      } on Object catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }
}

final class _Step {
  const _Step(this.result, this.next);

  final PendingLogoutResult result;

  /// Запись после шага; `null` — удалить.
  final PendingLogoutEntry? next;
}

/// Сервис отложенного выхода (живёт всё время работы приложения; сеть — основной Dio с `skipAuth`).
final pendingLogoutServiceProvider = Provider<PendingLogoutService>((ref) {
  final PendingLogoutService service = PendingLogoutService(
    storage: ref.watch(secureStorageProvider),
    dio: () => ref.read(dioProvider),
    clock: ref.watch(clockProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

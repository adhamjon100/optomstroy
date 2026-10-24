// Состояние центра уведомлений SCR-44 и колокольчика (02 SCR-44.4, SCR-44.7; 08 §4.16; D-41; ядро §19.4).
//
// - Список: `GET /notifications?unread=&kind=&limit=30&cursor=` (курсор, ≤ 100 в кэше); ответ обновляет кэш
//   (репозиторий). Нет сети — последние 100 из `notifications_cache`; 5xx без кэша — ошибка, с кэшем — «устаревшие».
// - Опрос: `GET /notifications?since=<последний createdAt>&limit=100` при старте, по возврату в foreground (экран)
//   и каждые 60 с ([notificationsPollIntervalProvider]); новые элементы — сверху, счётчик [NotificationsCenterState.newAbove].
// - Отметки о прочтении — единый механизм: сразу локально (строка прочитана, бейдж уменьшен), затем
//   `POST /notifications/{id}/read` / `POST /notifications/read-all` с `Idempotency-Key`; нет сети или запрос не
//   прошёл — `NotificationReadQueue` (кэш `read_at` + outbox `notification.read`, переживает перезапуск).
// - Бейдж `NotificationBell` — [notificationsBadgeProvider]; баннеры экранов — [notificationBannerProvider].
// Провайдеры без кодогенерации (этап F).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';
import 'package:optomstroy/features/notifications/domain/repositories/notifications_repository.dart';
import 'package:optomstroy/features/notifications/notifications_providers.dart';
import 'package:uuid/uuid.dart';

/// Интервал фонового опроса (08 §4.16.1: 60 с); `null` — без таймера (тесты, golden).
final notificationsPollIntervalProvider = Provider<Duration?>((ref) => const Duration(seconds: 60));

/// Фаза загрузки списка (02 SCR-44.7).
enum NotificationsPhase { loading, ready, error }

/// Объявление нового уведомления `severity=error` (UI-44-011): показ — у вызывающего (снекбар), не чаще 1 раза в 60 с.
final class NotificationAnnouncement {
  const NotificationAnnouncement(this.seq, this.notification);

  /// Номер события (экран показывает событие с новым номером один раз).
  final int seq;
  final AppNotification notification;
}

/// Состояние SCR-44 / колокольчика.
final class NotificationsCenterState {
  const NotificationsCenterState({
    this.items = const <AppNotification>[],
    this.unread = 0,
    this.unreadOnly = false,
    this.kinds = const <NotificationKind>{},
    this.phase = NotificationsPhase.loading,
    this.fromCache = false,
    this.failure,
    this.syncedAt,
    this.nextCursor,
    this.hasMore = false,
    this.loadingMore = false,
    this.readingAll = false,
    this.localReads = const <String>{},
    this.readAllAt,
    this.newAbove = 0,
    this.announcement,
  });

  /// Уведомления текущего фильтра, новые первыми.
  final List<AppNotification> items;

  /// Число непрочитанных (бейдж) с учётом локальных отметок.
  final int unread;

  /// Сегмент «Непрочитанные» (`unread=1`).
  final bool unreadOnly;

  /// Фильтр видов (пусто — все).
  final Set<NotificationKind> kinds;
  final NotificationsPhase phase;

  /// Список показан из `notifications_cache` (нет сети / сервер недоступен).
  final bool fromCache;

  /// Ошибка последнего запроса списка/опроса.
  final Failure? failure;

  /// Время последнего успешного ответа сервера (UTC).
  final DateTime? syncedAt;
  final String? nextCursor;
  final bool hasMore;
  final bool loadingMore;

  /// «Прочитать все» выполняется.
  final bool readingAll;

  /// Отметки «прочитано», ещё не подтверждённые сервером.
  final Set<String> localReads;

  /// Момент локального «Прочитать все» (всё созданное не позже — прочитано).
  final DateTime? readAllAt;

  /// Новые сверху с прошлого показа (плашка «N новых ↑»).
  final int newAbove;
  final NotificationAnnouncement? announcement;

  /// Прочитано с учётом локальных отметок.
  bool isRead(AppNotification n) =>
      n.isRead || localReads.contains(n.id) || (readAllAt != null && !n.createdAt.isAfter(readAllAt!));

  /// Строки к показу: в сегменте «Непрочитанные» прочитанные (в т. ч. локально) скрыты.
  List<AppNotification> get visible => unreadOnly
      ? <AppNotification>[
          for (final AppNotification n in items)
            if (!isRead(n)) n,
        ]
      : items;

  /// Есть непрочитанная ошибка синхронизации (`notifications_active` у колокольчика).
  bool get hasUnreadSyncError => items.any((AppNotification n) => n.kind == NotificationKind.syncError && !isRead(n));

  NotificationsCenterState copyWith({
    List<AppNotification>? items,
    int? unread,
    bool? unreadOnly,
    Set<NotificationKind>? kinds,
    NotificationsPhase? phase,
    bool? fromCache,
    Failure? failure,
    bool clearFailure = false,
    DateTime? syncedAt,
    String? nextCursor,
    bool clearCursor = false,
    bool? hasMore,
    bool? loadingMore,
    bool? readingAll,
    Set<String>? localReads,
    DateTime? readAllAt,
    bool clearReadAll = false,
    int? newAbove,
    NotificationAnnouncement? announcement,
  }) => NotificationsCenterState(
    items: items ?? this.items,
    unread: unread ?? this.unread,
    unreadOnly: unreadOnly ?? this.unreadOnly,
    kinds: kinds ?? this.kinds,
    phase: phase ?? this.phase,
    fromCache: fromCache ?? this.fromCache,
    failure: clearFailure ? null : (failure ?? this.failure),
    syncedAt: syncedAt ?? this.syncedAt,
    nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    readingAll: readingAll ?? this.readingAll,
    localReads: localReads ?? this.localReads,
    readAllAt: clearReadAll ? null : (readAllAt ?? this.readAllAt),
    newAbove: newAbove ?? this.newAbove,
    announcement: announcement ?? this.announcement,
  );
}

/// Центр уведомлений: один на сессию пользователя (смена пользователя — новое состояние).
final notificationsCenterProvider = NotifierProvider<NotificationsCenterController, NotificationsCenterState>(
  NotificationsCenterController.new,
);

/// Бейдж колокольчика: число непрочитанных и признак непрочитанной `sync_error` (UI-44-005).
final notificationsBadgeProvider = Provider<({int unread, bool syncError})>((ref) {
  final NotificationsCenterState s = ref.watch(notificationsCenterProvider);
  return (unread: s.unread, syncError: s.hasUnreadSyncError);
});

/// Где показывается баннер уведомления (RM-F-008): корзина SCR-20/CartPanel, оформление SCR-21, заказ SCR-24.
enum NotificationBannerScope {
  /// `cart_price_changed`, `cart_stock_changed`.
  cart({NotificationKind.cartPriceChanged, NotificationKind.cartStockChanged}),

  /// `cart_price_changed`, `cart_stock_changed`, `credit_blocked`.
  checkout({NotificationKind.cartPriceChanged, NotificationKind.cartStockChanged, NotificationKind.creditBlocked}),

  /// `credit_blocked` по заказу.
  order({NotificationKind.creditBlocked});

  const NotificationBannerScope(this.kinds);

  final Set<NotificationKind> kinds;
}

/// Последнее непрочитанное уведомление для баннера экрана; `id` — `cartId` (cart/checkout) или `orderId` (order):
/// уведомление с другим объектом в `payload` не показывается (без объекта в `payload` — показывается).
final notificationBannerProvider = Provider.family<AppNotification?, (NotificationBannerScope, String?)>((ref, arg) {
  final (NotificationBannerScope scope, String? id) = arg;
  final NotificationsCenterState s = ref.watch(notificationsCenterProvider);
  for (final AppNotification n in s.items) {
    final NotificationKind? kind = n.kind;
    if (kind == null || !scope.kinds.contains(kind) || s.isRead(n)) continue;
    if (id != null) {
      final Object? target = scope == NotificationBannerScope.order ? n.orderId : n.payload['cartId'];
      if (target is String && target != id) continue;
    }
    return n;
  }
  return null;
});

/// Контроллер SCR-44.
final class NotificationsCenterController extends Notifier<NotificationsCenterState> {
  static const int pageSize = 30;

  /// Порог «устаревших данных» (02 SCR-44.7).
  static const Duration staleAfter = Duration(minutes: 5);

  /// Не чаще одного объявления в 60 с (UI-44-011).
  static const Duration announceEvery = Duration(seconds: 60);

  Timer? _timer;
  int _generation = 0;
  Future<void>? _loading;
  String? _loadingKey;
  int _announceSeq = 0;
  DateTime? _lastAnnounceAt;
  final Uuid _uuid = const Uuid();

  NotificationsRepository get _repo => ref.read(notificationsRepositoryProvider);

  @override
  NotificationsCenterState build() {
    // Пользователь сессии сменился — состояние и очередь отметок начинаются заново.
    ref.watch(outboxOwnerProvider);
    _generation++;
    _loading = null;
    ref.onDispose(() => _timer?.cancel());
    // Сеть восстановлена — список из кэша сменяется ответом сервера (02 SCR-44.7 `cached → loading`).
    ref.listen<AsyncValue<OnlineStatus>>(onlineStatusProvider, (AsyncValue<OnlineStatus>? prev, next) {
      final OnlineStatus? was = prev?.value;
      final OnlineStatus? now = next.value;
      if (was == OnlineStatus.offline && now != null && now != OnlineStatus.offline) unawaited(load());
    });
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(load());
    });
    final Duration? period = ref.watch(notificationsPollIntervalProvider);
    if (period != null) {
      _timer = Timer.periodic(period, (_) {
        if (ref.mounted) unawaited(poll());
      });
    }
    return const NotificationsCenterState();
  }

  bool get _offline => ref.read(onlineStatusProvider).value == OnlineStatus.offline;

  DateTime get _now => ref.read(clockProvider).nowUtc();

  /// Загрузить первую страницу текущего фильтра (single-flight: повтор с тем же фильтром ждёт текущий запрос).
  Future<void> load() {
    final String key = '${state.unreadOnly}|${state.kinds.map((NotificationKind k) => k.value).join(',')}';
    final Future<void>? inflight = _loading;
    if (inflight != null && key == _loadingKey) return inflight;
    _loadingKey = key;
    late final Future<void> f;
    f = _load().whenComplete(() {
      if (identical(_loading, f)) _loading = null;
    });
    return _loading = f;
  }

  Future<void> _load() async {
    final int gen = _generation;
    if (state.items.isEmpty) state = state.copyWith(phase: NotificationsPhase.loading);
    final Result<NotificationsPage> r = await _repo.list(
      NotificationsQuery(unreadOnly: state.unreadOnly, kinds: state.kinds, limit: pageSize),
    );
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<NotificationsPage>(:final NotificationsPage value):
        state = _applyPage(value, replace: true).copyWith(newAbove: 0);
      case FailureResult<NotificationsPage>(:final Failure failure):
        await _fallbackToCache(failure, gen);
    }
  }

  /// Сменить сегмент «Все / Непрочитанные».
  Future<void> setUnreadOnly(bool unreadOnly) async {
    if (unreadOnly == state.unreadOnly) return;
    state = state.copyWith(unreadOnly: unreadOnly, items: const <AppNotification>[], clearCursor: true, hasMore: false);
    await load();
  }

  /// Переключить вид в фильтре (мультивыбор; пусто — все).
  Future<void> toggleKinds(Set<NotificationKind> group) async {
    final Set<NotificationKind> next = <NotificationKind>{...state.kinds};
    if (group.every(next.contains)) {
      next.removeAll(group);
    } else {
      next.addAll(group);
    }
    await setKinds(next);
  }

  /// Задать фильтр видов.
  Future<void> setKinds(Set<NotificationKind> kinds) async {
    state = state.copyWith(kinds: kinds, items: const <AppNotification>[], clearCursor: true, hasMore: false);
    await load();
  }

  /// Сбросить фильтры (сегмент и виды).
  Future<void> resetFilters() async {
    state = state.copyWith(
      unreadOnly: false,
      kinds: const <NotificationKind>{},
      items: const <AppNotification>[],
      clearCursor: true,
      hasMore: false,
    );
    await load();
  }

  /// Следующая страница (курсор).
  Future<void> loadMore() async {
    final String? cursor = state.nextCursor;
    if (cursor == null || !state.hasMore || state.loadingMore || state.fromCache) return;
    final int gen = _generation;
    state = state.copyWith(loadingMore: true);
    final Result<NotificationsPage> r = await _repo.list(
      NotificationsQuery(unreadOnly: state.unreadOnly, kinds: state.kinds, limit: pageSize, cursor: cursor),
    );
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<NotificationsPage>(:final NotificationsPage value):
        final Set<String> known = <String>{for (final AppNotification n in state.items) n.id};
        state = state.copyWith(
          items: <AppNotification>[
            ...state.items,
            for (final AppNotification n in value.items)
              if (!known.contains(n.id)) n,
          ],
          nextCursor: value.nextCursor,
          clearCursor: value.nextCursor == null,
          hasMore: value.hasMore,
          loadingMore: false,
          unread: _adjustedUnread(value),
        );
      case FailureResult<NotificationsPage>(:final Failure failure):
        state = state.copyWith(loadingMore: false, failure: failure);
    }
  }

  /// Инкрементальный опрос (`since`); без данных или из кэша — полная загрузка.
  Future<void> poll() async {
    if (_offline) return;
    if (state.phase != NotificationsPhase.ready || state.fromCache || state.items.isEmpty) return load();
    final int gen = _generation;
    final DateTime since = state.items.map((AppNotification n) => n.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
    final Result<NotificationsPage> r = await _repo.list(
      NotificationsQuery(unreadOnly: state.unreadOnly, kinds: state.kinds, since: since, limit: 100),
    );
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<NotificationsPage>(:final NotificationsPage value):
        final Set<String> known = <String>{for (final AppNotification n in state.items) n.id};
        final List<AppNotification> fresh = <AppNotification>[
          for (final AppNotification n in value.items)
            if (!known.contains(n.id)) n,
        ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        state = state.copyWith(
          items: <AppNotification>[...fresh, ...state.items],
          unread: _adjustedUnread(value),
          syncedAt: _now,
          clearFailure: true,
          newAbove: state.newAbove + fresh.length,
          announcement: _announce(fresh),
        );
      case FailureResult<NotificationsPage>(:final Failure failure):
        state = state.copyWith(failure: failure);
    }
  }

  /// Пользователь увидел новые строки (прокрутка к началу / тап по плашке).
  void clearNewAbove() {
    if (state.newAbove != 0) state = state.copyWith(newAbove: 0);
  }

  /// Отметить прочитанным (тап, свайп, меню). Повтор — без запроса.
  Future<void> markRead(String id) async {
    final AppNotification? n = state.items.where((AppNotification e) => e.id == id).firstOrNull;
    if (n != null && state.isRead(n)) return;
    final int gen = _generation;
    state = state.copyWith(localReads: <String>{...state.localReads, id}, unread: math.max(0, state.unread - 1));
    if (_offline) {
      await _queueRead(id);
      return;
    }
    final Result<int> r = await _repo.markRead(id, idempotencyKey: _uuid.v4());
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<int>(:final int value):
        state = _confirmRead(<String>{id}, unread: math.max(0, value - _pendingUnconfirmed(except: id)));
      case FailureResult<int>(failure: ServerFailure(status: 404)):
        // Уведомление удалено (срок хранения) — отмечать нечего.
        state = _confirmRead(<String>{id});
      case FailureResult<int>():
        await _queueRead(id);
    }
  }

  /// «Прочитать все» (идемпотентно; подтверждение не требуется).
  Future<void> markAllRead() async {
    if (state.readingAll) return;
    final int gen = _generation;
    state = state.copyWith(readingAll: true, unread: 0);
    final DateTime now = _now;
    // Граница «до момента действия» сравнивается сервером с `created_at` во времени сервера, поэтому это `createdAt`
    // самого нового известного уведомления (часы устройства могут отставать, RC-6); ничего не известно — часы устройства.
    final DateTime? newest = await _newestKnownCreatedAt();
    if (!ref.mounted || gen != _generation) return;
    final DateTime before = newest ?? now;
    if (_offline) {
      // Офлайн (`POST /notifications/read-all?before=`, OpenAPI 1.2.0, 08 §4.16.2): пришедшие после действия
      // уведомления (в том числе к моменту отправки из очереди) остаются непрочитанными.
      state = state.copyWith(readAllAt: before);
      await ref.read(notificationReadQueueProvider)?.enqueueReadAll(before: before);
      if (ref.mounted && gen == _generation) state = state.copyWith(readingAll: false);
      return;
    }
    // Онлайн — без `before`: сервер отмечает непрочитанные на момент обработки (08 §4.16.2 «Уточнения»); локально
    // прочитаны все показанные, даже если часы устройства отстают от сервера.
    state = state.copyWith(readAllAt: newest != null && newest.isAfter(now) ? newest : now);
    final Result<int> r = await _repo.markAllRead(idempotencyKey: _uuid.v4());
    if (!ref.mounted || gen != _generation) return;
    switch (r) {
      case Success<int>(:final int value):
        state = state.copyWith(readingAll: false, unread: value);
      case FailureResult<int>():
        await ref.read(notificationReadQueueProvider)?.enqueueReadAll(before: before);
        if (ref.mounted && gen == _generation) state = state.copyWith(readingAll: false);
    }
  }

  /// `createdAt` самого нового уведомления среди показанных и кэша устройства (время сервера); `null` — ни одного.
  Future<DateTime?> _newestKnownCreatedAt() async {
    DateTime? newest;
    void consider(AppNotification n) {
      if (newest == null || n.createdAt.isAfter(newest!)) newest = n.createdAt;
    }

    state.items.forEach(consider);
    try {
      (await _repo.watchCached().first).forEach(consider);
    } on Object {
      // Кэш недоступен (БД закрыта) — граница по показанным.
    }
    return newest;
  }

  Future<void> _queueRead(String id) async {
    await ref.read(notificationReadQueueProvider)?.enqueueRead(id);
  }

  Future<void> _fallbackToCache(Failure failure, int gen) async {
    List<AppNotification> cached = const <AppNotification>[];
    int cachedUnread = 0;
    try {
      cached = await _repo.watchCached(unreadOnly: state.unreadOnly).first;
      cachedUnread = await _repo.watchCachedUnreadCount().first;
    } on Object {
      // Кэш недоступен (БД закрыта) — как пустой.
    }
    if (!ref.mounted || gen != _generation) return;
    if (state.kinds.isNotEmpty) {
      cached = <AppNotification>[
        for (final AppNotification n in cached)
          if (state.kinds.contains(n.kind)) n,
      ];
    }
    final bool network = failure is NetworkFailure;
    // Уже показанный список сервера не заменяется кэшем: ошибка — признак «устаревших данных».
    if (state.items.isNotEmpty && !state.fromCache) {
      state = state.copyWith(failure: failure, phase: NotificationsPhase.ready);
      return;
    }
    final bool showCache = network || cached.isNotEmpty;
    final Set<String> pending = state.localReads;
    final DateTime? all = state.readAllAt;
    // Кэш уже содержит отметки очереди; в памяти — только те, что в БД не попали (БД закрыта).
    final int unread = all != null
        ? cached.where((AppNotification n) => !n.isRead && n.createdAt.isAfter(all)).length
        : math.max(0, cachedUnread - cached.where((AppNotification n) => !n.isRead && pending.contains(n.id)).length);
    state = state.copyWith(
      items: cached,
      unread: unread,
      fromCache: true,
      failure: failure,
      phase: showCache ? NotificationsPhase.ready : NotificationsPhase.error,
      clearCursor: true,
      hasMore: false,
    );
  }

  NotificationsCenterState _applyPage(NotificationsPage page, {required bool replace}) {
    // Отметки, подтверждённые сервером (readAt пришёл), больше не нужны в памяти.
    final Set<String> confirmed = <String>{
      for (final AppNotification n in page.items)
        if (n.isRead) n.id,
    };
    return state.copyWith(
      items: page.items,
      unread: _adjustedUnread(page),
      phase: NotificationsPhase.ready,
      fromCache: false,
      clearFailure: true,
      syncedAt: _now,
      nextCursor: page.nextCursor,
      clearCursor: page.nextCursor == null,
      hasMore: page.hasMore,
      loadingMore: false,
      localReads: state.localReads.difference(confirmed),
    );
  }

  /// `unreadCount` сервера минус локальные отметки, которые сервер ещё не учёл.
  int _adjustedUnread(NotificationsPage page) {
    final DateTime? all = state.readAllAt;
    if (all != null) {
      // Локальное «Прочитать все» ещё в очереди: непрочитанными остаются только более новые.
      return page.items.where((AppNotification n) => !n.isRead && n.createdAt.isAfter(all)).length;
    }
    final int pending = page.items.where((AppNotification n) => !n.isRead && state.localReads.contains(n.id)).length;
    return math.max(0, page.unreadCount - pending);
  }

  int _pendingUnconfirmed({required String except}) => state.localReads.where((String id) => id != except).length;

  NotificationsCenterState _confirmRead(Set<String> ids, {int? unread}) {
    final DateTime at = _now;
    return state.copyWith(
      items: <AppNotification>[
        for (final AppNotification n in state.items) ids.contains(n.id) && !n.isRead ? _read(n, at) : n,
      ],
      localReads: state.localReads.difference(ids),
      unread: unread,
    );
  }

  NotificationAnnouncement? _announce(List<AppNotification> fresh) {
    final AppNotification? error = fresh
        .where((AppNotification n) => n.severity == NotificationSeverity.error && !state.isRead(n))
        .firstOrNull;
    if (error == null) return null;
    final DateTime now = _now;
    if (_lastAnnounceAt != null && now.difference(_lastAnnounceAt!) < announceEvery) return null;
    _lastAnnounceAt = now;
    return NotificationAnnouncement(++_announceSeq, error);
  }

  static AppNotification _read(AppNotification n, DateTime at) => AppNotification(
    id: n.id,
    rawKind: n.rawKind,
    title: n.title,
    body: n.body,
    createdAt: n.createdAt,
    severity: n.severity,
    orderId: n.orderId,
    paymentId: n.paymentId,
    target: n.target,
    payload: n.payload,
    readAt: at,
  );
}

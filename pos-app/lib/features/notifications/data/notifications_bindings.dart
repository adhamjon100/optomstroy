// Привязка порта фичи notifications к реализации data (06 §6.14, L-8). Подключение — `app/di/overrides.dart`.
// БД — `appDatabaseProvider` (файл пользователя; `null` до входа — кэш пуст).
//
// RM-F-008 (F-fe-notif): офлайн-отметки «прочитано» — [notificationReadQueueProvider] (кэш + outbox
// `notification.read`); обработчик очереди — [notificationsOutboxHandlers], корень добавляет его в реестр
// `outboxHandlersProvider` (core/sync) вместе с обработчиками других фич.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/features/notifications/data/offline/notification_read_outbox.dart';
import 'package:optomstroy/features/notifications/data/repositories/notifications_repository_impl.dart';
import 'package:optomstroy/features/notifications/notifications_providers.dart';

final List<Override> notificationsBindings = <Override>[
  notificationsRepositoryProvider.overrideWith(
    (Ref ref) => NotificationsRepositoryImpl(
      ref.watch(dioProvider),
      // Запрос мог завершиться после закрытия корня (смена пользователя, выход) — тогда кэша нет.
      database: () => ref.mounted ? ref.read(appDatabaseProvider) : null,
      clock: ref.watch(clockProvider),
    ),
  ),
  notificationReadQueueProvider.overrideWith((Ref ref) {
    final OutboxQueue outbox = ref.watch(outboxQueueProvider);
    return OutboxNotificationReadQueue(
      // Запрос мог завершиться после закрытия корня (смена пользователя, выход) — тогда кэша нет.
      database: () => ref.mounted ? ref.read(appDatabaseProvider) : null,
      outbox: outbox,
      clock: ref.watch(clockProvider),
      // Сеть есть (запрос упал по другой причине) — попробовать отправить сразу; иначе — при восстановлении сети.
      onEnqueued: () {
        if (ref.read(connectivityWatcherProvider).current != OnlineStatus.offline) unawaited(outbox.flush());
      },
    );
  }),
];

/// Обработчики очереди фичи notifications (`notification.read`) для реестра `outboxHandlersProvider`.
List<OutboxActionHandler> notificationsOutboxHandlers(Ref ref) => <OutboxActionHandler>[
  NotificationReadOutboxHandler(() => ref.read(notificationsRepositoryProvider)),
];

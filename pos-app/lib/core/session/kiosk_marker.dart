// Признак планшета магазина на устройстве и доступ планшета к серверу (09 §8.9 п. 4, п. 7, п. 10; P-002 §8.2 п. 6–8;
// ADR-115 п. 12, п. 28; 06 §6.2 «Размещение режима «Планшет магазина»» п. (6); `visual/navigation.md` §4.1 G-0a, §4.3;
// 02 SCR-51.7; 13 TAB-2-10).
//
// Признак — ключи защищённого хранилища вне группы сессии (`SecureKey.kiosk`): `kiosk.tablet_id`, `kiosk.tablet_name`,
// `kiosk.user_id`, `kiosk.warehouse_id` (склад планшета — только для чтения кэша каталога на устройстве, на сервер не
// уходит; обновляется по `GET /me` → `tablet.warehouseId`, если администратор сменил склад в SCR-54). Пишется при
// подключении и подключении заново (SCR-54, FLOW-043.S6), переживает `401 SESSION_REVOKED`
// (срок сессии вышел — SCR-51 «Планшет нужно подключить заново», guard G-0a, закрепление остаётся) и удаляется только
// при `401 KIOSK_REVOKED` и аварийном выходе — вместе с хэшем, солью, счётчиком и паузой аварийного кода. По признаку
// холодный старт открывает `/kiosk` без SCR-08 и без сети: `userKind = kiosk` и `userId` (БД `pos_<user>.db` с кэшем
// каталога) берутся из признака (`SessionController.restore`). Персональных данных в признаке нет.
//
// Доступ планшета ([KioskAccess]) — ответы сервера, после которых SCR-51 показывает полноэкранное состояние без отзыва
// сессии: `403 KIOSK_NETWORK_DENIED` — «Планшет не в сети магазина»; `403 KIOSK_DISABLED` (`KIOSK_MODE=false`) и
// `403 FORBIDDEN` с причиной `kiosk_warehouse_unavailable` — «Сервис временно недоступен». «Не в сети магазина» и
// `KIOSK_DISABLED` снимает первый успешный ответ сервера планшету (в том числе `GET /settings/public` heartbeat раз в
// 4 мин); склад планшета недоступен — только успешный запрос по складу ([kioskWarehouseScopedPath]: каталог, поиск,
// остатки, корзина, сброс, заявка; heartbeat в этом состоянии шлёт один такой запрос), иначе витрина и полноэкранное
// состояние сменялись бы каждые 4 мин (02 SCR-51.7). Источник — `AuthInterceptor` через хуки `SessionController`.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

final Logger _log = Logger('session.kiosk');

/// Признак планшета магазина на этом устройстве.
@immutable
final class KioskMarker {
  const KioskMarker({required this.tabletId, this.tabletName, this.userId, this.warehouseId});

  /// `store_tablets.id`.
  final String tabletId;

  /// Имя планшета (не ПДн; в журналы не пишется).
  final String? tabletName;

  /// Технический пользователь `kind=kiosk` (`sub` access) — владелец БД `pos_<user>.db`.
  final String? userId;

  /// Склад планшета — только для чтения кэша каталога на устройстве (на сервер не отправляется).
  final String? warehouseId;

  /// Тот же признак со складом [value].
  KioskMarker withWarehouse(String? value) =>
      KioskMarker(tabletId: tabletId, tabletName: tabletName, userId: userId, warehouseId: value);

  @override
  bool operator ==(Object other) =>
      other is KioskMarker &&
      other.tabletId == tabletId &&
      other.tabletName == tabletName &&
      other.userId == userId &&
      other.warehouseId == warehouseId;

  @override
  int get hashCode => Object.hash(tabletId, tabletName, userId, warehouseId);

  @override
  String toString() => 'KioskMarker($tabletId)';
}

/// Чтение, запись и удаление признака планшета в защищённом хранилище.
final class KioskMarkerStore {
  const KioskMarkerStore(this._storage);

  final SecureStorage _storage;

  /// Признак или `null` (не планшет). Без `kiosk.tablet_id` признака нет.
  Future<KioskMarker?> read() async {
    final String? tabletId = await _storage.read(SecureKey.kioskTabletId);
    if (tabletId == null || tabletId.isEmpty) return null;
    return KioskMarker(
      tabletId: tabletId,
      tabletName: await _storage.read(SecureKey.kioskTabletName),
      userId: await _storage.read(SecureKey.kioskUserId),
      warehouseId: await _storage.read(SecureKey.kioskWarehouseId),
    );
  }

  /// Записать признак (подключение и подключение заново).
  Future<void> write(KioskMarker marker) async {
    await _storage.write(SecureKey.kioskTabletId, marker.tabletId);
    final String? name = marker.tabletName;
    if (name == null) {
      await _storage.delete(SecureKey.kioskTabletName);
    } else {
      await _storage.write(SecureKey.kioskTabletName, name);
    }
    final String? userId = marker.userId;
    if (userId == null) {
      await _storage.delete(SecureKey.kioskUserId);
    } else {
      await _storage.write(SecureKey.kioskUserId, userId);
    }
    final String? warehouseId = marker.warehouseId;
    if (warehouseId == null) {
      await _storage.delete(SecureKey.kioskWarehouseId);
    } else {
      await _storage.write(SecureKey.kioskWarehouseId, warehouseId);
    }
  }

  /// Удалить признак, хэш, соль, счётчик и паузу аварийного кода (`KIOSK_REVOKED`, аварийный выход). Сбой одного
  /// ключа не останавливает удаление остальных.
  Future<void> clear() async {
    for (final SecureKey key in SecureKey.kiosk) {
      try {
        await _storage.delete(key);
      } on Object catch (e) {
        _log.warning('признак планшета: ключ не удалён (${e.runtimeType})');
      }
    }
  }
}

/// Признак планшета в защищённом хранилище устройства.
final kioskMarkerStoreProvider = Provider<KioskMarkerStore>(
  (ref) => KioskMarkerStore(ref.watch(secureStorageProvider)),
);

/// Доступ сессии планшета к серверу (02 SCR-51.7).
enum KioskAccess {
  /// Обычная работа.
  allowed,

  /// `403 KIOSK_NETWORK_DENIED` — адрес вне `KIOSK_ALLOWED_CIDRS` (11 SEC-143): «Планшет не в сети магазина».
  networkDenied,

  /// `403 KIOSK_DISABLED` (`KIOSK_MODE=false`): «Сервис временно недоступен»; снимает любой успешный ответ.
  disabled,

  /// `403 FORBIDDEN` `kiosk_warehouse_unavailable` — склад планшета не задан или неактивен: «Сервис временно
  /// недоступен»; снимает только успешный запрос по складу ([kioskWarehouseScopedPath]).
  warehouseUnavailable;

  /// «Сервис временно недоступен» (02 SCR-51.7).
  bool get unavailable => this == disabled || this == warehouseUnavailable;

  /// Ответ `403` → доступ планшета; `null` — ответ к доступу планшета не относится (его обрабатывает экран).
  static KioskAccess? fromForbidden(String? code, String? reason) => switch (code) {
    'KIOSK_NETWORK_DENIED' => networkDenied,
    'KIOSK_DISABLED' => disabled,
    'FORBIDDEN' when reason == 'kiosk_warehouse_unavailable' => warehouseUnavailable,
    _ => null,
  };
}

/// Пути запросов планшета, которые сервер выполняет по складу планшета (каталог, поиск, остатки, корзина, сброс,
/// заявка): их успешный ответ снимает «Сервис временно недоступен» по складу. `/settings/public`, `/me`,
/// `/catalog/units`, `/catalog/warehouses` склад не проверяют.
const List<String> kioskWarehouseScopedPaths = <String>[
  '/catalog/categories',
  '/catalog/products',
  '/search/products',
  '/search/suggest',
  '/inventory',
  '/cart',
  '/kiosk/reset',
  '/kiosk/orders',
];

/// Запрос [path] (`RequestOptions.path`: относительно `/api/v1` или полный адрес) выполняется по складу планшета.
bool kioskWarehouseScopedPath(String path) {
  String p = Uri.tryParse(path)?.path ?? path;
  final int api = p.indexOf('/api/v1/');
  if (api >= 0) p = p.substring(api + '/api/v1'.length);
  if (!p.startsWith('/')) p = '/$p';
  for (final String prefix in kioskWarehouseScopedPaths) {
    if (p == prefix || p.startsWith('$prefix/')) return true;
  }
  return false;
}

/// Последний известный доступ планшета: отказ ставит `AuthInterceptor`, снимает успешный ответ
/// ([KioskAccessNotifier.succeeded]).
final kioskAccessProvider = NotifierProvider<KioskAccessNotifier, KioskAccess>(KioskAccessNotifier.new);

/// Хранилище [kioskAccessProvider].
final class KioskAccessNotifier extends Notifier<KioskAccess> {
  @override
  KioskAccess build() => KioskAccess.allowed;

  /// Сервер отказал планшету (`403`).
  void denied(KioskAccess access) {
    if (state != access) state = access;
  }

  /// Сервер ответил планшету успешно — витрина возвращается без перезапуска (AC-UI-51-010). «Склад планшета
  /// недоступен» снимает только запрос по складу ([warehouseScoped], 02 SCR-51.7).
  void succeeded({required bool warehouseScoped}) {
    if (state == KioskAccess.allowed) return;
    if (state == KioskAccess.warehouseUnavailable && !warehouseScoped) return;
    state = KioskAccess.allowed;
  }

  /// Новое подключение или конец режима планшета: отказов нет.
  void clear() {
    if (state != KioskAccess.allowed) state = KioskAccess.allowed;
  }
}

/// Склад планшета по признаку и `GET /me` (`tablet.warehouseId`) — память процесса; пишет `SessionController`.
final kioskTabletWarehouseProvider = NotifierProvider<KioskTabletWarehouse, String?>(KioskTabletWarehouse.new);

/// Состояние [kioskTabletWarehouseProvider].
final class KioskTabletWarehouse extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? warehouseId) {
    if (state != warehouseId) state = warehouseId;
  }
}

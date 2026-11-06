import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_mode.g.dart';

/// Режим оболочки (раскладка нижней панели / rail) — R0 §9, 06 §6.4.
///
/// Один граф маршрутов, разные наборы вкладок по режиму.
enum AppMode {
  /// Продавец (seller, senior_seller): Каталог · Избранное · Корзина · Клиенты · Профиль.
  seller,

  /// Кассир: Касса · Каталог · Клиенты · Транзакции · Профиль.
  cashier,

  /// Администратор: Каталог · Клиенты · Транзакции · Админ · Профиль.
  admin,

  /// Руководитель (owner; navigation.md §2.1, §14.7): Каталог (просмотр) · Клиенты · Транзакции · Отчёты · Профиль;
  /// главный экран — SCR-48 `/reports`; SCR-45/SCR-46 — ограниченный режим (ядро §21 п. 3), касса — просмотр.
  owner,

  /// Клиент-покупатель (R1, ядро v1.9 §24.2): Каталог `/home` · Избранное · Корзина · Мои заказы · Профиль.
  customer,

  /// Планшет магазина (технический пользователь `kind=kiosk`; P-002, ADR-115; navigation.md §2.1): вне оболочки —
  /// маршруты `/kiosk` (SCR-51), `/kiosk/checkout` (SCR-52), `/kiosk/done` (SCR-53), без вкладок, rail и drawer
  /// навигации; главный экран — `/kiosk`, другие пути закрывает guard G-15.
  kiosk,
}

/// Режим сотрудника магазина: служебная оболочка (HID-сканер, drawer навигации, шапка и горячие клавиши
/// сотрудника). Покупатель на своём телефоне и планшет магазина — не сотрудники (10 CUST-021, KIOSK-005).
bool isStaffMode(AppMode mode) => switch (mode) {
  AppMode.seller || AppMode.cashier || AppMode.admin || AppMode.owner => true,
  AppMode.customer || AppMode.kiosk => false,
};

/// Режим по типу пользователя и роли (D-15: одна активная роль).
///
/// [kind] — claim `kind` access-токена (core/session), [role] — главная роль профиля входа (фича auth).
/// `kiosk` (планшет магазина) проверяется первым — по виду субъекта, до правил ролей (06 §6.2 «Размещение режима…»
/// п. (1)): у технического пользователя нет ролей в `GET /me`, и режим продавца по умолчанию к нему не применяется.
/// `customer` — всегда режим клиента; `cashier` → касса; `admin` → администратор; `owner` → руководитель
/// (этап G); прочие сотрудники (`seller`, `senior_seller`) и неизвестная роль — продавец.
AppMode appModeFor({UserKind? kind, RoleCode? role}) {
  if (kind == UserKind.kiosk || role == RoleCode.kiosk) {
    return AppMode.kiosk;
  }
  if (kind == UserKind.customer || role == RoleCode.customer) {
    return AppMode.customer;
  }
  return switch (role) {
    RoleCode.cashier => AppMode.cashier,
    RoleCode.admin => AppMode.admin,
    RoleCode.owner => AppMode.owner,
    _ => AppMode.seller,
  };
}

/// Текущий режим оболочки: из сессии (`sessionControllerProvider.userKind`) и профиля входа
/// (`authSessionProvider.profile.primaryRole`, RM-D-007/RM-D-010).
@Riverpod(keepAlive: true)
AppMode appMode(Ref ref) => appModeFor(
  kind: ref.watch(sessionControllerProvider.select((s) => s.userKind)),
  role: ref.watch(authSessionProvider.select((s) => s.profile.primaryRole)),
);

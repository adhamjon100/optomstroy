// Порт данных SCR-54 «Планшеты магазина» (08 §4.18.11–§4.18.15, §4.4.6; 11 №77, №78). Реализация —
// `DioAdminTabletsRepository` (data), подключается `adminOverrides`. Подключение и подключение заново — с
// `Idempotency-Key` (повтор после обрыва тем же ключом: новые токены и новый аварийный код, ADR-115 п. 20) и
// step-up `kiosk.manage`; изменение — без step-up; отключение — со step-up, повтор безопасен. Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';

abstract interface class AdminTabletsRepository {
  /// `GET /admin/store-tablets` — все планшеты, порядок — по имени (`kiosk.read`).
  Future<Result<List<StoreTablet>>> list();

  /// `GET /catalog/warehouses` — справочник складов для формы и подписи склада в строке.
  Future<Result<List<TabletWarehouse>>> warehouses();

  /// `POST /admin/store-tablets {name, warehouseId}` + `Idempotency-Key` + `X-Step-Up-Token` → `201 KioskTokens`.
  Future<Result<KioskEnrollment>> enroll({
    required String name,
    required String warehouseId,
    required String idempotencyKey,
    String? stepUpToken,
  });

  /// `POST /admin/store-tablets/{id}/reconnect {}` + `Idempotency-Key` + `X-Step-Up-Token` → `200 KioskTokens`.
  Future<Result<KioskEnrollment>> reconnect(String id, {required String idempotencyKey, String? stepUpToken});

  /// `PATCH /admin/store-tablets/{id}` — имя и/или склад (хотя бы одно поле), без step-up.
  Future<Result<StoreTablet>> update(String id, {String? name, String? warehouseId});

  /// `POST /admin/store-tablets/{id}/revoke` + `X-Step-Up-Token` → `200 StoreTablet` (`status: revoked`).
  Future<Result<StoreTablet>> revoke(String id, {String? stepUpToken});
}

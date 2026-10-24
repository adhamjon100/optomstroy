// Порт дашборда кассира SCR-30 (08 §4.16 `GET /pos/dashboard`). Только онлайн; `admin`/`owner` — просмотр
// (`dashboard.cashier.read`), кассовые кнопки скрыты (D-15). Приём оплаты по заказу (SCR-38) — порт
// `PaymentsRepository` фичи orders; оплата долга без заказа (`POST /payments`, RM-G-013) в R1 выключена
// (`features.debtPaymentsFromPos=false`, Q-152) — порта нет. Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';

abstract interface class CashierRepository {
  /// `GET /pos/dashboard?date=&warehouseId=`; без [date] — сегодня (часовой пояс магазина — на сервере).
  Future<Result<PosDashboard>> dashboard({DateTime? date, String? warehouseId});
}

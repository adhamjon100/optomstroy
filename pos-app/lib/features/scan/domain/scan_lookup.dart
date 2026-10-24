// Поиск товара по отсканированному штрихкоду (SCR-17, HID в каталоге; 02 SCR-17.4/17.9, D-42, CAT-003).
//
// Порт [ScanBarcodeLookup] — узкий вид `SearchRepository` каталога (`GET /search/barcode/{value}`
// и офлайн-таблица drift `barcodes`, DATA-259). Фича scan не импортирует catalog: ребра
// `scan → catalog` нет в DAG 06 §6.1 (E_spec_questions EQ-FEF-07, EQ-SCAN-03); адаптер к
// `searchRepositoryProvider` подключает композиционный корень `app/di/overrides.dart`
// (код адаптера — features/scan/README.md). Чистый Dart.
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/qty.dart';

/// Режим экрана SCR-17 (`/scan?mode=`; 02 §4.1).
enum ScanMode {
  /// Найти товар и открыть карточку (по умолчанию).
  search('search'),

  /// Сразу добавить в корзину.
  add('add'),

  /// Распознать номер заказа для SCR-25 (товар не ищется).
  order('order'),

  /// Проверка камеры из SCR-42 (значение и формат возвращаются в SCR-42).
  test('test');

  const ScanMode(this.value);

  /// Значение query-параметра.
  final String value;

  /// Режим по query-параметру; неизвестный или пустой — [search].
  static ScanMode parse(String? value) {
    for (final m in values) {
      if (m.value == value) return m;
    }
    return search;
  }

  /// Режим ищет товар по штрихкоду.
  bool get looksUpProduct => this == search || this == add;
}

/// Найденный по штрихкоду товар (из `SearchBarcodeResult` или кэша `barcodes`).
final class ScanLookupResult {
  /// Создаёт результат.
  const ScanLookupResult({
    required this.productId,
    required this.productName,
    required this.variantId,
    this.sku,
    this.variantName,
    this.packagingId,
    this.packagingName,
    this.suggestedQuantity,
    this.unitLabel,
    this.ambiguous = false,
    this.fromCache = false,
    this.asOf,
  });

  /// `product.id`.
  final String productId;

  /// `product.name`.
  final String productName;

  /// Артикул товара/варианта.
  final String? sku;

  /// `variant.id`.
  final String variantId;

  /// Подпись варианта.
  final String? variantName;

  /// Упаковка, к которой привязан штрихкод (INV-017).
  final String? packagingId;

  /// Название упаковки.
  final String? packagingName;

  /// `suggestedQuantity` (шаг упаковки).
  final Qty? suggestedQuantity;

  /// Короткое название единицы для «+{qty} {unit}».
  final String? unitLabel;

  /// `warnings: ["ambiguous_barcode"]` — открыть SCR-14 с баннером проверки (`scan_ambiguous`).
  final bool ambiguous;

  /// Найден офлайн по кэшу (`scan_offline_note`).
  final bool fromCache;

  /// Время данных кэша.
  final DateTime? asOf;
}

/// Итог поиска по штрихкоду.
sealed class ScanLookupOutcome {
  const ScanLookupOutcome(this.value);

  /// Отсканированное значение.
  final String value;
}

/// Товар найден.
final class ScanFound extends ScanLookupOutcome {
  /// Создаёт итог.
  const ScanFound(super.value, this.result);

  /// Найденный товар.
  final ScanLookupResult result;
}

/// Штрихкод не найден (`404 NOT_FOUND` или нет в кэше офлайн).
final class ScanNotFound extends ScanLookupOutcome {
  /// Создаёт итог.
  const ScanNotFound(super.value, {this.offline = false});

  /// Поиск выполнен по кэшу (сервер недоступен).
  final bool offline;
}

/// Проверить не удалось (`scan_lookup_error` + «Повторить»; код сохраняется для повтора).
final class ScanLookupFailed extends ScanLookupOutcome {
  /// Создаёт итог.
  const ScanLookupFailed(super.value, this.failure);

  /// Причина.
  final Failure failure;
}

/// Порт поиска по штрихкоду.
abstract interface class ScanBarcodeLookup {
  /// `GET /search/barcode/{value}?warehouseId=`.
  Future<Result<ScanLookupResult>> lookupOnline(String value);

  /// Офлайн-поиск по drift `barcodes`; `null` — не найден.
  Future<Result<ScanLookupResult?>> lookupCached(String value);
}

/// Сценарий «штрихкод → товар»: сервер; при отсутствии сети — кэш (02 SCR-17.7 «Офлайн»).
final class LookupScannedBarcode {
  /// Создаёт сценарий над портом [lookup].
  const LookupScannedBarcode(this._lookup);

  final ScanBarcodeLookup _lookup;

  /// Ищет товар по [value].
  Future<ScanLookupOutcome> call(String value) async {
    final online = await _lookup.lookupOnline(value);
    switch (online) {
      case Success<ScanLookupResult>(value: final result):
        return ScanFound(value, result);
      case FailureResult<ScanLookupResult>(:final failure):
        if (_isNotFound(failure)) return ScanNotFound(value);
        if (failure is! NetworkFailure) return ScanLookupFailed(value, failure);
        final cached = await _lookup.lookupCached(value);
        return switch (cached) {
          Success<ScanLookupResult?>(value: final ScanLookupResult result) => ScanFound(value, result),
          Success<ScanLookupResult?>() => ScanNotFound(value, offline: true),
          FailureResult<ScanLookupResult?>() => ScanLookupFailed(value, failure),
        };
    }
  }

  static bool _isNotFound(Failure f) => f is ServerFailure && (f.code == 'NOT_FOUND' || f.status == 404);
}

/// Результат `pop(result)` экрана SCR-17 в режимах `order` и `test` (02 SCR-17.6).
final class ScannedCode {
  /// Создаёт результат.
  const ScannedCode(this.value, this.format);

  /// Значение.
  final String value;

  /// Формат (`EAN-13`, `EAN-8`, `Code128`, `UPC-A`, …).
  final String format;
}

/// Результат `pop(result)` в режимах `search`/`add`: найденный товар (источник открывает SCR-14).
final class ScannedProduct {
  /// Создаёт результат.
  const ScannedProduct(this.value, this.result, {this.added = false});

  /// Отсканированное значение.
  final String value;

  /// Найденный товар.
  final ScanLookupResult result;

  /// Позиция уже добавлена в корзину (`mode=add`).
  final bool added;
}

/// Квитанция добавления в корзину из сканера (для «Отменить», 5 с).
final class ScanAddReceipt {
  /// Создаёт квитанцию.
  const ScanAddReceipt({required this.quantityLabel, this.unitLabel, this.token});

  /// Добавленное количество (строка для «+{qty} {unit}»).
  final String quantityLabel;

  /// Единица.
  final String? unitLabel;

  /// Данные для отмены (прежнее количество строки, `rowVersion`) — непрозрачны для сканера.
  final Object? token;
}

/// Порт корзины для режима «сразу в корзину» (CART-002; реализация — фича cart, этап F).
abstract interface class ScanCartPort {
  /// +1 шаг варианта (или `suggestedQuantity` упаковки) с ключом идемпотентности на каждый скан.
  Future<Result<ScanAddReceipt>> addStep(ScanLookupResult result, {required String idempotencyKey});

  /// «Отменить»: вернуть прежнее количество строки.
  Future<Result<void>> undo(ScanAddReceipt receipt);
}

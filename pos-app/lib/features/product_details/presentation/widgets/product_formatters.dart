// Форматирование значений SCR-14…SCR-16 для UI (03 §16.4): разряды — узкий неразрывный пробел
// U+202F, десятичная запятая; количества — `Qty` (milli-units) без `double` (D-19). Деньги —
// `PriceText.format` дизайн-системы. Фото — URL `/images/{sha256}/{size}.webp` от базы API (D-30).
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';

/// Форматирование количеств и прочих значений карточки.
abstract final class ProductFormat {
  /// Разделитель разрядов (U+202F).
  static const String groupSeparator = ' ';

  /// «1 234,5»: дробная часть без хвостовых нулей; [group] — разряды.
  static String qty(Qty q, {bool group = true}) {
    final int milli = q.milli;
    final bool negative = milli < 0;
    final int abs = milli.abs();
    final String whole = (abs ~/ 1000).toString();
    String fraction = (abs % 1000).toString().padLeft(3, '0');
    while (fraction.isNotEmpty && fraction.endsWith('0')) {
      fraction = fraction.substring(0, fraction.length - 1);
    }
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < whole.length; i++) {
      if (group && i > 0 && (whole.length - i) % 3 == 0) b.write(groupSeparator);
      b.write(whole[i]);
    }
    final String sign = negative ? '−' : '';
    return fraction.isEmpty ? '$sign$b' : '$sign$b,$fraction';
  }

  /// Значение для дисплея нампада («12,5», без разрядов).
  static String numpadInput(Qty q) => qty(q, group: false);

  /// «09:41» (локальное время).
  static String time(DateTime at) {
    final DateTime l = at.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  /// Абсолютный URL фото размера [size]: URL сервера (`thumbUrl`/`cardUrl`/`fullUrl`), иначе
  /// `/images/{sha256}/{size}.webp` (RM-E-003); относительные — от origin [base]. Никогда не
  /// подставляет фото другого товара: ссылка строится только по `sha256` своего фото (INV-051).
  static String? imageUrl(ProductImageRef? ref, ProductImageSize size, Uri base) {
    if (ref == null || ref.sha256.isEmpty) return null;
    final String? given = switch (size) {
      ProductImageSize.thumb => ref.thumbUrl ?? ref.cardUrl,
      ProductImageSize.card => ref.cardUrl ?? ref.fullUrl,
      ProductImageSize.full => ref.fullUrl ?? ref.cardUrl,
    };
    final String path = given ?? ProductImage.pathFor(ref.sha256, size);
    final Uri? parsed = Uri.tryParse(path);
    if (parsed != null && parsed.hasScheme) return path;
    return base.replace(path: path.startsWith('/') ? path : '/$path', query: null).toString();
  }
}

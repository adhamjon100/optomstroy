// Форматы корзины для UI (03 §16.4): количество «2», «2,5»; проценты «5», «7,5»; время «HH:MM» (Asia/Bishkek).
// Деньги — только `PriceText.format` (целые тыйыны, D-19). Пути экранов — без импорта app/router (AP-01), формат
// как в routes.dart.
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;

abstract final class CartFormats {
  /// «1», «2,5», «12,125» — без хвостовых нулей.
  static String qty(Qty q) {
    final bool negative = q.milli < 0;
    final int abs = q.milli.abs();
    final int whole = abs ~/ 1000;
    final int frac = abs % 1000;
    final String body = frac == 0
        ? '$whole'
        : '$whole,${frac.toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '')}';
    return negative ? '−$body' : body;
  }

  /// Ввод нампада «12,5» (как [qty], без знака).
  static String qtyInput(Qty q) => qty(q);

  /// «5», «7,5», «12,25».
  static String percent(Percent p) {
    final int whole = p.hundredths ~/ 100;
    final int frac = p.hundredths % 100;
    if (frac == 0) return '$whole';
    return '$whole,${frac.toString().padLeft(2, '0').replaceFirst(RegExp(r'0+$'), '')}';
  }

  /// Разбор ввода скидки «7», «7,5», «7.25»: 0…100, не более 2 знаков; `null` — неверный ввод (MV-26).
  static Percent? parsePercent(String input) {
    final String s = input.trim().replaceAll(',', '.');
    if (s.isEmpty) return Percent.zero;
    final RegExpMatch? m = RegExp(r'^(\d{1,3})(?:\.(\d{0,2}))?$').firstMatch(s);
    if (m == null) return null;
    final int whole = int.parse(m.group(1)!);
    final String fracRaw = m.group(2) ?? '';
    final int frac = fracRaw.isEmpty ? 0 : int.parse(fracRaw.padRight(2, '0'));
    final int hundredths = whole * 100 + frac;
    if (hundredths > 10000) return null;
    return Percent(hundredths);
  }

  /// Значение процента из problem+json (`"5.00"` или число); `null` — не распознано.
  static Percent? percentOf(Object? raw) {
    if (raw is int) return Percent(raw * 100);
    if (raw is String) return parsePercent(raw);
    if (raw is num) return parsePercent(raw.toStringAsFixed(2)); // money-double: allow — процент из JSON-числа
    return null;
  }

  /// «09:41» — время магазина Asia/Bishkek (UTC+6, 02 §0.1); пояс машины не влияет.
  static String time(DateTime at) => DsBishkekTime.time(at);
}

/// Пути экранов, в которые ведёт корзина (02 §4.1; routes.dart).
abstract final class CartPaths {
  static const String cart = '/cart';
  static const String parked = '/cart/parked';
  static const String catalog = '/catalog';
  static const String home = '/home';

  /// SCR-21 `/checkout?cartId=`.
  static String checkout(String? cartId) =>
      cartId == null ? '/checkout' : '/checkout?cartId=${Uri.encodeQueryComponent(cartId)}';

  /// SCR-14 `/catalog/p/{productId}?variantId=`.
  static String product(String productId, {String? variantId}) =>
      '/catalog/p/${Uri.encodeComponent(productId)}'
      '${variantId == null ? '' : '?variantId=${Uri.encodeQueryComponent(variantId)}'}';

  /// SCR-24 `/orders/{id}`.
  static String order(String orderId) => '/orders/${Uri.encodeComponent(orderId)}';

  /// SCR-26 «Новый клиент» из корзины (результат — ID клиента).
  static const String newCustomer = '/customers/new?returnTo=cart';
}

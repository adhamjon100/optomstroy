// Предпочтения устройства SCR-21 (02 SCR-21.9) в drift `settings`, scope `device` (07 §11.2; FQ-CHK-12):
// `checkout.last_delivery_method`, `checkout.last_payment_method`, `checkout.print_options`.
//
// Порт `CheckoutPrefsStore` синхронный (контроллер SCR-21 читает его при открытии), поэтому значения читаются из
// БД один раз при создании (асинхронно) и держатся в памяти; запись — сразу в память и в фоне в БД. Способ оплаты
// `credit` не сохраняется (никогда не предвыбирается). ПДн здесь нет.
import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:optomstroy/core/database/daos/settings_dao.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';

final Logger _log = Logger('app.di.checkout_prefs');

/// `CheckoutPrefsStore` над `SettingsDao` (scope `device`).
final class DriftCheckoutPrefsStore implements CheckoutPrefsStore {
  /// Создаёт хранилище и начинает чтение из БД; [nowMs] — время записи.
  DriftCheckoutPrefsStore(this._dao, {required int Function() nowMs}) : _nowMs = nowMs {
    loaded = _load();
  }

  static const String deliveryKey = 'checkout.last_delivery_method';
  static const String paymentKey = 'checkout.last_payment_method';
  static const String printKey = 'checkout.print_options';

  final SettingsDao _dao;
  final int Function() _nowMs;
  CheckoutPrefs _prefs = const CheckoutPrefs();
  bool _written = false;

  /// Завершается после чтения из БД (для тестов).
  late final Future<void> loaded;

  @override
  CheckoutPrefs read() => _prefs;

  @override
  void write(CheckoutPrefs prefs) {
    _written = true;
    _prefs = prefs;
    unawaited(_save(prefs));
  }

  Future<void> _load() async {
    try {
      final String? delivery = await _dao.read(deliveryKey);
      final String? payment = await _dao.read(paymentKey);
      final String? print = await _dao.read(printKey);
      if (_written) return; // запись в этом сеансе новее
      final DeliveryMethod? d = _enum(DeliveryMethod.values, delivery, (DeliveryMethod v) => v.value);
      final PaymentMethod? p = _enum(PaymentMethod.values, payment, (PaymentMethod v) => v.value);
      final Map<String, Object?> po = print == null ? const <String, Object?>{} : _map(print);
      _prefs = CheckoutPrefs(
        deliveryMethod: d,
        paymentMethod: p == PaymentMethod.credit ? null : p,
        printInvoice: po['invoice'] is bool ? po['invoice']! as bool : true,
        printWaybill: po['waybill'] is bool ? po['waybill']! as bool : false,
        printReceipt: po['receipt'] is bool ? po['receipt']! as bool : false,
      );
    } on Object catch (e) {
      _log.warning('checkout prefs: чтение не удалось (${e.runtimeType})');
    }
  }

  Future<void> _save(CheckoutPrefs prefs) async {
    try {
      final int now = _nowMs();
      final DeliveryMethod? d = prefs.deliveryMethod;
      final PaymentMethod? p = prefs.paymentMethod == PaymentMethod.credit ? null : prefs.paymentMethod;
      if (d == null) {
        await _dao.remove(deliveryKey);
      } else {
        await _dao.write(deliveryKey, jsonEncode(d.value), scope: SettingScope.device, nowMs: now);
      }
      if (p == null) {
        await _dao.remove(paymentKey);
      } else {
        await _dao.write(paymentKey, jsonEncode(p.value), scope: SettingScope.device, nowMs: now);
      }
      await _dao.write(
        printKey,
        jsonEncode(<String, bool>{
          'invoice': prefs.printInvoice,
          'waybill': prefs.printWaybill,
          'receipt': prefs.printReceipt,
        }),
        scope: SettingScope.device,
        nowMs: now,
      );
    } on Object catch (e) {
      _log.warning('checkout prefs: запись не удалась (${e.runtimeType})');
    }
  }

  static T? _enum<T>(List<T> values, String? json, String Function(T) valueOf) {
    if (json == null) return null;
    final Object? raw;
    try {
      raw = jsonDecode(json);
    } on FormatException {
      return null;
    }
    for (final T v in values) {
      if (valueOf(v) == raw) return v;
    }
    return null;
  }

  static Map<String, Object?> _map(String json) {
    try {
      final Object? raw = jsonDecode(json);
      return raw is Map<String, Object?> ? raw : const <String, Object?>{};
    } on FormatException {
      return const <String, Object?>{};
    }
  }
}

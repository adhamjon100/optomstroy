// HID-скан в каталоге «без экрана» (D-42; 02 п. 2.2.11, SCR-10.4.A, SCR-17.4 «HID без экрана»).
//
// Оборачивает содержимое оболочки staff/customer (вставляет интегратор в `app/router/shells`):
// подключает `ScannerWedgeService` к клавиатуре и выполняет действие по скану:
// `GET /search/barcode/{value}` (офлайн — кэш `barcodes`) → по настройке `scan_adds_to_cart`
// добавить в корзину со снекбаром «Отсканировано {код} · {товар} +1 шт · Отменить» или открыть
// SCR-14; не найдено → SCR-11 `/catalog/search?q=` + снекбар `scan_not_found`; ошибка — снекбар
// `scan_lookup_error` с «Повторить». Каждый HID-скан — отдельное действие (Q-207: без подавления
// повторов), сканы обрабатываются по очереди.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/presentation/scan_navigation.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';
import 'package:uuid/uuid.dart';

/// Что делать, если штрихкод не найден.
enum HidNotFoundAction {
  /// Перейти в SCR-11 с запросом-кодом и показать снекбар (02 SCR-10.4.A).
  openSearch,

  /// Только снекбар `scan_not_found` (экран остаётся).
  snackbar,
}

/// Перехватчик экрана: вернуть `true`, если экран сам обработал событие (SCR-25 — номер заказа,
/// SCR-38 — `payment_scan_disabled`, SCR-11 — замена запроса).
typedef HidScanOverride = FutureOr<bool> Function(HidScanEvent event);

/// Область действия HID-сканера.
class HidScanScope extends ConsumerStatefulWidget {
  /// Создаёт область.
  const HidScanScope({
    super.key,
    required this.child,
    this.enabled = true,
    this.attachKeyboard = true,
    this.notFoundAction = HidNotFoundAction.openSearch,
    this.onEvent,
  });

  /// Содержимое.
  final Widget child;

  /// `false` — сканы не обрабатываются (экраны входа SCR-01…08).
  final bool enabled;

  /// Подключить сервис к `HardwareKeyboard`, если он ещё не подключён (и отключить при уходе).
  final bool attachKeyboard;

  /// Поведение «не найдено».
  final HidNotFoundAction notFoundAction;

  /// Перехват событий экраном.
  final HidScanOverride? onEvent;

  @override
  ConsumerState<HidScanScope> createState() => _HidScanScopeState();
}

class _HidScanScopeState extends ConsumerState<HidScanScope> {
  late final ScannerWedgeService _service;
  StreamSubscription<HidScanEvent>? _sub;
  bool _ownsAttachment = false;
  Future<void> _queue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _service = ref.read(scannerWedgeServiceProvider);
    if (widget.attachKeyboard && !_service.isAttached) {
      _service.attach();
      _ownsAttachment = true;
    }
    _sub = _service.events.listen((e) => _queue = _queue.then((_) => _onEvent(e)));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    if (_ownsAttachment) _service.detach();
    super.dispose();
  }

  Future<void> _onEvent(HidScanEvent event) async {
    if (!mounted || !widget.enabled) return;
    final override = widget.onEvent;
    if (override != null && await override(event)) return;
    if (!mounted) return;
    switch (event) {
      case HidScanned(:final value):
        await _lookup(value);
      case HidScanRejected():
        AppSnackbar.show(context, message: AppLocalizations.of(context).scan_invalid_code);
      case HidScanIgnored() || HidScanIncomplete():
        break;
    }
  }

  Future<void> _lookup(String value) async {
    final outcome = await ref.read(lookupScannedBarcodeProvider)(value);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    switch (outcome) {
      case ScanFound(:final result):
        final cart = ref.read(scanCartPortProvider);
        if (cart != null && ref.read(scanAddsToCartProvider)) {
          await _add(cart, value, result);
          return;
        }
        unawaited(GoRouter.of(context).push<void>(ScanLocations.product(result)));
        if (result.ambiguous) AppSnackbar.show(context, message: l10n.scan_ambiguous);
      case ScanNotFound():
        AppSnackbar.show(context, message: l10n.scan_not_found(value));
        if (widget.notFoundAction == HidNotFoundAction.openSearch) GoRouter.of(context).go(ScanLocations.search(value));
      case ScanLookupFailed():
        AppSnackbar.show(
          context,
          message: l10n.scan_lookup_error,
          variant: AppSnackbarVariant.error,
          actionLabel: l10n.ds_button_retry,
          onAction: () => _queue = _queue.then((_) => _lookup(value)),
        );
    }
  }

  Future<void> _add(ScanCartPort cart, String value, ScanLookupResult result) async {
    // Ключ идемпотентности — на каждый скан (02 SCR-17.11).
    final added = await cart.addStep(result, idempotencyKey: const Uuid().v4());
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    added.fold(
      (receipt) => AppSnackbar.show(
        context,
        message: l10n.scan_hid_result(result.productName, receipt.quantityLabel, receipt.unitLabel ?? '', value),
        variant: AppSnackbarVariant.success,
        actionLabel: l10n.ds_button_undo,
        onAction: () => unawaited(cart.undo(receipt)),
      ),
      (_) => AppSnackbar.show(context, message: l10n.scan_lookup_error, variant: AppSnackbarVariant.error),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

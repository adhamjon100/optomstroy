// Состояние SCR-35 «Скидки и условия» (02 SCR-35.4, SCR-35.7; 08 §4.11.6 `GET /customers/{id}/discounts`, §4.12.2
// `GET /discounts/rules?customerId=`; DISC-001…015, DEBT-008, D-23). Два запроса параллельно, каждый блок — со своим
// состоянием (Partial: успешный блок показывается, ошибочный — «Не удалось загрузить · Повторить»). Повторное
// обновление во время загрузки игнорируется; ответы прежнего клиента отбрасываются. Только чтение.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer_terms.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_card_controller.dart';

/// Состояние блока.
enum DiscountsBlockPhase { loading, ready, error }

/// Состояние SCR-35.
final class CustomerDiscountsState {
  const CustomerDiscountsState({
    this.offline = false,
    this.terms = DiscountsBlockPhase.loading,
    this.discounts,
    this.termsFailure,
    this.rules = DiscountsBlockPhase.loading,
    this.rulesInfo,
    this.rulesFailure,
    this.expanded = const <String>{},
  });

  /// Нет сети при открытии.
  final bool offline;

  /// `GET /customers/{id}/discounts`.
  final DiscountsBlockPhase terms;
  final CustomerDiscounts? discounts;
  final Failure? termsFailure;

  /// `GET /discounts/rules?customerId=`.
  final DiscountsBlockPhase rules;
  final DiscountRulesInfo? rulesInfo;
  final Failure? rulesFailure;

  /// Раскрытые правила (`rule.id`).
  final Set<String> expanded;

  bool get loading => terms == DiscountsBlockPhase.loading || rules == DiscountsBlockPhase.loading;

  /// `404` по клиенту — «Клиент не найден».
  bool get notFound => termsFailure != null && isNotFoundFailure(termsFailure!);

  /// `403` — «Нет доступа к разделу».
  bool get forbidden => termsFailure is PermissionFailure && rulesFailure is PermissionFailure;

  CustomerDiscountsState copyWith({
    DiscountsBlockPhase? terms,
    CustomerDiscounts? Function()? discounts,
    Failure? Function()? termsFailure,
    DiscountsBlockPhase? rules,
    DiscountRulesInfo? Function()? rulesInfo,
    Failure? Function()? rulesFailure,
    Set<String>? expanded,
  }) => CustomerDiscountsState(
    offline: offline,
    terms: terms ?? this.terms,
    discounts: discounts == null ? this.discounts : discounts(),
    termsFailure: termsFailure == null ? this.termsFailure : termsFailure(),
    rules: rules ?? this.rules,
    rulesInfo: rulesInfo == null ? this.rulesInfo : rulesInfo(),
    rulesFailure: rulesFailure == null ? this.rulesFailure : rulesFailure(),
    expanded: expanded ?? this.expanded,
  );
}

/// `customerDiscountsProvider(customerId)`.
final customerDiscountsProvider = NotifierProvider.autoDispose
    .family<CustomerDiscountsController, CustomerDiscountsState, String>(CustomerDiscountsController.new);

/// Логика SCR-35.
final class CustomerDiscountsController extends Notifier<CustomerDiscountsState> {
  /// Контроллер скидок клиента [customerId].
  CustomerDiscountsController(this.customerId);

  final String customerId;
  int _generation = 0;

  @override
  CustomerDiscountsState build() {
    unawaited(Future<void>.microtask(load));
    return const CustomerDiscountsState();
  }

  /// Оба запроса (открытие, pull-to-refresh, F5); во время загрузки — игнор.
  Future<void> load({bool force = false}) async {
    if (!ref.mounted) return;
    if (!force && _generation > 0 && state.loading) return;
    final int gen = ++_generation;
    if (!ref.read(customersOnlineProvider)) {
      state = const CustomerDiscountsState(offline: true);
      return;
    }
    state = CustomerDiscountsState(expanded: state.expanded);
    await Future.wait(<Future<void>>[_terms(gen), _rules(gen)]);
  }

  /// «Повторить» блока условий.
  Future<void> retryTerms() async {
    if (state.terms == DiscountsBlockPhase.loading) return;
    state = state.copyWith(terms: DiscountsBlockPhase.loading, termsFailure: () => null);
    await _terms(_generation);
  }

  /// «Повторить» блока правил.
  Future<void> retryRules() async {
    if (state.rules == DiscountsBlockPhase.loading) return;
    state = state.copyWith(rules: DiscountsBlockPhase.loading, rulesFailure: () => null);
    await _rules(_generation);
  }

  Future<void> _terms(int gen) async {
    Result<CustomerDiscounts> r;
    try {
      r = await ref.read(customerDirectoryRepositoryProvider).discounts(customerId);
    } on Object catch (e) {
      r = FailureResult<CustomerDiscounts>(UnknownFailure(cause: e));
    }
    if (!ref.mounted || gen != _generation) return;
    state = switch (r) {
      Success<CustomerDiscounts>(:final CustomerDiscounts value) => state.copyWith(
        terms: DiscountsBlockPhase.ready,
        discounts: () => value,
      ),
      FailureResult<CustomerDiscounts>(:final Failure failure) => state.copyWith(
        terms: DiscountsBlockPhase.error,
        termsFailure: () => failure,
      ),
    };
  }

  Future<void> _rules(int gen) async {
    // `customer`: ручная скидка и лимиты ролей клиенту недоступны (10 CUST-021) — `GET /discounts/rules` не нужен,
    // правила своей карточки приходят в `GET /customers/{id}/discounts` (RM-G-014).
    if (ref.read(customersViewerProvider).isCustomer) {
      state = state.copyWith(rules: DiscountsBlockPhase.ready);
      return;
    }
    Result<DiscountRulesInfo> r;
    try {
      r = await ref.read(customerDirectoryRepositoryProvider).discountRules(customerId: customerId);
    } on Object catch (e) {
      r = FailureResult<DiscountRulesInfo>(UnknownFailure(cause: e));
    }
    if (!ref.mounted || gen != _generation) return;
    state = switch (r) {
      Success<DiscountRulesInfo>(:final DiscountRulesInfo value) => state.copyWith(
        rules: DiscountsBlockPhase.ready,
        rulesInfo: () => value,
      ),
      FailureResult<DiscountRulesInfo>(:final Failure failure) => state.copyWith(
        rules: DiscountsBlockPhase.error,
        rulesFailure: () => failure,
      ),
    };
  }

  /// Раскрыть/свернуть правило.
  void toggle(String ruleId) {
    final Set<String> next = <String>{...state.expanded};
    if (!next.remove(ruleId)) next.add(ruleId);
    state = state.copyWith(expanded: next);
  }

  /// Подзаголовок: имя клиента из памяти сессии.
  String? customerName() => ref.read(customerNamesProvider).nameOf(customerId);
}

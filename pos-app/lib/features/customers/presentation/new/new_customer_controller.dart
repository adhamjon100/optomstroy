// Состояние и логика SCR-26 «Новый клиент» (02 SCR-26.4, SCR-26.7; RM-F-006; D-08, CUST-010…016).
//
// * Обязательная проверка дублей по телефону на 9-й цифре (`GET /search/customers?q=+996…`); для «Юр. лицо» / «ИП»
//   у `cashier`, `senior_seller`, `admin` — ещё и по ИНН на 14-й цифре; пока проверка не выполнена — создание
//   недоступно. `seller` проверку по ИНН получает от сервера (`409 CUSTOMER_DUPLICATE_SUSPECTED`).
// * `POST /customers` с `Idempotency-Key` (создаётся при нажатии; сетевой повтор — тем же ключом; «Всё равно
//   создать» — новый ключ: тело другое). ПДн формы — только память (07 §11.2), в drift не пишутся.
// * Маршрут API — 08 §4.11.2 (`POST /customers`); backend — этап G (RM-G-001, FQ-FND-07): до него сервер отвечает
//   `404`, экран показывает ошибку создания.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart' show OnlineStatus;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/session/session_controller.dart' show sessionControllerProvider;
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/new_customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:uuid/uuid.dart';

/// Роль для SCR-26 («Всё равно создать» — `customer.create.force`: `cashier`, `senior_seller`, `admin`; проверка по
/// ИНН до создания — роли с поиском по ИНН). По умолчанию `null` — возможности `seller` (кнопка скрыта; права
/// проверяет сервер). Корень подставляет роль из профиля входа.
final newCustomerViewerRoleProvider = Provider<RoleCode?>((ref) {
  final UserKind? kind = ref.watch(sessionControllerProvider.select((s) => s.userKind));
  return kind == UserKind.customer ? RoleCode.customer : null;
});

/// Есть ли сеть (создание и проверка дублей — только онлайн).
final newCustomerOnlineProvider = Provider<bool>(
  (ref) => ref.watch(onlineStatusProvider).value != OnlineStatus.offline,
);

/// Новый `Idempotency-Key`.
final newCustomerKeyFactoryProvider = Provider<String Function()>((ref) => const Uuid().v4);

/// Состояние проверки дублей.
enum DuplicateCheck { none, checking, clear, found, error }

/// Кандидат-дубль для показа (из поиска или из `409`).
final class DuplicateView {
  const DuplicateView({required this.id, required this.name, this.phone, this.byInn = false});

  final String id;
  final String name;
  final String? phone;

  /// Совпадение по ИНН.
  final bool byInn;
}

/// Ошибка поля формы.
enum NewCustomerFieldError { phoneInvalid, nameRequired, innInvalid, forceReasonRequired }

/// Поле формы.
enum NewCustomerField { phone, name, inn, forceReason }

/// Состояние SCR-26.
final class NewCustomerState {
  const NewCustomerState({
    this.role,
    this.phoneE164,
    this.name = '',
    this.type = CustomerType.individual,
    this.inn = '',
    this.address = '',
    this.comment = '',
    this.check = DuplicateCheck.none,
    this.innCheck = DuplicateCheck.none,
    this.candidates = const <DuplicateView>[],
    this.force = false,
    this.forceReason = '',
    this.forceForbidden = false,
    this.creating = false,
    this.showErrors = false,
    this.createFailure,
    this.createdId,
    this.onecCheckSkippedAt,
  });

  final RoleCode? role;
  final String? phoneE164;
  final String name;
  final CustomerType type;
  final String inn;
  final String address;
  final String comment;
  final DuplicateCheck check;
  final DuplicateCheck innCheck;
  final List<DuplicateView> candidates;

  /// «Всё равно создать» нажато — поле причины открыто.
  final bool force;
  final String forceReason;

  /// `403 FORBIDDEN` при `forceCreate` — кнопка скрывается.
  final bool forceForbidden;
  final bool creating;
  final bool showErrors;
  final Failure? createFailure;

  /// Созданный клиент — результат экрана.
  final String? createdId;

  /// Ответ `201` с `warnings[STALE_DATA]` (02 UI-26-016, 10 CUST-012): момент ответа; экран остаётся открытым с
  /// баннером «Проверка в 1С сейчас недоступна — возможен дубль», результат [createdId] — при закрытии экрана.
  final DateTime? onecCheckSkippedAt;

  /// Роль с правом «Всё равно создать».
  bool get canForce =>
      !forceForbidden && (role == RoleCode.cashier || role == RoleCode.seniorSeller || role == RoleCode.admin);

  /// Роль ищет по ИНН до создания.
  bool get checksInn => role == RoleCode.cashier || role == RoleCode.seniorSeller || role == RoleCode.admin;

  bool get innVisible => type != CustomerType.individual;

  NewCustomerState copyWith({
    String? phoneE164,
    bool clearPhone = false,
    String? name,
    CustomerType? type,
    String? inn,
    String? address,
    String? comment,
    DuplicateCheck? check,
    DuplicateCheck? innCheck,
    List<DuplicateView>? candidates,
    bool? force,
    String? forceReason,
    bool? forceForbidden,
    bool? creating,
    bool? showErrors,
    Failure? createFailure,
    bool clearFailure = false,
    String? createdId,
    DateTime? onecCheckSkippedAt,
  }) => NewCustomerState(
    role: role,
    phoneE164: clearPhone ? null : phoneE164 ?? this.phoneE164,
    name: name ?? this.name,
    type: type ?? this.type,
    inn: inn ?? this.inn,
    address: address ?? this.address,
    comment: comment ?? this.comment,
    check: check ?? this.check,
    innCheck: innCheck ?? this.innCheck,
    candidates: candidates ?? this.candidates,
    force: force ?? this.force,
    forceReason: forceReason ?? this.forceReason,
    forceForbidden: forceForbidden ?? this.forceForbidden,
    creating: creating ?? this.creating,
    showErrors: showErrors ?? this.showErrors,
    createFailure: clearFailure ? null : createFailure ?? this.createFailure,
    createdId: createdId ?? this.createdId,
    onecCheckSkippedAt: onecCheckSkippedAt ?? this.onecCheckSkippedAt,
  );
}

/// SCR-26.
final newCustomerControllerProvider = NotifierProvider.autoDispose<NewCustomerController, NewCustomerState>(
  NewCustomerController.new,
);

/// Логика SCR-26.
final class NewCustomerController extends Notifier<NewCustomerState> {
  int _checkSeq = 0;
  int _innSeq = 0;
  bool _disposed = false;

  /// Ключ текущей попытки создания (сетевой повтор — тем же ключом).
  String? _key;

  CustomersRepository get _repo => ref.read(customersRepositoryProvider);

  @override
  NewCustomerState build() {
    ref.onDispose(() => _disposed = true);
    return NewCustomerState(role: ref.read(newCustomerViewerRoleProvider));
  }

  void _set(NewCustomerState s) {
    if (!_disposed) state = s;
  }

  /// Ввод телефона: полный номер → проверка дублей; изменение номера сбрасывает результат.
  void setPhone(String? e164) {
    if (e164 == state.phoneE164) return;
    _key = null;
    _checkSeq++;
    _set(
      state.copyWith(
        phoneE164: e164,
        clearPhone: e164 == null,
        check: DuplicateCheck.none,
        candidates: const <DuplicateView>[],
        force: false,
        forceReason: '',
      ),
    );
    if (e164 != null) unawaited(checkPhone());
  }

  /// Проверка дублей по телефону («Повторить проверку» — тот же запрос; двойное нажатие — один запрос).
  Future<void> checkPhone() async {
    final String? phone = state.phoneE164;
    if (phone == null || state.check == DuplicateCheck.checking) return;
    final int seq = ++_checkSeq;
    _set(state.copyWith(check: DuplicateCheck.checking));
    final Result<PageResult<Customer>> r = await _repo.search(CustomerSearchQuery(q: phone, limit: 10));
    if (_disposed || seq != _checkSeq) return;
    switch (r) {
      case Success<PageResult<Customer>>(:final PageResult<Customer> value):
        final List<DuplicateView> found = <DuplicateView>[
          for (final Customer c in value.items)
            DuplicateView(id: c.id, name: c.title, phone: c.phoneMasked ?? _firstPhone(c)),
        ];
        _set(
          state.copyWith(
            check: found.isEmpty ? DuplicateCheck.clear : DuplicateCheck.found,
            candidates: found.isEmpty ? _innOnly() : found,
          ),
        );
      case FailureResult<PageResult<Customer>>():
        _set(state.copyWith(check: DuplicateCheck.error));
    }
  }

  List<DuplicateView> _innOnly() => <DuplicateView>[
    for (final DuplicateView d in state.candidates)
      if (d.byInn) d,
  ];

  static String? _firstPhone(Customer c) => c.phones.isEmpty ? null : c.phones.first.valueE164;

  /// ФИО / наименование.
  void setName(String v) => _set(state.copyWith(name: v));

  /// Тип клиента (ИНН — при «ИП» и «Юр. лицо»).
  void setType(CustomerType t) {
    _key = null;
    _set(state.copyWith(type: t, innCheck: DuplicateCheck.none));
    if (t != CustomerType.individual) unawaited(_maybeCheckInn());
  }

  /// ИНН (14 цифр) → проверка по ИНН у ролей с поиском по ИНН.
  void setInn(String v) {
    _key = null;
    _innSeq++;
    _set(state.copyWith(inn: v, innCheck: DuplicateCheck.none));
    unawaited(_maybeCheckInn());
  }

  Future<void> _maybeCheckInn() async {
    final String inn = state.inn.trim();
    if (!state.checksInn || !state.innVisible || !RegExp(r'^\d{14}$').hasMatch(inn)) return;
    final int seq = ++_innSeq;
    _set(state.copyWith(innCheck: DuplicateCheck.checking));
    final Result<PageResult<Customer>> r = await _repo.search(CustomerSearchQuery(q: inn, limit: 10));
    if (_disposed || seq != _innSeq) return;
    switch (r) {
      case Success<PageResult<Customer>>(:final PageResult<Customer> value):
        final List<DuplicateView> byInn = <DuplicateView>[
          for (final Customer c in value.items)
            DuplicateView(id: c.id, name: c.title, phone: c.phoneMasked ?? _firstPhone(c), byInn: true),
        ];
        _set(
          state.copyWith(
            innCheck: byInn.isEmpty ? DuplicateCheck.clear : DuplicateCheck.found,
            candidates: byInn.isEmpty
                ? state.candidates
                : <DuplicateView>[...state.candidates.where((DuplicateView d) => !d.byInn), ...byInn],
          ),
        );
      case FailureResult<PageResult<Customer>>():
        _set(state.copyWith(innCheck: DuplicateCheck.error));
    }
  }

  /// Адрес (≤ 300).
  void setAddress(String v) => _set(state.copyWith(address: v));

  /// Комментарий (≤ 500).
  void setComment(String v) => _set(state.copyWith(comment: v));

  /// «Всё равно создать» — открыть поле причины (повторное нажатие ничего не делает).
  void startForce() {
    if (!state.canForce || state.force) return;
    _key = null;
    _set(state.copyWith(force: true));
  }

  /// Причина создания при дубле (5…200).
  void setForceReason(String v) => _set(state.copyWith(forceReason: v));

  /// Ошибки полей.
  Map<NewCustomerField, NewCustomerFieldError> errors() {
    final NewCustomerState s = state;
    final Map<NewCustomerField, NewCustomerFieldError> e = <NewCustomerField, NewCustomerFieldError>{};
    if (s.phoneE164 == null) e[NewCustomerField.phone] = NewCustomerFieldError.phoneInvalid;
    final int n = s.name.trim().length;
    if (n < NewCustomerRequest.nameMin || n > NewCustomerRequest.nameMax) {
      e[NewCustomerField.name] = NewCustomerFieldError.nameRequired;
    }
    final String inn = s.inn.trim();
    if (s.type == CustomerType.legal && !RegExp(r'^\d{14}$').hasMatch(inn)) {
      e[NewCustomerField.inn] = NewCustomerFieldError.innInvalid;
    } else if (s.type == CustomerType.entrepreneur && inn.isNotEmpty && !RegExp(r'^\d{14}$').hasMatch(inn)) {
      e[NewCustomerField.inn] = NewCustomerFieldError.innInvalid;
    }
    if (s.force) {
      final int r = s.forceReason.trim().length;
      if (r < NewCustomerRequest.forceReasonMin || r > NewCustomerRequest.forceReasonMax) {
        e[NewCustomerField.forceReason] = NewCustomerFieldError.forceReasonRequired;
      }
    }
    return e;
  }

  /// «Создать клиента» доступна: сеть, проверка дублей выполнена (без совпадений — или «Всё равно создать» с
  /// причиной ≥ 5), нет идущего запроса.
  bool canCreate({required bool online}) {
    final NewCustomerState s = state;
    if (!online || s.creating || s.createdId != null) return false;
    if (s.check == DuplicateCheck.none || s.check == DuplicateCheck.checking || s.check == DuplicateCheck.error) {
      return false;
    }
    if (s.innCheck == DuplicateCheck.checking) return false;
    final bool duplicates = s.check == DuplicateCheck.found || s.innCheck == DuplicateCheck.found;
    if (duplicates && !s.force) return false;
    if (s.force && s.forceReason.trim().length < NewCustomerRequest.forceReasonMin) return false;
    return true;
  }

  /// Создать (`POST /customers`). Повторное нажатие во время запроса игнорируется.
  Future<void> create() async {
    if (state.creating || state.createdId != null) return;
    if (errors().isNotEmpty) {
      _set(state.copyWith(showErrors: true));
      return;
    }
    final NewCustomerState s = state;
    final String inn = s.inn.trim();
    final String address = s.address.trim();
    final String comment = s.comment.trim();
    final NewCustomerRequest request = NewCustomerRequest(
      name: s.name.trim(),
      customerType: s.type,
      phonesE164: <String>[s.phoneE164!],
      inn: s.innVisible && inn.isNotEmpty ? inn : null,
      address: address.isEmpty ? null : address,
      comment: comment.isEmpty ? null : comment,
      forceCreate: s.force,
      forceReason: s.force ? s.forceReason.trim() : null,
    );
    _key ??= ref.read(newCustomerKeyFactoryProvider)();
    _set(s.copyWith(creating: true, clearFailure: true));
    final Result<NewCustomerOutcome> r = await _repo.create(request, idempotencyKey: _key!);
    if (_disposed) return;
    switch (r) {
      case Success<NewCustomerOutcome>(value: final NewCustomerCreated created):
        _key = null;
        _set(
          state.copyWith(
            creating: false,
            createdId: created.customer.id,
            onecCheckSkippedAt: created.onecCheckSkipped ? ref.read(clockProvider).nowUtc() : null,
          ),
        );
      case Success<NewCustomerOutcome>(value: NewCustomerDuplicates(:final List<DuplicateCandidate> candidates)):
        _key = null;
        _set(
          state.copyWith(
            creating: false,
            check: DuplicateCheck.found,
            force: false,
            forceReason: '',
            candidates: <DuplicateView>[
              for (final DuplicateCandidate c in candidates)
                DuplicateView(id: c.id, name: c.displayName, phone: c.phoneMasked),
            ],
          ),
        );
      case FailureResult<NewCustomerOutcome>(:final Failure failure):
        // Сеть — ключ сохраняется: «Повторить» уходит тем же ключом и телом (SCR-26.4 п. 4).
        if (failure is! NetworkFailure) _key = null;
        if (failure is PermissionFailure && s.force) {
          _set(state.copyWith(creating: false, forceForbidden: true, force: false, createFailure: failure));
          return;
        }
        _set(state.copyWith(creating: false, createFailure: failure, showErrors: failure is ValidationFailure));
    }
  }

  /// Есть введённые данные (диалог UI-26-017).
  bool isDirty() =>
      state.phoneE164 != null ||
      state.name.isNotEmpty ||
      state.inn.isNotEmpty ||
      state.address.isNotEmpty ||
      state.comment.isNotEmpty;
}

// Состояние и действия SCR-46 (02 SCR-46.4, SCR-46.7): загрузка `GET /admin/settings` + `GET /admin/discount-limits`
// + зритель (`GET /me`: `owner` без `admin` — только просмотр, ядро §21 п. 3; зритель неизвестен — тоже только
// просмотр, fail-closed), черновики полей (только память — критичные настройки не кэшируются), сохранение секции:
// лимиты — `PUT /admin/discount-limits` (step-up `settings.discount_limits.update`), прочее — `PUT /admin/settings`
// частичным объектом + `rowVersion` (step-up `settings.app.update`). `409 VERSION_CONFLICT` — баннер UI-46-014,
// «Обновить» перечитывает сервер и накладывает локальные изменения поверх; `422` — ошибки под полями.
// stepUpToken живёт только в памяти `StepUpRunner`.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings_repository.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_form.dart';

/// Операции step-up SCR-46 (08 §4.18.5–§4.18.6).
abstract final class AdminSettingsOperations {
  static const String discountLimitsUpdate = 'settings.discount_limits.update';
  static const String appUpdate = 'settings.app.update';
}

final class AdminSettingsState {
  const AdminSettingsState({
    this.loading = true,
    this.failure,
    this.settings,
    this.limits,
    this.viewer,
    this.drafts = const <String, String>{},
    this.errors = const <String, SettingsFieldError>{},
    this.versionConflict = false,
    this.saving = false,
  });

  final bool loading;
  final Failure? failure;
  final AdminSettings? settings;
  final AdminDiscountLimits? limits;
  final AdminViewer? viewer;

  /// Черновики: ключ поля → строка ввода (`limit.<role>`, `override.<role>` — лимиты).
  final Map<String, String> drafts;

  /// Ошибки сервера по полям (`422`).
  final Map<String, SettingsFieldError> errors;
  final bool versionConflict;
  final bool saving;

  /// Изменять может только `admin` (зритель известен и не «только owner»).
  bool get canEdit => viewer != null && viewer!.isAdmin;

  /// Серверное значение поля.
  String serverValue(String key) {
    if (key.startsWith('limit.') || key.startsWith('override.')) {
      return limits == null ? '' : (LimitsDraft.initial(limits!)[key] ?? '');
    }
    final SettingsField? f = AdminSettingsCatalog.byKey(key);
    return f == null || settings == null ? '' : f.read(settings!.values);
  }

  /// Текущее значение поля (черновик или сервер).
  String value(String key) => drafts[key] ?? serverValue(key);

  /// Изменения секции (черновик ≠ сервер).
  List<SettingsChange> changes(AdminSettingsSection s) {
    final Iterable<String> keys = s == AdminSettingsSection.discountLimits
        ? drafts.keys.where((String k) => k.startsWith('limit.') || k.startsWith('override.'))
        : AdminSettingsCatalog.of(s).map((SettingsField f) => f.key).where(drafts.containsKey);
    return <SettingsChange>[
      for (final String k in keys)
        if (drafts[k]!.trim() != serverValue(k).trim())
          SettingsChange(key: k, before: serverValue(k), after: drafts[k]!.trim()),
    ];
  }

  bool dirty(AdminSettingsSection s) => changes(s).isNotEmpty;

  /// Ошибка ввода поля (клиент) или сервера.
  SettingsFieldError? errorOf(String key) {
    final String v = value(key);
    if (key.startsWith('limit.')) return LimitsDraft.parse(v) == null ? SettingsFieldError.limit : errors[key];
    final SettingsField? f = AdminSettingsCatalog.byKey(key);
    final SettingsFieldError? local = f?.validate(v);
    if (local != null) return local;
    if (key == 'recommendedAppVersion' &&
        SettingsVersions.recommendedBelowMin(value('minAppVersion'), value('recommendedAppVersion'))) {
      return SettingsFieldError.versionOrder;
    }
    return errors[key];
  }

  /// В секции есть ошибки ввода.
  bool invalid(AdminSettingsSection s) {
    final Iterable<String> keys = s == AdminSettingsSection.discountLimits
        ? <String>[for (final RoleCodeKey k in RoleCodeKey.all) k.limit]
        : AdminSettingsCatalog.of(s).map((SettingsField f) => f.key);
    return keys.any((String k) {
      final SettingsFieldError? e = errorOf(k);
      return e != null && e != SettingsFieldError.server;
    });
  }

  AdminSettingsState copyWith({
    bool? loading,
    Failure? failure,
    bool clearFailure = false,
    AdminSettings? settings,
    AdminDiscountLimits? limits,
    AdminViewer? viewer,
    Map<String, String>? drafts,
    Map<String, SettingsFieldError>? errors,
    bool? versionConflict,
    bool? saving,
  }) => AdminSettingsState(
    loading: loading ?? this.loading,
    failure: clearFailure ? null : (failure ?? this.failure),
    settings: settings ?? this.settings,
    limits: limits ?? this.limits,
    viewer: viewer ?? this.viewer,
    drafts: drafts ?? this.drafts,
    errors: errors ?? this.errors,
    versionConflict: versionConflict ?? this.versionConflict,
    saving: saving ?? this.saving,
  );
}

/// Ключи строк лимитов по ролям.
final class RoleCodeKey {
  const RoleCodeKey(this.limit, this.override);

  final String limit;
  final String override;

  static final List<RoleCodeKey> all = <RoleCodeKey>[
    for (final r in discountLimitRoles) RoleCodeKey(LimitsDraft.limitKey(r), LimitsDraft.overrideKey(r)),
  ];
}

final adminSettingsControllerProvider = NotifierProvider.autoDispose<AdminSettingsController, AdminSettingsState>(
  AdminSettingsController.new,
);

final class AdminSettingsController extends Notifier<AdminSettingsState> {
  late AdminSettingsRepository _repo;
  late StepUpRunner _runner;

  @override
  AdminSettingsState build() {
    _repo = ref.watch(adminSettingsRepositoryProvider);
    _runner = StepUpRunner(nowUtc: ref.watch(clockProvider).nowUtc);
    ref.onDispose(_runner.clear);
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(load());
    });
    return const AdminSettingsState();
  }

  /// Забыть токены step-up (сворачивание приложения).
  void forgetStepUp() => _runner.clear();

  /// Загрузка (и «Повторить»): настройки, лимиты, зритель — параллельно.
  Future<void> load({bool keepDrafts = false}) async {
    state = state.copyWith(loading: true, clearFailure: true);
    final List<Object> results = await Future.wait<Object>(<Future<Object>>[
      _repo.settings(),
      _repo.discountLimits(),
      ref.read(adminUsersRepositoryProvider).viewer(),
    ]);
    if (!ref.mounted) return;
    final Result<AdminSettings> s = results[0] as Result<AdminSettings>;
    final Result<AdminDiscountLimits> l = results[1] as Result<AdminDiscountLimits>;
    final Result<AdminViewer> v = results[2] as Result<AdminViewer>;
    final Failure? failure = s.failureOrNull ?? l.failureOrNull;
    if (failure != null) {
      state = state.copyWith(loading: false, failure: failure);
      return;
    }
    state = AdminSettingsState(
      loading: false,
      settings: s.valueOrNull,
      limits: l.valueOrNull,
      viewer: v.valueOrNull,
      drafts: keepDrafts ? state.drafts : const <String, String>{},
    );
  }

  /// Изменение поля.
  void edit(String key, String value) {
    if (!state.canEdit) return;
    final Map<String, SettingsFieldError> errors = Map<String, SettingsFieldError>.of(state.errors)..remove(key);
    state = state.copyWith(drafts: <String, String>{...state.drafts, key: value}, errors: errors);
  }

  /// «Отменить»: значения секции — к серверным, без запросов.
  void discard(AdminSettingsSection s) {
    final Set<String> keys = s == AdminSettingsSection.discountLimits
        ? <String>{
            for (final RoleCodeKey k in RoleCodeKey.all) ...<String>[k.limit, k.override],
          }
        : AdminSettingsCatalog.of(s).map((SettingsField f) => f.key).toSet();
    state = state.copyWith(
      drafts: Map<String, String>.of(state.drafts)..removeWhere((String k, String _) => keys.contains(k)),
      errors: Map<String, SettingsFieldError>.of(state.errors)
        ..removeWhere((String k, SettingsFieldError _) => keys.contains(k)),
    );
  }

  /// «Обновить» после `409`: перечитать сервер, локальные изменения сохраняются поверх.
  Future<void> refreshAfterConflict() async {
    await load(keepDrafts: true);
    if (ref.mounted) state = state.copyWith(versionConflict: false);
  }

  /// Сохранение секции [s] (после diff-подтверждения). `null` — нечего сохранять / нельзя.
  Future<AdminActionResult<void>?> save(
    AdminSettingsSection s, {
    required StepUpObtainer obtain,
    required String idempotencyKey,
  }) async {
    if (!state.canEdit || state.saving || state.invalid(s)) return null;
    final List<SettingsChange> changes = state.changes(s);
    if (changes.isEmpty) return null;
    state = state.copyWith(saving: true);
    final AdminActionResult<void> result;
    if (s == AdminSettingsSection.discountLimits) {
      final AdminDiscountLimits? limits = LimitsDraft.build(state.limits!, <String, String>{
        ...LimitsDraft.initial(state.limits!),
        ...state.drafts,
      });
      if (limits == null) {
        state = state.copyWith(saving: false);
        return null;
      }
      final AdminActionResult<AdminDiscountLimits> r = await _runner.run<AdminDiscountLimits>(
        operation: AdminSettingsOperations.discountLimitsUpdate,
        obtain: obtain,
        call: (String? token) => _repo.updateDiscountLimits(limits, idempotencyKey: idempotencyKey, stepUpToken: token),
      );
      if (!ref.mounted) return r;
      if (r case ActionDone<AdminDiscountLimits>(:final value)) {
        state = state.copyWith(limits: value);
        discard(s);
      }
      result = _forget(r);
    } else {
      final Map<String, String> changed = <String, String>{for (final SettingsChange c in changes) c.key: c.after};
      final AdminActionResult<AdminSettings> r = await _runner.run<AdminSettings>(
        operation: AdminSettingsOperations.appUpdate,
        obtain: obtain,
        call: (String? token) => _repo.updateSettings(
          SettingsValuesBuilder.build(changed),
          rowVersion: state.settings!.rowVersion,
          idempotencyKey: idempotencyKey,
          stepUpToken: token,
        ),
      );
      if (!ref.mounted) return r;
      if (r case ActionDone<AdminSettings>(:final value)) {
        state = state.copyWith(settings: value);
        discard(s);
      }
      result = _forget(r);
    }
    final Failure? failure = result.failureOrNull;
    state = state.copyWith(
      saving: false,
      versionConflict: failure is ConflictFailure && failure.kind == ConflictKind.versionConflict,
      errors: failure is ValidationFailure ? _fieldErrors(failure) : null,
    );
    return result;
  }

  static AdminActionResult<void> _forget<T>(AdminActionResult<T> r) => switch (r) {
    ActionDone<T>() => const ActionDone<void>(null),
    ActionFailed<T>(:final failure) => ActionFailed<void>(failure),
    ActionCancelled<T>() => const ActionCancelled<void>(),
  };

  /// `errors[].field` (`settings.lowStockThreshold`, `limits.seller`, …) → поля формы.
  static Map<String, SettingsFieldError> _fieldErrors(ValidationFailure f) {
    final Map<String, SettingsFieldError> out = <String, SettingsFieldError>{};
    for (final e in f.errors) {
      final String field = e.field;
      for (final SettingsField s in AdminSettingsCatalog.fields) {
        if (field == s.key || field.endsWith('.${s.key}')) out[s.key] = SettingsFieldError.server;
      }
      for (final RoleCodeKey k in RoleCodeKey.all) {
        final String role = k.limit.substring('limit.'.length);
        if (field.endsWith('limits.$role') || field.endsWith('limits[$role]')) out[k.limit] = SettingsFieldError.server;
      }
    }
    return out;
  }
}

// SCR-46 «Админ: лимиты скидок и настройки» (`/admin/settings?section=`; admin — изменение со step-up, owner —
// только просмотр (ядро §21 п. 3, 11 §4.4); 02 ч. E SCR-46; RM-G-008, RM-G-012, RM-G-014).
//
// Compact — секции-аккордеон, раскрытая секция — форма, внизу закреплены «Отменить · Сохранить» (видны при изменениях);
// medium/expanded — навигация секций 240 (точка `warning` у секции с несохранёнными изменениями) + форма ≤ 720.
// «Сохранить» → ConfirmDialog diff («ключ: было → стало») → `PUT` (лимиты — `PUT /admin/discount-limits`, прочее —
// `PUT /admin/settings` частичным объектом) → `403 STEP_UP_REQUIRED` → StepUpDialog → повтор тем же
// `Idempotency-Key`. Повышение минимальной версии — отдельное подтверждение (AC-UI-46-005). `409` — баннер
// конфликта с «Обновить» (слияние); `422` — ошибки под полями. Уход из секции/с экрана с изменениями — диалог
// «Сохранить изменения в секции …?». `CUSTOMER_SELF_SERVICE` — только чтение. Настройки не кэшируются: офлайн —
// EmptyState offlineNoCache. `Ctrl+S` — сохранить.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_nav_menu.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_controller.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_form.dart';
import 'package:optomstroy/features/admin/presentation/settings/widgets/admin_settings_sections.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_actions.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';

/// SCR-46. Лимиты скидок и настройки `/admin/settings?section=` (admin; owner — только просмотр, ядро §21 п. 3).
class AdminSettingsScreen extends ConsumerStatefulWidget {
  /// Экран SCR-46.
  const AdminSettingsScreen({this.section, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-46';

  /// Раздел настроек (`?section=`).
  final String? section;

  /// Ключи для тестов.
  static const Key screenKey = ValueKey<String>('scr-46');
  static const Key saveKey = ValueKey<String>('admin-settings-save');
  static const Key discardKey = ValueKey<String>('admin-settings-discard');
  static const Key readOnlyBannerKey = ValueKey<String>('admin-settings-readonly');
  static const Key conflictBannerKey = ValueKey<String>('admin-settings-conflict');
  static const Key historyLinkKey = ValueKey<String>('admin-settings-history');
  static const Key changedByKey = ValueKey<String>('admin-settings-changed-by');
  static Key sectionKey(AdminSettingsSection s) => ValueKey<String>('admin-settings-section-${s.value}');
  static Key dirtyDotKey(AdminSettingsSection s) => ValueKey<String>('admin-settings-dirty-${s.value}');

  /// Ширина навигации секций (medium/expanded).
  static const double navWidth = 240; // money-double: allow — геометрия UI (lp)

  /// Максимальная ширина формы.
  static const double formMaxWidth = 720; // money-double: allow — геометрия UI (lp)

  @override
  ConsumerState<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends ConsumerState<AdminSettingsScreen> {
  late AdminSettingsSection _section = AdminSettingsSection.parse(widget.section);
  bool _compactOpen = true;
  late final AppLifecycleListener _lifecycle;

  AdminSettingsController get _controller => ref.read(adminSettingsControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Сворачивание — step-up токены экрана забываются.
    _lifecycle = AppLifecycleListener(onHide: () => _controller.forgetStepUp());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ навигация

  void _syncUrl(AdminSettingsSection s) {
    GoRouter.maybeOf(
      context,
    )?.go(Uri(path: '/admin/settings', queryParameters: <String, String>{'section': s.value}).toString());
  }

  /// Уход из секции с несохранёнными изменениями: «Сохранить изменения в секции …?» → сохранить; отмена — остаться.
  Future<bool> _leaveSection() async {
    final AdminSettingsState st = ref.read(adminSettingsControllerProvider);
    if (!st.canEdit || !st.dirty(_section)) return true;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool save = await ConfirmDialog.show(
      context,
      title: l10n.admin_settings_unsaved_confirm(AdminSettingsTexts.section(l10n, _section)),
      message: _diffText(l10n, st.changes(_section)),
      confirmLabel: l10n.ds_button_apply,
    );
    if (!save || !mounted) return false;
    final bool saved = await _save(confirmDiff: false);
    return saved;
  }

  Future<void> _select(AdminSettingsSection s, {required bool compact}) async {
    if (s == _section) {
      if (compact) setState(() => _compactOpen = !_compactOpen);
      return;
    }
    if (!await _leaveSection() || !mounted) return;
    setState(() {
      _section = s;
      _compactOpen = true;
    });
    _syncUrl(s);
  }

  Future<void> _navigate(String location) async {
    if (!await _leaveSection() || !mounted) return;
    GoRouter.maybeOf(context)?.go(location);
  }

  String _historyLocation(AdminSettingsState st) {
    final DateTime now = ref.read(clockProvider).nowUtc();
    final DateTime? updated = _section == AdminSettingsSection.discountLimits ? st.limits?.updatedAt : null;
    final DateTime to = AdminFormat.startOfDayUtc(now).add(const Duration(days: 1));
    DateTime from = AdminFormat.startOfDayUtc((updated ?? now).subtract(const Duration(days: 30)));
    // Предел журнала — 366 дней (ядро §20.2 п. 15).
    final DateTime earliest = to.subtract(const Duration(days: 366));
    if (from.isBefore(earliest)) from = earliest;
    return Uri(
      path: '/admin/audit',
      queryParameters: <String, String>{
        'from': AdminFormat.iso(from),
        'to': AdminFormat.iso(to),
        'action': _section.auditPrefix,
      },
    ).toString();
  }

  // ------------------------------------------------------------------ сохранение

  String _diffText(AppLocalizations l10n, List<SettingsChange> changes) => changes
      .map((SettingsChange c) {
        if (c.key.startsWith('limit.') || c.key.startsWith('override.')) {
          final RoleCode? role = RoleCode.tryParse(c.key.substring(c.key.indexOf('.') + 1));
          final String name = role == null ? c.key : AdminLabels.role(l10n, role);
          return c.key.startsWith('limit.')
              ? '$name: ${c.before} % → ${c.after} %'
              : '$name · ${l10n.admin_settings_limit_override}: ${c.before} → ${c.after}';
        }
        return '${c.key}: ${c.before.isEmpty ? '—' : c.before} → ${c.after.isEmpty ? '—' : c.after}';
      })
      .join('\n');

  /// Сохранение текущей секции; `true` — сохранено.
  Future<bool> _save({bool confirmDiff = true}) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AdminSettingsState st = ref.read(adminSettingsControllerProvider);
    final AdminSettingsSection section = _section;
    if (!st.canEdit || st.saving || st.invalid(section)) return false;
    final List<SettingsChange> changes = st.changes(section);
    if (changes.isEmpty) return true;
    // Повышение минимальной версии — отдельное предупреждение (AC-UI-46-005).
    final SettingsChange? minChange = changes.where((SettingsChange c) => c.key == 'minAppVersion').firstOrNull;
    if (minChange != null && SettingsVersions.raised(minChange.before, minChange.after)) {
      final bool ok = await ConfirmDialog.show(
        context,
        title: l10n.admin_settings_diff_title,
        message: l10n.admin_settings_min_version_confirm(minChange.after),
        confirmLabel: l10n.ds_button_apply,
        variant: ConfirmDialogVariant.destructive,
        destructiveCta: true,
      );
      if (!ok || !mounted) return false;
    }
    if (!mounted) return false;
    final String key = newIdempotencyKey();
    final StepUpObtainer obtain = adminStepUpObtainer(context, ref);
    Future<AdminActionResult<void>> run(String? _) async =>
        await _controller.save(section, obtain: obtain, idempotencyKey: key) ?? const ActionCancelled<void>();
    final AdminActionResult<void>? result;
    if (confirmDiff) {
      result = await confirmAndRun<void>(
        context,
        title: l10n.admin_settings_diff_title,
        message: _diffText(l10n, changes),
        confirmLabel: l10n.ds_button_apply,
        variant: ConfirmDialogVariant.standard,
        run: run,
      );
    } else {
      result = await run(null);
    }
    if (!mounted || result == null) return false;
    switch (result) {
      case ActionDone<void>():
        showAdminSuccess(
          context,
          section == AdminSettingsSection.discountLimits ? l10n.admin_settings_limits_saved : l10n.admin_settings_saved,
        );
        return true;
      case ActionFailed<void>(:final failure):
        final bool handled =
            (failure is ConflictFailure && failure.kind == ConflictKind.versionConflict) ||
            failure is ValidationFailure;
        if (!handled) showAdminFailure(context, result);
        return false;
      case ActionCancelled<void>():
        return false;
    }
  }

  // ------------------------------------------------------------------ разметка

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AdminSettingsState st = ref.watch(adminSettingsControllerProvider);
    final WindowClass wc = context.windowClass;
    final bool compact = wc == WindowClass.compact;
    final bool anyDirty = st.canEdit && AdminSettingsSection.values.any(st.dirty);

    Widget body;
    if (st.loading && st.settings == null) {
      body = const _Skeleton();
    } else if (st.failure != null && st.settings == null) {
      final Failure f = st.failure!;
      body = f is NetworkFailure
          ? EmptyState(
              variant: EmptyStateVariant.offlineNoCache,
              title: l10n.ds_sync_offline,
              actionLabel: l10n.ds_button_retry,
              onAction: () => unawaited(_controller.load()),
            )
          : f is PermissionFailure
          ? EmptyState(variant: EmptyStateVariant.noPermission, title: l10n.error_forbidden)
          : ErrorState.fullScreen(
              title: l10n.admin_settings_title,
              message: AdminFailureText.of(l10n, f),
              onRetry: () => unawaited(_controller.load()),
              requestId: f.requestId,
            );
    } else if (compact) {
      body = _compactBody(context, l10n, st);
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: AdminSettingsScreen.navWidth,
            child: ListView(
              padding: EdgeInsets.symmetric(vertical: context.space.s2),
              children: <Widget>[
                for (final AdminSettingsSection s in AdminSettingsSection.values)
                  _navTile(context, l10n, st, s, compact: false),
              ],
            ),
          ),
          VerticalDivider(width: 1, thickness: 1, color: context.colors.border),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(context.space.s4),
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: AdminSettingsScreen.formMaxWidth),
                        child: AnimatedSwitcher(
                          duration: context.motion.of(context.motion.base),
                          child: KeyedSubtree(
                            key: ValueKey<AdminSettingsSection>(_section),
                            child: _form(context, l10n, st),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (st.canEdit && st.dirty(_section)) _footer(context, l10n, st),
              ],
            ),
          ),
        ],
      );
    }

    return PopScope<Object?>(
      canPop: !anyDirty,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        final NavigatorState nav = Navigator.of(context);
        if (await _leaveSection() && mounted && nav.canPop()) nav.pop();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => unawaited(_save()),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            key: AdminSettingsScreen.screenKey,
            appBar: AppBar(
              title: Text(l10n.admin_settings_title),
              actions: <Widget>[
                AdminNavMenu(current: AdminSection.settings, onNavigate: (String l) => unawaited(_navigate(l))),
                SizedBox(width: context.space.s2),
              ],
            ),
            body: body,
            bottomNavigationBar: compact && st.canEdit && st.dirty(_section) ? _footer(context, l10n, st) : null,
          ),
        ),
      ),
    );
  }

  Widget _navTile(
    BuildContext context,
    AppLocalizations l10n,
    AdminSettingsState st,
    AdminSettingsSection s, {
    required bool compact,
  }) {
    final bool dirty = st.canEdit && st.dirty(s);
    return AppListTile(
      key: AdminSettingsScreen.sectionKey(s),
      title: AdminSettingsTexts.section(l10n, s),
      leadingIcon: AdminSettingsTexts.icon(s),
      selected: !compact && s == _section,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (dirty)
            Container(
              key: AdminSettingsScreen.dirtyDotKey(s),
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: context.colors.warning, shape: BoxShape.circle),
            ),
          if (compact) ...<Widget>[
            SizedBox(width: context.space.s2),
            AnimatedRotation(
              turns: s == _section && _compactOpen ? 0.5 : 0,
              duration: context.motion.of(context.motion.base),
              child: Icon(Icons.expand_more_rounded, color: context.colors.textSecondary),
            ),
          ],
        ],
      ),
      onTap: () => unawaited(_select(s, compact: compact)),
    );
  }

  Widget _compactBody(BuildContext context, AppLocalizations l10n, AdminSettingsState st) => ListView(
    children: <Widget>[
      for (final AdminSettingsSection s in AdminSettingsSection.values) ...<Widget>[
        _navTile(context, l10n, st, s, compact: true),
        _MaybeAnimatedSize(
          child: s == _section && _compactOpen
              ? Padding(padding: EdgeInsets.all(context.space.s4), child: _form(context, l10n, st))
              : const SizedBox(width: double.infinity), // money-double: allow — геометрия UI (ширина lp)
        ),
        Divider(height: 1, thickness: 1, color: context.colors.border),
      ],
    ],
  );

  Widget _form(BuildContext context, AppLocalizations l10n, AdminSettingsState st) {
    final bool selfService = ref.watch(adminCustomerSelfServiceProvider);
    final AdminDiscountLimits? limits = st.limits;
    final bool showChangedBy =
        _section == AdminSettingsSection.discountLimits && limits?.updatedAt != null && limits?.updatedBy != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!st.canEdit)
          Padding(
            key: AdminSettingsScreen.readOnlyBannerKey,
            padding: EdgeInsets.only(bottom: context.space.s3),
            child: ErrorState.banner(message: l10n.admin_settings_readonly_banner, tone: ErrorStateTone.info),
          ),
        if (st.versionConflict)
          Padding(
            key: AdminSettingsScreen.conflictBannerKey,
            padding: EdgeInsets.only(bottom: context.space.s3),
            child: ErrorState.banner(
              message: l10n.admin_settings_conflict_banner,
              tone: ErrorStateTone.warning,
              onRetry: () => unawaited(_controller.refreshAfterConflict()),
            ),
          ),
        // На compact заголовок секции — строка аккордеона.
        if (context.windowClass != WindowClass.compact)
          Text(
            AdminSettingsTexts.section(l10n, _section),
            style: context.text.h3.copyWith(color: context.colors.textPrimary),
          ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: context.space.s2,
          children: <Widget>[
            if (showChangedBy)
              Text(
                l10n.admin_settings_changed_by(limits!.updatedBy!.displayName, AdminFormat.dateTime(limits.updatedAt!)),
                key: AdminSettingsScreen.changedByKey,
                style: context.text.caption.copyWith(color: context.colors.textSecondary),
              ),
            AppButton(
              key: AdminSettingsScreen.historyLinkKey,
              label: l10n.admin_settings_history_link,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
              icon: Icons.fact_check_outlined,
              onPressed: () => unawaited(_navigate(_historyLocation(st))),
            ),
            if (_section == AdminSettingsSection.discountLimits)
              AppButton(
                label: l10n.admin_users_title,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                icon: Icons.admin_panel_settings_outlined,
                onPressed: () => unawaited(_navigate('/admin/users?tab=users')),
              ),
            if (_section == AdminSettingsSection.sync)
              AppButton(
                label: l10n.sync_title,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                icon: Icons.sync_rounded,
                onPressed: () => unawaited(_navigate('/sync')),
              ),
          ],
        ),
        SizedBox(height: context.space.s3),
        AdminSettingsSectionBody(section: _section, state: st, selfService: selfService, onEdit: _controller.edit),
      ],
    );
  }

  Widget _footer(BuildContext context, AppLocalizations l10n, AdminSettingsState st) => Material(
    color: context.colors.surface,
    elevation: 2,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            AppButton(
              key: AdminSettingsScreen.discardKey,
              label: l10n.ds_button_undo,
              variant: AppButtonVariant.text,
              size: AppButtonSize.l,
              onPressed: st.saving ? null : () => _controller.discard(_section),
            ),
            SizedBox(width: context.space.s2),
            AppButton(
              key: AdminSettingsScreen.saveKey,
              label: l10n.ds_button_apply,
              size: AppButtonSize.l,
              loading: st.saving,
              onPressed: st.invalid(_section) || st.saving ? null : () => unawaited(_save()),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(context.space.s4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < 6; i++) ...<Widget>[const SkeletonBox(height: 52), SizedBox(height: context.space.s3)],
      ],
    ),
  );
}

/// `AnimatedSize` раскрытия (по образцу ANIM-016); при reduce-motion — без анимации (нулевая длительность
/// `AnimatedSize` перекомпоновывается внутри собственной компоновки).
class _MaybeAnimatedSize extends StatelessWidget {
  const _MaybeAnimatedSize({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Duration d = context.motion.of(context.motion.base);
    return d == Duration.zero ? child : AnimatedSize(duration: d, curve: context.motion.standard, child: child);
  }
}

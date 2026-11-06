// SCR-54 «Админ: планшеты магазина» (`/admin/tablets`; 02 ч. F SCR-54; FLOW-043; 08 §4.18.11–§4.18.15; 10 KIOSK-002…
// KIOSK-004, KIOSK-024, KIOSK-031, KIOSK-032; 11 №77, №78, SEC-133, SEC-140; ADR-115; 13 TAB-2-02). `admin` —
// подключение, подключение заново, изменение, отключение (`kiosk.manage`, step-up); `owner` — только список
// (`kiosk.read`).
//
// Сверху вниз: действия этого устройства (UI-54-002 «Сделать это устройство планшетом магазина», UI-54-003
// «Подключить заново этот планшет» — только при `features.storeTablet=true`; на compact — отказ UI-54-016 без
// запроса) → баннер отказа → список (UI-54-004: имя и склад, статус, последняя связь, закрепление, версия, срок
// подключения с напоминанием за 30 дней; expanded — строка с действиями, medium/compact — карточка с меню). Список,
// «Изменить» и «Отключить планшет» работают и при выключенном флаге (откат, ADR-115 п. 28). После `201`/`200
// KioskTokens` — аварийный код один раз (UI-54-014), «Готово» → данные администратора удаляются, устройство уходит в
// режим планшета (SCR-51, guard G-15). Данные списка не кэшируются; повторная загрузка — при возврате на экран и
// pull-to-refresh.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_nav_menu.dart';
import 'package:optomstroy/features/admin/presentation/tablets/admin_tablets_controller.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_edit_dialog.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_enroll_dialog.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_exit_code_dialog.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_actions.dart';

/// SCR-54. Планшеты магазина `/admin/tablets` (admin; owner — только просмотр).
class AdminTabletsScreen extends ConsumerStatefulWidget {
  const AdminTabletsScreen({super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-54';

  /// Ключи для тестов.
  static const Key screenKey = ValueKey<String>('scr-54');
  static const Key enrollKey = ValueKey<String>('tablets-enroll');
  static const Key reconnectKey = ValueKey<String>('tablets-reconnect');
  static const Key compactRefusedKey = ValueKey<String>('tablets-compact-refused');
  static const Key emptyKey = ValueKey<String>('tablets-empty');
  static const Key listKey = ValueKey<String>('tablets-list');
  static Key rowKey(String id) => ValueKey<String>('tablet-row-$id');
  static Key statusKey(String id) => ValueKey<String>('tablet-status-$id');
  static Key lastSeenKey(String id) => ValueKey<String>('tablet-last-seen-$id');
  static Key lockKey(String id) => ValueKey<String>('tablet-lock-$id');
  static Key versionKey(String id) => ValueKey<String>('tablet-version-$id');
  static Key updateKey(String id) => ValueKey<String>('tablet-update-$id');
  static Key expiryKey(String id) => ValueKey<String>('tablet-expiry-$id');
  static Key editKey(String id) => ValueKey<String>('tablet-edit-$id');
  static Key revokeKey(String id) => ValueKey<String>('tablet-revoke-$id');
  static Key menuKey(String id) => ValueKey<String>('tablet-menu-$id');

  /// Максимальная ширина контента (expanded / large).
  static const double contentMaxWidth = 1200; // money-double: allow — геометрия UI (lp)

  /// «22.10 09:41» — время последней связи по Asia/Bishkek (02 UI-54-007).
  static String lastSeen(DateTime utc) {
    final DateTime w = AdminFormat.wall(utc);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(w.day)}.${two(w.month)} ${two(w.hour)}:${two(w.minute)}';
  }

  @override
  ConsumerState<AdminTabletsScreen> createState() => _AdminTabletsScreenState();
}

class _AdminTabletsScreenState extends ConsumerState<AdminTabletsScreen> {
  late final AppLifecycleListener _lifecycle;
  bool _compactRefused = false;
  bool _connecting = false;

  AdminTabletsController get _controller => ref.read(adminTabletsControllerProvider.notifier);

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

  // ------------------------------------------------------------------ подключение этого устройства

  /// На compact режим планшета не включается (UI-54-016): подсказка, запроса нет.
  bool _refuseOnCompact() {
    if (DsBreakpoints.of(context) != WindowClass.compact) return false;
    setState(() => _compactRefused = true);
    return true;
  }

  Future<void> _enroll() async {
    if (_connecting || _refuseOnCompact()) return;
    final AdminKioskDevice? device = ref.read(adminKioskDeviceProvider);
    if (device == null) return;
    final AdminTabletsState st = ref.read(adminTabletsControllerProvider);
    final StepUpObtainer obtain = adminStepUpObtainer(context, ref);
    _connecting = true;
    try {
      final KioskEnrollment? enrollment = await TabletEnrollDialog.show(
        context,
        warehouses: st.warehouses,
        submit: (String name, String warehouseId, String key) => _guarded(
          device,
          () => _controller.enroll(name: name, warehouseId: warehouseId, idempotencyKey: key, obtain: obtain),
        ),
      );
      if (enrollment != null && mounted) await _showExitCode(device, enrollment);
    } finally {
      _connecting = false;
    }
  }

  Future<void> _reconnect() async {
    if (_connecting || _refuseOnCompact()) return;
    final AdminKioskDevice? device = ref.read(adminKioskDeviceProvider);
    if (device == null) return;
    final AdminTabletsState st = ref.read(adminTabletsControllerProvider);
    final List<StoreTablet> tablets = st.tablets ?? const <StoreTablet>[];
    if (tablets.isEmpty) return;
    final StepUpObtainer obtain = adminStepUpObtainer(context, ref);
    _connecting = true;
    try {
      final KioskEnrollment? enrollment = await TabletReconnectDialog.show(
        context,
        tablets: tablets,
        preselectedId: st.knownTabletId,
        warehouseName: st.warehouseName,
        submit: (String id, String key) =>
            _guarded(device, () => _controller.reconnect(id, idempotencyKey: key, obtain: obtain)),
      );
      if (enrollment != null && mounted) await _showExitCode(device, enrollment);
    } finally {
      _connecting = false;
    }
  }

  /// Запрос подключения: сессия администратора удерживается до «Готово» (сервер отзывает её в той же транзакции);
  /// не состоялось — отпускается.
  Future<AdminActionResult<KioskEnrollment>> _guarded(
    AdminKioskDevice device,
    Future<AdminActionResult<KioskEnrollment>> Function() call,
  ) async {
    device.holdSession();
    final AdminActionResult<KioskEnrollment> result = await call();
    if (result is! ActionDone<KioskEnrollment>) device.releaseSession();
    return result;
  }

  /// UI-54-014 → «Готово» → режим планшета (G-15 открывает SCR-51 и снимает этот экран вместе с диалогом).
  Future<void> _showExitCode(AdminKioskDevice device, KioskEnrollment enrollment) async {
    bool failed = false;
    await TabletExitCodeDialog.show(
      context,
      code: enrollment.exitCode,
      onDone: () async {
        try {
          await device.become(enrollment);
        } on Object {
          // Подключение на сервере состоялось, но устройство в режим планшета не перешло: сессия администратора
          // завершается как обычно (её отозвал сервер), запись подключается заново (02 SCR-54.11).
          failed = true;
          device.releaseSession();
        }
      },
    );
    if (failed && mounted) {
      AppSnackbar.show(
        context,
        message: AppLocalizations.of(context).error_internal,
        variant: AppSnackbarVariant.error,
      );
    }
  }

  // ------------------------------------------------------------------ изменение и отключение

  Future<void> _edit(StoreTablet t) async {
    final AdminTabletsState st = ref.read(adminTabletsControllerProvider);
    await TabletFormDialog.show<StoreTablet>(
      context,
      mode: TabletFormMode.edit,
      warehouses: st.warehouses,
      initialName: t.name,
      initialWarehouseId: t.warehouseId,
      submit: (String name, String warehouseId) async {
        final String? newName = name == t.name ? null : name;
        final String? newWarehouse = warehouseId == t.warehouseId ? null : warehouseId;
        if (newName == null && newWarehouse == null) return ActionDone<StoreTablet>(t);
        return _controller.update(t.id, name: newName, warehouseId: newWarehouse);
      },
    );
  }

  Future<void> _revoke(StoreTablet t) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final StepUpObtainer obtain = adminStepUpObtainer(context, ref);
    final AdminActionResult<StoreTablet>? result = await confirmAndRun<StoreTablet>(
      context,
      title: l10n.kiosk_admin_revoke,
      message: l10n.kiosk_admin_revoke_confirm(t.name),
      confirmLabel: l10n.kiosk_admin_revoke,
      variant: ConfirmDialogVariant.destructive,
      destructiveCta: true,
      run: (String? _) => _controller.revoke(t.id, obtain: obtain),
    );
    if (!mounted || result == null) return;
    if (result case ActionFailed<StoreTablet>(:final failure)) {
      AppSnackbar.show(context, message: TabletFailureText.of(l10n, failure), variant: AppSnackbarVariant.error);
    }
  }

  // ------------------------------------------------------------------ разметка

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AdminTabletsState st = ref.watch(adminTabletsControllerProvider);
    final WindowClass wc = context.windowClass;
    final bool compact = wc == WindowClass.compact;
    final bool wide = wc == WindowClass.expanded || wc == WindowClass.large;
    final bool flag = ref.watch(adminKioskEnabledProvider);
    final bool hasDevice = ref.watch(adminKioskDeviceProvider) != null;
    final String? recommended = ref.watch(adminRecommendedAppVersionProvider);
    final DateTime now = ref.read(clockProvider).nowUtc();
    // Подключение и «Подключить заново» — только `admin` при включённом флаге (AC-UI-54-003).
    final bool canConnect = st.canManage && flag && hasDevice;
    final List<StoreTablet>? tablets = st.tablets;

    Widget body;
    if (tablets == null && st.loading) {
      body = const _Skeleton();
    } else if (tablets == null) {
      final Failure f = st.failure ?? const UnknownFailure();
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
              title: l10n.kiosk_admin_title,
              message: TabletFailureText.of(l10n, f),
              onRetry: () => unawaited(_controller.load()),
              requestId: f.requestId,
            );
    } else {
      final EdgeInsets pad = EdgeInsets.all(compact ? context.space.s4 : context.space.s5);
      body = RefreshIndicator(
        onRefresh: _controller.load,
        child: ListView(
          key: AdminTabletsScreen.listKey,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: pad,
          children: <Widget>[
            Align(
              alignment: AlignmentDirectional.topStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: AdminTabletsScreen.contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (canConnect) _actions(context, l10n, compact: compact, hasTablets: tablets.isNotEmpty),
                    if (_compactRefused && compact)
                      Padding(
                        key: AdminTabletsScreen.compactRefusedKey,
                        padding: EdgeInsets.only(bottom: context.space.s3),
                        child: ErrorState.banner(
                          message: l10n.kiosk_admin_compact_refused,
                          tone: ErrorStateTone.info,
                          onClose: () => setState(() => _compactRefused = false),
                        ),
                      ),
                    if (tablets.isEmpty)
                      SizedBox(
                        key: AdminTabletsScreen.emptyKey,
                        height: 360,
                        child: EmptyState(
                          variant: EmptyStateVariant.categories,
                          title: l10n.kiosk_admin_empty,
                          illustration: Icon(
                            Icons.tablet_android_outlined,
                            size: compact ? 96 : 120,
                            color: context.colors.textTertiary,
                          ),
                          actionLabel: canConnect && !compact ? l10n.kiosk_admin_enroll : null,
                          onAction: canConnect && !compact ? () => unawaited(_enroll()) : null,
                        ),
                      )
                    else
                      for (final StoreTablet t in tablets)
                        _TabletRow(
                          key: AdminTabletsScreen.rowKey(t.id),
                          tablet: t,
                          warehouse: st.warehouseName(t.warehouseId),
                          wide: wide,
                          now: now,
                          recommendedVersion: recommended,
                          canManage: st.canManage,
                          onEdit: () => unawaited(_edit(t)),
                          onRevoke: () => unawaited(_revoke(t)),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      key: AdminTabletsScreen.screenKey,
      appBar: AppBar(
        title: Text(l10n.kiosk_admin_title),
        actions: <Widget>[
          const AdminNavMenu(current: AdminSection.tablets),
          SizedBox(width: context.space.s2),
        ],
      ),
      body: body,
    );
  }

  /// UI-54-002, UI-54-003: справа (compact — под заголовком во всю ширину).
  Widget _actions(BuildContext context, AppLocalizations l10n, {required bool compact, required bool hasTablets}) {
    final List<Widget> buttons = <Widget>[
      AppButton(
        key: AdminTabletsScreen.enrollKey,
        label: l10n.kiosk_admin_enroll,
        icon: Icons.tablet_android_rounded,
        expand: compact,
        fitLabel: compact,
        onPressed: () => unawaited(_enroll()),
      ),
      if (hasTablets)
        AppButton(
          key: AdminTabletsScreen.reconnectKey,
          label: l10n.kiosk_admin_reconnect,
          icon: Icons.sync_rounded,
          variant: AppButtonVariant.outlined,
          expand: compact,
          fitLabel: compact,
          onPressed: () => unawaited(_reconnect()),
        ),
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: context.space.s4),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final Widget b in buttons)
                  Padding(
                    padding: EdgeInsets.only(bottom: context.space.s2),
                    child: b,
                  ),
              ],
            )
          : Wrap(
              alignment: WrapAlignment.end,
              spacing: context.space.s2,
              runSpacing: context.space.s2,
              children: buttons,
            ),
    );
  }
}

/// Строка планшета UI-54-004…UI-54-011: expanded — одна линия с действиями; medium/compact — карточка, действия в меню.
class _TabletRow extends StatelessWidget {
  const _TabletRow({
    super.key,
    required this.tablet,
    required this.warehouse,
    required this.wide,
    required this.now,
    required this.recommendedVersion,
    required this.canManage,
    required this.onEdit,
    required this.onRevoke,
  });

  final StoreTablet tablet;
  final String? warehouse;
  final bool wide;
  final DateTime now;
  final String? recommendedVersion;
  final bool canManage;
  final VoidCallback onEdit;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final StoreTablet t = tablet;
    final TextStyle caption = context.text.caption.copyWith(
      color: context.colors.textSecondary,
      fontFeatures: DsTypography.numeric,
    );
    final bool soon = t.expiresSoon(now);
    final DateTime? expires = t.expiresAt;
    final Widget status = StatusChip(
      key: AdminTabletsScreen.statusKey(t.id),
      label: t.isActive ? l10n.kiosk_admin_status_active : l10n.kiosk_admin_status_revoked,
      variant: t.isActive ? StatusChipVariant.success : StatusChipVariant.neutral,
      dense: true,
    );
    final List<Widget> facts = <Widget>[
      Text(
        l10n.kiosk_admin_last_seen(t.lastSeenAt == null ? '—' : AdminTabletsScreen.lastSeen(t.lastSeenAt!)),
        key: AdminTabletsScreen.lastSeenKey(t.id),
        style: caption,
      ),
      TabletFlag(
        key: AdminTabletsScreen.lockKey(t.id),
        label: t.lockOn ? l10n.kiosk_admin_lock_on : l10n.kiosk_admin_lock_off,
        variant: t.lockOn ? StatusChipVariant.success : StatusChipVariant.warning,
        icon: t.lockOn ? Icons.lock_rounded : Icons.lock_open_rounded,
      ),
      Text(l10n.kiosk_admin_app_version(t.appVersion ?? '—'), key: AdminTabletsScreen.versionKey(t.id), style: caption),
      if (t.updateNeeded(recommendedVersion))
        TabletFlag(
          key: AdminTabletsScreen.updateKey(t.id),
          label: l10n.kiosk_admin_update_needed,
          variant: StatusChipVariant.warning,
          icon: Icons.system_update_rounded,
        ),
      if (expires == null)
        Text(l10n.kiosk_admin_expires('—'), key: AdminTabletsScreen.expiryKey(t.id), style: caption)
      else if (soon)
        TabletFlag(
          key: AdminTabletsScreen.expiryKey(t.id),
          label: l10n.kiosk_admin_expires_soon(AdminFormat.date(expires)),
          variant: StatusChipVariant.warning,
          icon: Icons.event_busy_rounded,
        )
      else
        Text(
          l10n.kiosk_admin_expires(AdminFormat.date(expires)),
          key: AdminTabletsScreen.expiryKey(t.id),
          style: caption,
        ),
    ];
    final Widget title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // expanded — одна строка в колонке 220; карточка medium/compact — до 2 строк (масштаб текста до 1.3×, A11Y-005).
        Text(
          t.name,
          maxLines: wide ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: context.text.body.copyWith(color: context.colors.textPrimary, fontWeight: FontWeight.w500),
        ),
        if (warehouse != null)
          Text(
            warehouse!,
            maxLines: wide ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.caption.copyWith(color: context.colors.textSecondary),
          ),
      ],
    );
    final Widget facts0 = Wrap(
      spacing: context.space.s3,
      runSpacing: context.space.s2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: facts,
    );
    final BoxDecoration frame = BoxDecoration(
      color: context.colors.surface,
      border: Border.all(color: context.colors.border),
      borderRadius: BorderRadius.all(context.radii.md),
    );
    if (wide) {
      return Container(
        constraints: const BoxConstraints(minHeight: 64),
        margin: EdgeInsets.only(bottom: context.space.s2),
        padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
        decoration: frame,
        child: Row(
          children: <Widget>[
            SizedBox(width: 220, child: title),
            SizedBox(width: context.space.s3),
            status,
            SizedBox(width: context.space.s3),
            Expanded(child: facts0),
            if (canManage) ...<Widget>[
              SizedBox(width: context.space.s2),
              AppButton(
                key: AdminTabletsScreen.editKey(t.id),
                label: l10n.kiosk_admin_edit,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                onPressed: onEdit,
              ),
              if (t.isActive)
                AppButton(
                  key: AdminTabletsScreen.revokeKey(t.id),
                  label: l10n.kiosk_admin_revoke,
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.s,
                  onPressed: onRevoke,
                ),
            ],
          ],
        ),
      );
    }
    return Container(
      margin: EdgeInsets.only(bottom: context.space.s2),
      padding: EdgeInsets.all(context.space.s3),
      decoration: frame,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: title),
              SizedBox(width: context.space.s2),
              status,
              if (canManage)
                PopupMenuButton<_RowAction>(
                  key: AdminTabletsScreen.menuKey(t.id),
                  tooltip: l10n.ds_button_more,
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (_RowAction a) => a == _RowAction.edit ? onEdit() : onRevoke(),
                  itemBuilder: (BuildContext _) => <PopupMenuEntry<_RowAction>>[
                    PopupMenuItem<_RowAction>(
                      key: AdminTabletsScreen.editKey(t.id),
                      value: _RowAction.edit,
                      child: Text(l10n.kiosk_admin_edit),
                    ),
                    if (t.isActive)
                      PopupMenuItem<_RowAction>(
                        key: AdminTabletsScreen.revokeKey(t.id),
                        value: _RowAction.revoke,
                        child: Text(l10n.kiosk_admin_revoke, style: TextStyle(color: context.colors.error)),
                      ),
                  ],
                ),
            ],
          ),
          SizedBox(height: context.space.s2),
          facts0,
        ],
      ),
    );
  }
}

enum _RowAction { edit, revoke }

/// Признак строки (закрепление, версия, срок подключения — UI-54-008…UI-54-010): вид `StatusChip` (контейнер и цвет
/// тона, иконка 16, `label`), но без предела ширины 160 и без предела строк — предупреждение «Подключение
/// заканчивается {date}. Подключите планшет заново» читается целиком и переносится на столько строк, сколько нужно
/// (compact при масштабе текста 1.3× и 1.5× — 03 A11Y-005; AC-UI-54-013).
class TabletFlag extends StatelessWidget {
  const TabletFlag({super.key, required this.label, required this.variant, required this.icon});

  final String label;
  final StatusChipVariant variant;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = StatusChip.colorsOf(context.colors, variant);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 20),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.all(context.radii.full)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 4),
            Flexible(
              child: Text(label, style: context.text.label.copyWith(color: fg, height: 1.2)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(context.space.s4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < 4; i++) ...<Widget>[const SkeletonBox(height: 64), SizedBox(height: context.space.s2)],
      ],
    ),
  );
}

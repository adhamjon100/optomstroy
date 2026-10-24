// SCR-41 «Профиль» (`/profile`, все роли; 02 ч. E SCR-41; RM-G-008). Режим сотрудника — G-fe-admin; режим клиента
// (блок «Клиент 1С» по статусу привязки, свои заказы) дополняет G-fe-customer-mode.
//
// Шапка (UI-41-001): инициалы, ФИО, телефон `+996 XXX XXX XXX`, роли, строка «Вход: {устройство} · {время}» из
// `Me.session` (без второго запроса). «Изменить данные» (UI-41-009) — лист (compact) / боковая панель 480.
// Данные профиля (UI-41-012) — «Не указано» для пустых. Пункты (UI-41-003): «Мои заказы», «Мои транзакции» (по праву
// `transactions.read.*`), «Уведомления», «Синхронизация» (staff), «Настройки», «Сменить номер телефона» (S!, мастер
// UI-41-010), «Заблокировать» (staff, overlay SCR-08 без запросов). Опасные: «Выйти» (подтверждение; офлайн —
// отложенный выход SessionController), «Выйти на всех устройствах» (destructive + S!; офлайн недоступно).
// ПДн (ФИО, телефон) — только память экрана (09 §8.5): ни drift, ни логи. Офлайн без данных — пункты меню и «Выйти».
// Режим клиента (RM-G-014): «Мои заказы» первым пунктом (UI-41-016), без «Мои транзакции», «Синхронизация» и
// «Заблокировать»; блок «Клиент 1С» (UI-41-011) — статус привязки и переходы SCR-06 / своя карточка SCR-32.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';
import 'package:optomstroy/features/profile/presentation/widgets/phone_change_flow.dart';
import 'package:optomstroy/features/profile/presentation/widgets/profile_edit_form.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';

/// SCR-41. Профиль `/profile` (все роли).
class ProfileScreen extends ConsumerStatefulWidget {
  /// Экран SCR-41.
  const ProfileScreen({super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-41';

  /// Ключи для тестов.
  static const Key screenKey = ValueKey<String>('scr-41');
  static const Key headerKey = ValueKey<String>('profile-header');
  static const Key editKey = ValueKey<String>('profile-edit');
  static const Key phoneChangeKey = ValueKey<String>('profile-phone-change');
  static const Key logoutKey = ValueKey<String>('profile-logout');
  static const Key logoutAllKey = ValueKey<String>('profile-logout-all');
  static const Key lockKey = ValueKey<String>('profile-lock');
  static const Key ordersKey = ValueKey<String>('profile-orders');
  static const Key transactionsKey = ValueKey<String>('profile-transactions');
  static const Key notificationsKey = ValueKey<String>('profile-notifications');
  static const Key syncKey = ValueKey<String>('profile-sync');
  static const Key settingsKey = ValueKey<String>('profile-settings');
  static const Key customerLinkKey = ValueKey<String>('profile-customer-link');
  static const Key customerLinkStatusKey = ValueKey<String>('profile-customer-link-status');

  /// Ширина карточки профиля (medium/expanded).
  static const double cardWidth = 560; // money-double: allow — геометрия UI (lp)

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  UserProfile? _me;
  Failure? _failure;
  bool _loading = true;
  bool _loggingOut = false;

  ProfileRepository get _repo => ref.read(profileRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    final Result<UserProfile> r = await _repo.me();
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (r) {
        case Success<UserProfile>(:final value):
          _me = value;
        case FailureResult<UserProfile>(:final failure):
          _failure = failure;
      }
    });
  }

  bool _isStaff(UserProfile? me) =>
      me == null ? ref.read(sessionControllerProvider).userKind != UserKind.customer : me.kind != UserKind.customer;

  // ------------------------------------------------------------------ действия

  Future<void> _edit(UserProfile me) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final int year = ref.read(clockProvider).nowUtc().year;
    final Widget form = ProfileEditForm(profile: me.profile, repository: _repo, nowYear: year);
    final ProfileData? saved;
    if (context.windowClass == WindowClass.compact) {
      saved = await AppBottomSheet.show<ProfileData>(
        context,
        title: l10n.profile_edit_button,
        body: form,
        variant: AppBottomSheetVariant.fullHeight,
      );
    } else {
      saved = await AppBottomSheet.showSide<ProfileData>(
        context,
        title: l10n.profile_edit_button,
        width: AppBottomSheet.sideExpanded,
        body: form,
      );
    }
    if (saved == null || !mounted) return;
    AppSnackbar.show(context, message: l10n.profile_saved, variant: AppSnackbarVariant.success);
    unawaited(_load());
  }

  Future<void> _changePhone(UserProfile me) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool go = await ConfirmDialog.show(
      context,
      title: l10n.profile_phone_change,
      message: l10n.profile_phone_change_confirm,
      confirmLabel: l10n.profile_phone_get_code,
    );
    if (!go || !mounted) return;
    final Widget flow = PhoneChangeFlow(repository: _repo, currentPhoneE164: me.profile.phoneE164);
    final PhoneChangeResult? done;
    if (context.windowClass == WindowClass.compact) {
      done = await AppBottomSheet.show<PhoneChangeResult>(
        context,
        title: l10n.profile_phone_change,
        body: flow,
        variant: AppBottomSheetVariant.fullHeight,
      );
    } else {
      done = await AppBottomSheet.showSide<PhoneChangeResult>(
        context,
        title: l10n.profile_phone_change,
        width: AppBottomSheet.sideExpanded,
        body: flow,
      );
    }
    if (done == null || !mounted) return;
    AppSnackbar.show(context, message: l10n.profile_phone_changed, variant: AppSnackbarVariant.success);
    unawaited(_load());
  }

  Future<void> _logout() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final SessionController session = ref.read(sessionControllerProvider.notifier);
    bool unsent = false;
    try {
      unsent = !(await session.pendingLocalChanges()).isEmpty;
    } on Object {
      // Сбой чтения локальной БД не блокирует выход.
    }
    if (!mounted) return;
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.profile_logout_confirm,
      message: unsent ? l10n.profile_logout_unsynced_cart : l10n.pending_logout_body,
      confirmLabel: unsent ? l10n.profile_logout_anyway : l10n.profile_logout,
    );
    if (!ok || !mounted) return;
    setState(() => _loggingOut = true);
    await session.logout();
    if (mounted) setState(() => _loggingOut = false);
  }

  Future<void> _logoutAll() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.profile_logout_all,
      message: l10n.profile_logout_all_confirm,
      confirmLabel: l10n.profile_logout_all,
      variant: ConfirmDialogVariant.destructive,
      destructiveCta: true,
    );
    if (!ok || !mounted) return;
    setState(() => _loggingOut = true);
    final error = await ref.read(sessionControllerProvider.notifier).logoutAll();
    if (!mounted) return;
    setState(() => _loggingOut = false);
    if (error != null) {
      AppSnackbar.show(context, message: l10n.error_internal, variant: AppSnackbarVariant.error);
    }
  }

  void _go(String location, {bool push = false}) {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null) return;
    if (push) {
      unawaited(router.push<void>(location));
    } else {
      router.go(location);
    }
  }

  // ------------------------------------------------------------------ разметка

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final UserProfile? me = _me;
    final bool staff = _isStaff(me);
    final bool online = ref.watch(onlineStatusProvider).value != OnlineStatus.offline;
    final bool compact = context.windowClass == WindowClass.compact;

    final List<Widget> children = <Widget>[
      if (_loading && me == null)
        const _HeaderSkeleton()
      else if (me != null)
        _header(context, l10n, me)
      else if (_failure != null)
        _failure is NetworkFailure
            ? ErrorState.banner(
                message: l10n.ds_sync_offline,
                tone: ErrorStateTone.warning,
                onRetry: () => unawaited(_load()),
              )
            : ErrorState.inline(
                message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(_failure!)),
                onRetry: () => unawaited(_load()),
              ),
      if (me != null) ...<Widget>[
        SizedBox(height: context.space.s3),
        Align(
          alignment: compact ? Alignment.center : AlignmentDirectional.centerStart,
          child: AppButton(
            key: ProfileScreen.editKey,
            label: l10n.profile_edit_button,
            variant: AppButtonVariant.outlined,
            size: AppButtonSize.s,
            onPressed: online ? () => unawaited(_edit(me)) : null,
          ),
        ),
        SizedBox(height: context.space.s3),
        AppListTile(
          title: l10n.profile_birthyear_label,
          subtitle: me.profile.birthYear?.toString() ?? l10n.profile_value_not_set,
        ),
        AppListTile(
          title: l10n.profile_activity_label,
          subtitle: (me.profile.activitySphere ?? '').isEmpty ? l10n.profile_value_not_set : me.profile.activitySphere,
        ),
        if (me.kind == UserKind.customer &&
            me.customerLink != null &&
            me.customerLink!.status != null &&
            me.customerLink!.status != ProfileLinkStatus.none)
          _customerLinkTile(l10n, me.customerLink!),
      ],
      SizedBox(height: context.space.s3),
      Divider(height: 1, color: context.colors.border),
      AppListTile(
        key: ProfileScreen.ordersKey,
        title: l10n.profile_menu_my_orders,
        leadingIcon: Icons.receipt_outlined,
        showChevron: true,
        onTap: () => _go('/orders?mine=1'),
      ),
      if (staff &&
          (me == null || me.permissions.isEmpty || me.permissions.any((String p) => p.startsWith('transactions.read'))))
        AppListTile(
          key: ProfileScreen.transactionsKey,
          title: l10n.profile_menu_my_transactions,
          leadingIcon: Icons.swap_horiz_rounded,
          showChevron: true,
          onTap: () => _go('/transactions?mine=1'),
        ),
      AppListTile(
        key: ProfileScreen.notificationsKey,
        title: l10n.profile_menu_notifications,
        leadingIcon: Icons.notifications_outlined,
        showChevron: true,
        onTap: () => _go('/notifications', push: true),
      ),
      if (staff)
        AppListTile(
          key: ProfileScreen.syncKey,
          title: l10n.profile_menu_sync,
          leadingIcon: Icons.sync_rounded,
          showChevron: true,
          onTap: () => _go('/sync', push: true),
        ),
      AppListTile(
        key: ProfileScreen.settingsKey,
        title: l10n.profile_menu_settings,
        leadingIcon: Icons.settings_outlined,
        showChevron: true,
        onTap: () => _go('/settings', push: true),
      ),
      if (me != null)
        AppListTile(
          key: ProfileScreen.phoneChangeKey,
          title: l10n.profile_phone_change,
          subtitle: online ? null : l10n.profile_offline_action_disabled,
          leadingIcon: Icons.phone_iphone_rounded,
          showChevron: true,
          enabled: online,
          onTap: online ? () => unawaited(_changePhone(me)) : null,
        ),
      if (staff)
        AppListTile(
          key: ProfileScreen.lockKey,
          title: l10n.profile_menu_lock,
          leadingIcon: Icons.lock_outline_rounded,
          onTap: () => ref.read(sessionControllerProvider.notifier).lock(SessionLockReason.manual),
        ),
      Divider(height: 1, color: context.colors.border),
      AppListTile(
        key: ProfileScreen.logoutKey,
        title: l10n.profile_logout,
        leading: Icon(Icons.logout_rounded, color: context.colors.error),
        enabled: !_loggingOut,
        onTap: _loggingOut ? null : () => unawaited(_logout()),
      ),
      AppListTile(
        key: ProfileScreen.logoutAllKey,
        title: l10n.profile_logout_all,
        subtitle: online ? null : l10n.profile_offline_action_disabled,
        leading: Icon(Icons.logout_rounded, color: context.colors.error),
        enabled: online && !_loggingOut,
        onTap: online && !_loggingOut ? () => unawaited(_logoutAll()) : null,
      ),
    ];

    return Scaffold(
      key: ProfileScreen.screenKey,
      appBar: AppBar(title: Text(l10n.profile_title)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(compact ? context.space.s4 : context.space.s6),
          children: <Widget>[
            Align(
              alignment: compact ? Alignment.topCenter : AlignmentDirectional.topStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: ProfileScreen.cardWidth),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// UI-41-011 «Клиент 1С» (только `customer`; 02 AC-UI-41-010): `proposed` — маскированное наименование и переход
  /// на SCR-06; `conflict` — «Ожидает подтверждения администратором»; `confirmed` — полное наименование и своя
  /// карточка SCR-32; долг и история до подтверждения не показываются (10 CUST-025).
  Widget _customerLinkTile(AppLocalizations l10n, ProfileCustomerLink link) {
    final ProfileLinkStatus status = link.status!;
    final String? subtitle = switch (status) {
      ProfileLinkStatus.confirmed => link.displayName ?? link.displayNameMasked,
      ProfileLinkStatus.conflict => l10n.profile_customer_link_waiting,
      _ => link.displayNameMasked ?? l10n.profile_customer_link_waiting,
    };
    final VoidCallback? onTap = switch (status) {
      ProfileLinkStatus.confirmed when link.isConfirmed => () => _go(
        '/customers/${Uri.encodeComponent(link.customerId!)}',
      ),
      ProfileLinkStatus.proposed => () => _go('/register/customer-link', push: true),
      _ => null,
    };
    return AppListTile(
      key: ProfileScreen.customerLinkKey,
      title: l10n.profile_customer_link_title,
      subtitle: subtitle,
      showChevron: onTap != null,
      trailing: StatusChip(
        key: ProfileScreen.customerLinkStatusKey,
        label: _linkStatus(l10n, status),
        variant: StatusChipMapping.variantOf('link', status.value) ?? StatusChipVariant.neutral,
        dense: true,
      ),
      onTap: onTap,
    );
  }

  static String _linkStatus(AppLocalizations l10n, ProfileLinkStatus s) => switch (s) {
    ProfileLinkStatus.proposed => l10n.status_link_proposed,
    ProfileLinkStatus.confirmed => l10n.status_link_confirmed,
    ProfileLinkStatus.rejected => l10n.status_link_rejected,
    ProfileLinkStatus.conflict => l10n.status_link_conflict,
    ProfileLinkStatus.none => '',
  };

  Widget _header(BuildContext context, AppLocalizations l10n, UserProfile me) {
    final bool compact = context.windowClass == WindowClass.compact;
    final String name = me.profile.fullName ?? '';
    final String initials = name
        .split(RegExp(r'\s+'))
        .where((String p) => p.isNotEmpty)
        .take(2)
        .map((String p) => p.characters.first.toUpperCase())
        .join();
    final ProfileSession? s = me.session;
    final String? login = s?.deviceName == null || s?.createdAt == null
        ? null
        : l10n.profile_login_device(s!.deviceName!, _stamp(s.createdAt!));
    return Container(
      key: ProfileScreen.headerKey,
      padding: EdgeInsets.all(context.space.s6),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.all(context.radii.lg),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: context.colors.primaryContainer, shape: BoxShape.circle),
            child: Text(initials, style: context.text.h3.copyWith(color: context.colors.primaryText)),
          ),
          SizedBox(height: context.space.s3),
          Text(
            name,
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: context.text.h2.copyWith(color: context.colors.textPrimary),
          ),
          if (me.profile.phoneE164 != null)
            Text(
              DsPhoneFormat.display(me.profile.phoneE164!),
              style: context.text.body.copyWith(
                color: context.colors.textSecondary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          SizedBox(height: context.space.s2),
          Wrap(
            spacing: context.space.s1,
            runSpacing: context.space.s1,
            alignment: compact ? WrapAlignment.center : WrapAlignment.start,
            children: <Widget>[
              for (final RoleCode r in me.roles)
                StatusChip(label: _role(l10n, r), variant: StatusChipVariant.neutral, dense: true),
            ],
          ),
          if (login != null) ...<Widget>[
            SizedBox(height: context.space.s2),
            Text(login, style: context.text.caption.copyWith(color: context.colors.textSecondary)),
          ],
        ],
      ),
    );
  }

  String _stamp(DateTime utc) {
    final DateTime w = utc.toUtc().add(const Duration(hours: 6));
    final DateTime n = ref.read(clockProvider).nowUtc().add(const Duration(hours: 6));
    String p(int v) => v.toString().padLeft(2, '0');
    final String time = '${p(w.hour)}:${p(w.minute)}';
    return w.year == n.year && w.month == n.month && w.day == n.day
        ? time
        : '${p(w.day)}.${p(w.month)}.${w.year} $time';
  }

  static String _role(AppLocalizations l10n, RoleCode r) => switch (r) {
    RoleCode.seller => l10n.role_seller,
    RoleCode.cashier => l10n.role_cashier,
    RoleCode.seniorSeller => l10n.role_senior_seller,
    RoleCode.admin => l10n.role_admin,
    RoleCode.owner => l10n.role_owner,
    RoleCode.customer => l10n.role_customer,
    RoleCode.integration => l10n.role_integration,
  };
}

class _HeaderSkeleton extends StatelessWidget {
  const _HeaderSkeleton();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(context.space.s6),
    child: const Column(
      children: <Widget>[
        SkeletonBox.avatar(size: 64),
        SizedBox(height: 12),
        SkeletonBox.text(width: 200, height: 24),
        SizedBox(height: 8),
        SkeletonBox.text(width: 140, height: 16),
      ],
    ),
  );
}

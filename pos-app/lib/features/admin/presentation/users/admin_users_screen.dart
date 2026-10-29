// SCR-45 «Админ: пользователи, роли, приглашения» (02 SCR-45; RM-D-010, RM-D-016; маршрут
// `/admin/users?tab=users|invitations|links&userId=`). Режимы: `admin` — полный; `owner` — по ядру
// §21 п.3 (11 §4.4). Compact: вкладки → инструменты → список; тап → карточка отдельным экраном,
// FAB «+ Пригласить». Medium (ландшафт)/expanded: мастер-деталь (список 360/400 + карточка ≤ 800).
// Данные не кэшируются (ПДн): офлайн — EmptyState offlineNoCache.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/debouncer.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_users_policy.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_nav_menu.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_controller.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_user_card.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/invitations_tab.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/invite_form.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/links_tab.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/role_badge.dart';

/// Вкладки SCR-45 (`?tab=`).
enum AdminUsersTab {
  users('users'),
  invitations('invitations'),
  links('links');

  const AdminUsersTab(this.value);

  final String value;

  static AdminUsersTab? tryParse(String? v) => values.where((t) => t.value == v).firstOrNull;
}

class AdminUsersScreen extends ConsumerStatefulWidget {
  const AdminUsersScreen({super.key, this.initialTab, this.initialUserId});

  /// `?tab=`.
  final AdminUsersTab? initialTab;

  /// `?userId=` — восстанавливает карточку (02 SCR-45.11).
  final String? initialUserId;

  @override
  ConsumerState<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends ConsumerState<AdminUsersScreen> with TickerProviderStateMixin {
  TabController? _tabs;
  List<AdminUsersTab> _visible = const [];
  late final AppLifecycleListener _lifecycle;

  AdminUsersController get _controller => ref.read(adminUsersControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Сворачивание приложения — step-up токены экрана забываются (повтор потребует подтверждения).
    _lifecycle = AppLifecycleListener(onHide: () => _controller.forgetStepUp());
    final id = widget.initialUserId;
    if (id != null) scheduleMicrotask(() => unawaited(_controller.select(id)));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _tabs?.dispose();
    super.dispose();
  }

  void _syncTabs(List<AdminUsersTab> visible) {
    if (_tabs != null && _sameTabs(visible, _visible)) return;
    final previous = _tabs == null ? widget.initialTab : _visible[_tabs!.index];
    _tabs?.dispose();
    _visible = visible;
    final index = previous == null ? 0 : visible.indexOf(previous);
    _tabs = TabController(length: visible.length, vsync: this, initialIndex: index < 0 ? 0 : index);
  }

  static bool _sameTabs(List<AdminUsersTab> a, List<AdminUsersTab> b) =>
      a.length == b.length && List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);

  Future<void> _invite() async {
    if (_tabs != null && _visible.contains(AdminUsersTab.invitations)) {
      final created = await InviteForm.show(context);
      if (created != null && mounted) _tabs!.animateTo(_visible.indexOf(AdminUsersTab.invitations));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(adminUsersControllerProvider);
    final policy = state.policy;
    final windowClass = DsBreakpoints.of(context);
    final compact = windowClass == WindowClass.compact;

    Widget body;
    if (state.viewerFailure != null) {
      final failure = state.viewerFailure!;
      body = failure is NetworkFailure
          ? EmptyState(
              variant: EmptyStateVariant.offlineNoCache,
              title: l10n.auth_error_network,
              actionLabel: l10n.ds_button_retry,
              onAction: () => unawaited(_controller.retry()),
            )
          : ErrorState.fullScreen(
              title: l10n.admin_users_title,
              message: AdminFailureText.of(l10n, failure),
              onRetry: () => unawaited(_controller.retry()),
              requestId: failure.requestId,
            );
    } else if (policy == null) {
      body = const _ListSkeleton();
    } else if (policy.mode == AdminUsersMode.none) {
      body = EmptyState(variant: EmptyStateVariant.noPermission, title: l10n.error_forbidden);
    } else {
      final selfService = ref.watch(adminCustomerSelfServiceProvider);
      final visible = [
        AdminUsersTab.users,
        if (policy.canSeeInvitations) AdminUsersTab.invitations,
        if (policy.canSeeLinks(customerSelfService: selfService, hasCases: state.links.items.isNotEmpty))
          AdminUsersTab.links,
      ];
      _syncTabs(visible);
      body = Column(
        children: [
          TabBar(
            key: const ValueKey<String>('admin-users-tabs'),
            controller: _tabs,
            isScrollable: compact,
            tabs: [
              for (final t in visible)
                Tab(
                  key: ValueKey<String>('admin-tab-${t.value}'),
                  text: switch (t) {
                    AdminUsersTab.users => l10n.admin_users_tab_users(state.users.count),
                    AdminUsersTab.invitations => l10n.admin_users_tab_invitations(state.invitations.count),
                    AdminUsersTab.links => l10n.admin_users_tab_links(state.links.count),
                  },
                ),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                for (final t in visible)
                  switch (t) {
                    AdminUsersTab.users => _UsersTab(windowClass: windowClass, onInvite: () => unawaited(_invite())),
                    AdminUsersTab.invitations => const InvitationsTab(),
                    AdminUsersTab.links => const LinksTab(),
                  },
              ],
            ),
          ),
        ],
      );
    }

    final canInvite = policy?.canManageInvitations ?? false;
    return CallbackShortcuts(
      bindings: {
        if (canInvite) const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => unawaited(_invite()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const ValueKey<String>('scr-45'),
          appBar: AppBar(
            title: Text(l10n.admin_users_title),
            // Переходы ветки «Админ» (02 SCR-45.6; этап G): Настройки · Аудит · Отчёты.
            actions: const <Widget>[
              AdminNavMenu(current: AdminSection.users),
              SizedBox(width: 8),
            ],
          ),
          body: body,
          floatingActionButton: compact && canInvite
              ? FloatingActionButton.extended(
                  key: const ValueKey<String>('admin-invite-fab'),
                  onPressed: () => unawaited(_invite()),
                  icon: const Icon(Icons.person_add_rounded),
                  label: Text(l10n.admin_users_invite_button),
                )
              : null,
        ),
      ),
    );
  }
}

/// Вкладка «Пользователи»: инструменты (UI-45-002, UI-45-008) + список (UI-45-003) + карточка.
class _UsersTab extends ConsumerStatefulWidget {
  const _UsersTab({required this.windowClass, required this.onInvite});

  final WindowClass windowClass;
  final VoidCallback onInvite;

  @override
  ConsumerState<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends ConsumerState<_UsersTab> {
  final Debouncer _debounce = Debouncer(Debouncer.search);
  final TextEditingController _search = TextEditingController();

  AdminUsersController get _controller => ref.read(adminUsersControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(adminUsersControllerProvider).query.q;
  }

  @override
  void dispose() {
    _debounce.dispose();
    _search.dispose();
    super.dispose();
  }

  bool get _masterDetail {
    final wc = widget.windowClass;
    if (wc == WindowClass.expanded || wc == WindowClass.large) return true;
    if (wc == WindowClass.medium) return MediaQuery.orientationOf(context) == Orientation.landscape;
    return false;
  }

  void _onSearch(String text) {
    _debounce(() {
      final q = ref.read(adminUsersControllerProvider).query;
      unawaited(_controller.setQuery(q.copyWith(q: text, clearCursor: true)));
    });
  }

  Future<void> _open(AdminUser user) async {
    unawaited(_controller.select(user.id));
    if (_masterDetail) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: Text(AppLocalizations.of(ctx).admin_users_title)),
          body: const AdminUserCard(),
        ),
      ),
    );
    if (mounted) unawaited(_controller.select(null));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(adminUsersControllerProvider);
    final policy = state.policy!;
    final query = state.query;
    final compact = widget.windowClass == WindowClass.compact;

    final roleItems = [
      AppDropdownItem<String>(value: '', label: l10n.admin_users_filter_all),
      for (final r in staffRoles) AppDropdownItem<String>(value: r.value, label: AdminLabels.role(l10n, r)),
    ];
    final statusItems = [
      AppDropdownItem<String>(value: '', label: l10n.admin_users_filter_all),
      for (final s in const [UserStatus.active, UserStatus.pendingActivation, UserStatus.blocked])
        AppDropdownItem<String>(value: s.value, label: AdminLabels.userStatus(l10n, s.value)),
    ];

    final toolbar = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          SizedBox(
            width: compact ? double.infinity : 360, // money-double: allow — геометрия UI (lp)
            child: SearchBar(
              key: const ValueKey<String>('admin-users-search'),
              variant: SearchBarVariant.compact,
              controller: _search,
              placeholder: l10n.admin_users_search_hint,
              semanticLabel: l10n.admin_users_search_hint,
              onChanged: _onSearch,
            ),
          ),
          SizedBox(
            width: 200,
            child: AppDropdown<String>(
              key: const ValueKey<String>('admin-users-filter-role'),
              label: l10n.admin_users_filter_role,
              items: roleItems,
              value: query.role?.value ?? '',
              onChanged: (v) => unawaited(
                _controller.setQuery(
                  query.copyWith(role: RoleCode.tryParse(v), clearRole: v.isEmpty, clearCursor: true),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 200,
            child: AppDropdown<String>(
              key: const ValueKey<String>('admin-users-filter-status'),
              label: l10n.admin_users_filter_status,
              items: statusItems,
              value: query.status?.value ?? '',
              onChanged: (v) => unawaited(
                _controller.setQuery(
                  query.copyWith(status: UserStatus.tryParse(v), clearStatus: v.isEmpty, clearCursor: true),
                ),
              ),
            ),
          ),
          if (!compact && policy.canManageInvitations)
            AppButton(
              key: const ValueKey<String>('admin-invite-button'),
              label: l10n.admin_users_invite_button,
              size: AppButtonSize.l,
              onPressed: widget.onInvite,
            ),
        ],
      ),
    );

    final list = _UsersList(
      state: state,
      compact: compact,
      selectedId: _masterDetail ? state.selectedId : null,
      onOpen: (u) => unawaited(_open(u)),
      onInvite: policy.canManageInvitations ? widget.onInvite : null,
      onRetry: () => unawaited(_controller.reloadUsers()),
      onMore: () => unawaited(_controller.loadMoreUsers()),
    );

    if (!_masterDetail) {
      return Column(
        children: [
          toolbar,
          Expanded(child: list),
        ],
      );
    }
    final listWidth = widget.windowClass == WindowClass.large ? 400.0 : 360.0;
    return Column(
      children: [
        toolbar,
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: listWidth, child: list),
              const VerticalDivider(width: 1),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: state.selectedId == null ? const SizedBox.shrink() : const AdminUserCard(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UsersList extends StatelessWidget {
  const _UsersList({
    required this.state,
    required this.compact,
    required this.selectedId,
    required this.onOpen,
    required this.onInvite,
    required this.onRetry,
    required this.onMore,
  });

  final AdminUsersState state;
  final bool compact;
  final String? selectedId;
  final ValueChanged<AdminUser> onOpen;
  final VoidCallback? onInvite;
  final VoidCallback onRetry;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final slice = state.users;
    if (slice.loading && slice.items.isEmpty) return const _ListSkeleton();
    if (slice.failure != null && slice.items.isEmpty) {
      final failure = slice.failure!;
      if (failure is NetworkFailure) {
        return EmptyState(
          variant: EmptyStateVariant.offlineNoCache,
          title: l10n.auth_error_network,
          actionLabel: l10n.ds_button_retry,
          onAction: onRetry,
        );
      }
      return Center(
        child: ErrorState.inline(message: AdminFailureText.of(l10n, failure), onRetry: onRetry),
      );
    }
    if (slice.items.isEmpty) {
      return EmptyState(
        variant: EmptyStateVariant.search,
        title: l10n.admin_users_empty,
        actionLabel: onInvite == null ? null : l10n.admin_users_invite_button,
        onAction: onInvite,
      );
    }
    return ListView.separated(
      key: const ValueKey<String>('admin-users-list'),
      itemCount: slice.items.length + (slice.hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i >= slice.items.length) {
          WidgetsBinding.instance.addPostFrameCallback((_) => onMore());
          return const Padding(padding: EdgeInsets.all(16), child: SkeletonBox.text());
        }
        final user = slice.items[i];
        return _UserRow(user: user, compact: compact, selected: user.id == selectedId, onTap: () => onOpen(user));
      },
    );
  }
}

/// Строка пользователя (UI-45-003): аватар, ФИО, телефон, `RoleBadge` ≤ 3, `StatusChip`, последний вход.
class _UserRow extends StatelessWidget {
  const _UserRow({required this.user, required this.compact, required this.selected, required this.onTap});

  final AdminUser user;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final name = (user.fullName?.trim().isNotEmpty ?? false) ? user.fullName!.trim() : '—';
    final phone = user.phone == null ? '' : (user.hasFullPhone ? DsPhoneFormat.display(user.phone!) : user.phone!);
    final locale = Localizations.localeOf(context).toString();
    final last = user.lastLoginAt == null
        ? null
        : DateFormat('d MMM, HH:mm', locale).format(AdminFormat.wall(user.lastLoginAt!));
    final caption = context.text.caption.copyWith(color: c.textSecondary);
    return Material(
      color: selected ? c.primaryContainer : c.surface,
      child: InkWell(
        key: ValueKey<String>('admin-user-row-${user.id}'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                AdminAvatar(name: name, disabled: user.isBlocked),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.body.copyWith(
                          color: user.isBlocked ? c.disabledText : c.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (phone.isNotEmpty) Text(phone, style: caption),
                      const SizedBox(height: 4),
                      RoleBadges(roles: user.roleCodes, textOnly: compact),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusChip(
                      label: AdminLabels.userStatus(l10n, user.status),
                      variant: AdminLabels.userStatusVariant(user.status),
                      dense: true,
                    ),
                    if (last != null) ...[const SizedBox(height: 4), Text(last, style: caption)],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    physics: const NeverScrollableScrollPhysics(),
    children: [
      for (var i = 0; i < 8; i++)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              SkeletonBox.avatar(),
              SizedBox(width: 12),
              Expanded(child: SkeletonBox.text()),
            ],
          ),
        ),
    ],
  );
}

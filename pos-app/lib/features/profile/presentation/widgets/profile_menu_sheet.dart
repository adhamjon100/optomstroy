// Меню профиля по аватару шапки телефона (compact; 15 ADR-122 п. 2; 02 SCR-41.3, §3.1 п. 8): нижний лист
// `AppBottomSheet` — карточка пользователя (инициалы, ФИО, роль) со ссылкой «Открыть профиль» (SCR-41) и тот же список
// пунктов, что на SCR-41 ([ProfileMenuList]): «История заказов», «Избранное», затем прежние пункты. Лист не уводит с
// текущего экрана; пункт закрывает лист и выполняет действие от экрана, с которого лист открыт. Профиль (`GET /me`)
// лист читает сам — для «Мои транзакции» по правам и «Сменить номер»; без сети или без ответа — пункты без смены
// номера (как SCR-41 офлайн). ПДн — только память листа (09 §8.5).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart' show TopAppBarUser;
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';
import 'package:optomstroy/features/profile/presentation/widgets/profile_actions.dart';
import 'package:optomstroy/features/profile/presentation/widgets/profile_menu_list.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';

/// Открыть меню профиля нижним листом от экрана [context]. [name] и [role] — имя и подпись роли из сессии (до ответа
/// `GET /me`).
Future<void> showProfileMenuSheet(BuildContext context, {required String name, required String role}) {
  return AppBottomSheet.show<void>(
    context,
    body: ProfileMenuSheet(origin: context, name: name, role: role),
  );
}

/// Содержимое листа профиля.
class ProfileMenuSheet extends ConsumerStatefulWidget {
  /// Создаёт содержимое листа.
  const ProfileMenuSheet({super.key, required this.origin, required this.name, required this.role});

  /// Экран, с которого открыт лист: от него — переходы, диалоги и снекбары после закрытия листа.
  final BuildContext origin;

  /// Имя пользователя сессии.
  final String name;

  /// Подпись роли.
  final String role;

  /// Ключ карточки пользователя (тесты).
  static const Key cardKey = ValueKey<String>('profile-sheet-card');

  /// Ключ ссылки «Открыть профиль» (тесты).
  static const Key openProfileKey = ValueKey<String>('profile-sheet-open-profile');

  /// Ключи пунктов (тесты; префикс `profile-sheet`).
  static const Key ordersKey = ValueKey<String>('profile-sheet-orders');
  static const Key favoritesKey = ValueKey<String>('profile-sheet-favorites');
  static const Key logoutKey = ValueKey<String>('profile-sheet-logout');

  @override
  ConsumerState<ProfileMenuSheet> createState() => _ProfileMenuSheetState();
}

class _ProfileMenuSheetState extends ConsumerState<ProfileMenuSheet> {
  UserProfile? _me;
  ProfileRepository? _repo;

  @override
  void initState() {
    super.initState();
    try {
      _repo = ref.read(profileRepositoryProvider);
    } on Object {
      // Порт профиля не подключён (тесты оболочки) — лист без данных `GET /me`.
      _repo = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final ProfileRepository? repo = _repo;
    if (repo == null) return;
    final Result<UserProfile> r = await repo.me();
    if (!mounted) return;
    if (r case Success<UserProfile>(:final UserProfile value)) {
      setState(() => _me = value);
    }
  }

  bool get _staff {
    final UserProfile? me = _me;
    return me == null
        ? ref.read(sessionControllerProvider).userKind != UserKind.customer
        : me.kind != UserKind.customer;
  }

  /// Закрыть лист, затем [action] от экрана-источника (если он ещё на месте).
  void _then(void Function(BuildContext origin) action) {
    Navigator.of(context).pop();
    final BuildContext origin = widget.origin;
    if (origin.mounted) action(origin);
  }

  void _navigate(String location, bool push) => _then((BuildContext origin) {
    final GoRouter? router = GoRouter.maybeOf(origin);
    if (router == null) return;
    if (push) {
      unawaited(router.push<void>(location));
    } else {
      router.go(location);
    }
  });

  void _logout() => _then((BuildContext origin) {
    final SessionController session = ref.read(sessionControllerProvider.notifier);
    unawaited(() async {
      if (await confirmProfileLogout(origin, session)) await session.logout();
    }());
  });

  void _logoutAll() => _then((BuildContext origin) {
    final SessionController session = ref.read(sessionControllerProvider.notifier);
    final AppLocalizations l10n = AppLocalizations.of(origin);
    unawaited(() async {
      if (!await confirmProfileLogoutAll(origin)) return;
      final Object? error = await session.logoutAll();
      if (error != null && origin.mounted) {
        AppSnackbar.show(origin, message: l10n.error_internal, variant: AppSnackbarVariant.error);
      }
    }());
  });

  void _phoneChange(ProfileRepository repo, UserProfile me) => _then((BuildContext origin) {
    final AppLocalizations l10n = AppLocalizations.of(origin);
    unawaited(() async {
      if (await startProfilePhoneChange(origin, repo, me) && origin.mounted) {
        AppSnackbar.show(origin, message: l10n.profile_phone_changed, variant: AppSnackbarVariant.success);
      }
    }());
  });

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final UserProfile? me = _me;
    final ProfileRepository? repo = _repo;
    final bool staff = _staff;
    final bool online = ref.watch(onlineStatusProvider).value != OnlineStatus.offline;
    final String name = (me?.profile.fullName ?? '').trim().isNotEmpty ? me!.profile.fullName!.trim() : widget.name;
    final bool showTransactions =
        me == null || me.permissions.isEmpty || me.permissions.any((String p) => p.startsWith('transactions.read'));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _card(context, l10n, name),
        SizedBox(height: context.space.s2),
        Divider(height: 1, color: context.colors.border),
        ProfileMenuList(
          keyPrefix: 'profile-sheet',
          staff: staff,
          showTransactions: showTransactions,
          online: online,
          loggingOut: false,
          onNavigate: _navigate,
          onLogout: _logout,
          onLogoutAll: _logoutAll,
          onPhoneChange: me == null || repo == null ? null : () => _phoneChange(repo, me),
          onLock: staff
              ? () => _then((_) => ref.read(sessionControllerProvider.notifier).lock(SessionLockReason.manual))
              : null,
        ),
      ],
    );
  }

  /// Карточка пользователя: аватар с инициалами, ФИО и роль; нажатие — SCR-41 «Открыть профиль».
  Widget _card(BuildContext context, AppLocalizations l10n, String name) {
    final String initials = TopAppBarUser.initialsOf(name);
    return Column(
      key: ProfileMenuSheet.cardKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            ExcludeSemantics(
              child: Container(
                width: TopAppBarUser.avatarSize,
                height: TopAppBarUser.avatarSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: context.colors.primaryContainer,
                  borderRadius: BorderRadius.all(context.radii.avatar),
                ),
                child: Text(
                  initials,
                  textScaler: TextScaler.noScaling,
                  style: context.text.avatarInitial.copyWith(color: context.colors.primaryText),
                ),
              ),
            ),
            SizedBox(width: context.space.s3),
            Expanded(
              child: Semantics(
                header: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.body.copyWith(fontWeight: FontWeight.w600, color: context.colors.textPrimary),
                    ),
                    if (widget.role.isNotEmpty && widget.role != name)
                      Text(
                        widget.role,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.caption.copyWith(color: context.colors.textSecondary),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        AppListTile(
          key: ProfileMenuSheet.openProfileKey,
          title: l10n.profile_sheet_open_profile,
          leadingIcon: Icons.account_circle_outlined,
          showChevron: true,
          onTap: () => _navigate(ProfileMenuLocations.profile, false),
        ),
      ],
    );
  }
}

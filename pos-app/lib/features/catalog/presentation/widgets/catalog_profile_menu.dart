// Меню аватара шапки сотрудника (02 SCR-10.3 A9, UI-10-033; ADR-112): первым — заголовок с именем и ролью (не пункт:
// без фокуса и нажатия; в окне уже 1280 lp и на medium имя видно только здесь — SRC-C-004a, 02 A8) → Профиль → SCR-41 ·
// Настройки → SCR-42 ·
// Синхронизация → SCR-43 · Заблокировать (SCR-08, ручная блокировка — как Ctrl+L) · Выйти (ConfirmDialog
// «Выйти из аккаунта?» → `POST /auth/logout`). Одно меню для шапки каталога (`CatalogWorkspace`) и шапки оболочки
// на прочих экранах (`StaffShellHeader`). У клиента — без «Синхронизации» и «Заблокировать» (02 UI-50-001).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/presentation/catalog_paths.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart' show catalogRoleLabel;
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logout.dart';

const String _lockValue = 'lock';
const String _logoutValue = 'logout';

/// Показать меню аватара под [anchor] (блок пользователя шапки). Пункты-переходы передаются в [onNavigate]
/// (экран выбирает `push`/`go`); «Заблокировать» — порт [catalogHeaderLockProvider]; «Выйти» —
/// [confirmCatalogLogout]. [context] — контекст экрана (навигатор, тема), [ref] — его `WidgetRef`.
Future<void> showCatalogProfileMenu({
  required BuildContext context,
  required BuildContext anchor,
  required WidgetRef ref,
  required ValueChanged<String> onNavigate,
}) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final RenderBox box = anchor.findRenderObject()! as RenderBox;
  final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final Offset bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
  final RoleCode? role = ref.read(catalogViewerRoleProvider);
  final bool staff = role != RoleCode.customer;
  final VoidCallback? lock = staff ? ref.read(catalogHeaderLockProvider) : null;
  final String roleText = catalogRoleLabel(l10n, role);
  final String? name = ref.read(catalogViewerNameProvider);
  final String? picked = await showMenu<String>(
    context: context,
    color: context.colors.surface,
    constraints: const BoxConstraints(minWidth: 240, maxWidth: 240),
    position: RelativeRect.fromLTRB(bottomRight.dx - 240, bottomRight.dy + 4, overlay.size.width - bottomRight.dx, 0),
    items: <PopupMenuEntry<String>>[
      if ((name ?? roleText).isNotEmpty) ...<PopupMenuEntry<String>>[
        _ProfileMenuHeader(name: name ?? roleText, role: name == null ? '' : roleText),
        const PopupMenuDivider(height: 1),
      ],
      PopupMenuItem<String>(
        key: const ValueKey<String>('profile-menu-profile'),
        value: CatalogPaths.profile,
        height: 44,
        child: Text(l10n.profile_title),
      ),
      PopupMenuItem<String>(
        key: const ValueKey<String>('profile-menu-settings'),
        value: CatalogPaths.settings,
        height: 44,
        child: Text(l10n.profile_menu_settings),
      ),
      if (staff)
        PopupMenuItem<String>(
          key: const ValueKey<String>('profile-menu-sync'),
          value: CatalogPaths.sync,
          height: 44,
          child: Text(l10n.profile_menu_sync),
        ),
      if (lock != null)
        PopupMenuItem<String>(
          key: const ValueKey<String>('profile-menu-lock'),
          value: _lockValue,
          height: 44,
          child: Text(l10n.profile_menu_lock),
        ),
      // «Выйти» → ConfirmDialog «Выйти из аккаунта?» (фокус на «Отмена») → POST /auth/logout (UI-10-033).
      PopupMenuItem<String>(
        key: const ValueKey<String>('profile-menu-logout'),
        value: _logoutValue,
        height: 44,
        child: Text(l10n.profile_logout),
      ),
    ],
  );
  if (picked == null || !context.mounted) {
    return;
  }
  switch (picked) {
    case _lockValue:
      lock?.call();
    case _logoutValue:
      await confirmCatalogLogout(context, ref);
    default:
      onNavigate(picked);
  }
}

/// Заголовок меню аватара: имя `body 600 textPrimary` и роль `caption textSecondary` (UI-10-033, 02 A8). Не пункт
/// меню — не получает фокус и не нажимается; для screen reader — заголовок.
class _ProfileMenuHeader extends PopupMenuEntry<String> {
  const _ProfileMenuHeader({required this.name, required this.role});

  /// Ключ заголовка (тесты).
  static const Key headerKey = ValueKey<String>('profile-menu-header');

  final String name;
  final String role;

  @override
  double get height => 56; // money-double: allow — высота строки меню (lp)

  @override
  bool represents(String? value) => false;

  @override
  State<_ProfileMenuHeader> createState() => _ProfileMenuHeaderState();
}

class _ProfileMenuHeaderState extends State<_ProfileMenuHeader> {
  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: _ProfileMenuHeader.headerKey,
      header: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: widget.height),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.body.copyWith(fontWeight: FontWeight.w600, color: context.colors.textPrimary),
              ),
              if (widget.role.isNotEmpty)
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
    );
  }
}

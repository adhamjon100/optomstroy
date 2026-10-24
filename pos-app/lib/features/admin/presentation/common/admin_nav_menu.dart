// Переходы между разделами ветки «Админ» (02 SCR-45.6, SCR-46.6, SCR-47.6, SCR-48.6; GQ-FEFND-03): меню шапки
// «Пользователи · Настройки · Аудит · Отчёты» на SCR-45/46/47. Права проверяют guard маршрутов и сервер (D-15):
// меню только ведёт по адресам `/admin/*` и `/reports`, текущий раздел в нём отмечен.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Раздел ветки «Админ».
enum AdminSection {
  users('/admin/users'),
  settings('/admin/settings'),
  audit('/admin/audit'),
  reports('/reports');

  const AdminSection(this.path);

  final String path;
}

/// Меню разделов админа в шапке.
class AdminNavMenu extends StatelessWidget {
  const AdminNavMenu({required this.current, this.onNavigate, super.key});

  /// Ключ кнопки меню.
  static const Key buttonKey = ValueKey<String>('admin-nav-menu');

  /// Ключ пункта.
  static Key itemKey(AdminSection s) => ValueKey<String>('admin-nav-${s.name}');

  /// Текущий раздел.
  final AdminSection current;

  /// Переход (по умолчанию — `GoRouter.go`); для экранов с несохранёнными изменениями — с подтверждением.
  final void Function(String location)? onNavigate;

  static String label(AppLocalizations l10n, AdminSection s) => switch (s) {
    AdminSection.users => l10n.admin_users_title,
    AdminSection.settings => l10n.admin_settings_title,
    AdminSection.audit => l10n.audit_title,
    AdminSection.reports => l10n.reports_title,
  };

  static IconData icon(AdminSection s) => switch (s) {
    AdminSection.users => Icons.admin_panel_settings_outlined,
    AdminSection.settings => Icons.settings_outlined,
    AdminSection.audit => Icons.fact_check_outlined,
    AdminSection.reports => Icons.bar_chart_rounded,
  };

  void _go(BuildContext context, String location) {
    if (onNavigate != null) {
      onNavigate!(location);
      return;
    }
    GoRouter.maybeOf(context)?.go(location);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return PopupMenuButton<AdminSection>(
      key: buttonKey,
      tooltip: l10n.ds_button_more,
      icon: const Icon(Icons.apps_rounded),
      onSelected: (AdminSection s) => _go(context, s.path),
      itemBuilder: (BuildContext _) => <PopupMenuEntry<AdminSection>>[
        for (final AdminSection s in AdminSection.values)
          PopupMenuItem<AdminSection>(
            key: itemKey(s),
            value: s,
            enabled: s != current,
            child: Row(
              children: <Widget>[
                Icon(icon(s), size: 20, color: context.colors.textSecondary),
                SizedBox(width: context.space.s3),
                Text(label(l10n, s)),
              ],
            ),
          ),
      ],
    );
  }
}

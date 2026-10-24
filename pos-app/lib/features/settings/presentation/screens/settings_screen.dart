// SCR-42 «Настройки» (`/settings?section=`, все роли; 02 ч. E SCR-42; RM-D-009).
//
// Compact — список секций → экран секции (`?section=`), «Назад» возвращает к списку; medium/expanded —
// навигация секций 240 lp слева и содержимое ≤ 640 lp справа (02 SCR-42.2). Секции: «Язык», «Защита входа»,
// «Устройства и сессии», «Сканер штрихкодов» и «Принтер» (только staff и только если фича-владелец подключила
// секцию — `settingsScannerSectionProvider` / `settingsPrinterSectionProvider`; готовая секция «Принтер» —
// `PrinterSettingsSection` с портом `PrinterSettingsPort`, этап G), «Отображение», «О приложении».
// Имя класса, путь файла и параметры конструктора фиксированы маршрутом (app/router/routes.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/settings_texts.dart';
import 'package:optomstroy/features/settings/presentation/widgets/basic_sections.dart';
import 'package:optomstroy/features/settings/presentation/widgets/scanner_server_settings.dart';
import 'package:optomstroy/features/settings/presentation/widgets/security_section.dart';
import 'package:optomstroy/features/settings/presentation/widgets/sessions_section.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

/// SCR-42 — Настройки.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({this.section, super.key});

  /// ID экрана по 02 §4.1.
  static const String screenId = 'SCR-42';

  /// Корневой ключ экрана.
  static const Key screenKey = ValueKey<String>('scr-42');

  /// Ширина навигации секций (medium/expanded).
  static const double navWidth = 240; // money-double: allow — геометрия UI (lp)

  /// Максимальная ширина содержимого секции.
  static const double contentMaxWidth = 640; // money-double: allow — геометрия UI (lp)

  /// Ключ пункта секции в списке.
  static Key tileKey(SettingsSection s) => ValueKey<String>('settings-tile-${s.value}');

  /// Ключ содержимого секции.
  static Key contentKey(SettingsSection s) => ValueKey<String>('settings-content-${s.value}');

  /// Открыть раздел настроек.
  final String? section;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  SettingsSection? _selected;

  @override
  void initState() {
    super.initState();
    _selected = SettingsSection.tryParse(widget.section);
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) _selected = SettingsSection.tryParse(widget.section);
  }

  List<SettingsSection> _visible(SettingsViewer viewer) => <SettingsSection>[
    SettingsSection.language,
    SettingsSection.security,
    SettingsSection.sessions,
    if (viewer.isStaff && ref.watch(settingsScannerSectionProvider) != null) SettingsSection.scanner,
    if (viewer.isStaff && ref.watch(settingsPrinterSectionProvider) != null) SettingsSection.printer,
    SettingsSection.display,
    SettingsSection.about,
  ];

  void _select(SettingsSection? s) {
    setState(() => _selected = s);
    // Адрес `?section=` (переходы 02 SCR-42.6); без роутера (виджет-тесты) — только состояние экрана.
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go(
        Uri(path: '/settings', queryParameters: s == null ? null : <String, String>{'section': s.value}).toString(),
      );
    }
  }

  IconData _icon(SettingsSection s) => switch (s) {
    SettingsSection.language => Icons.language_rounded,
    SettingsSection.security => Icons.lock_outline_rounded,
    SettingsSection.sessions => Icons.devices_outlined,
    SettingsSection.scanner => Icons.qr_code_scanner_rounded,
    SettingsSection.printer => Icons.print_outlined,
    SettingsSection.display => Icons.text_fields_rounded,
    SettingsSection.about => Icons.info_outline_rounded,
  };

  Widget _content(BuildContext context, SettingsSection s) {
    final Widget body = switch (s) {
      SettingsSection.language => const LanguageSection(),
      SettingsSection.security => const SecuritySection(),
      SettingsSection.sessions => const SessionsSection(),
      SettingsSection.scanner => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[const ScannerServerSettings(), ref.watch(settingsScannerSectionProvider)!(context)],
      ),
      SettingsSection.printer => ref.watch(settingsPrinterSectionProvider)!(context),
      SettingsSection.display => const DisplaySection(),
      SettingsSection.about => const AboutSection(),
    };
    return SingleChildScrollView(
      key: SettingsScreen.contentKey(s),
      padding: EdgeInsets.all(context.space.s4),
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: SettingsScreen.contentMaxWidth),
          child: body,
        ),
      ),
    );
  }

  String? _currentValue(AppLocalizations l10n, SettingsSection s) => switch (s) {
    SettingsSection.language => l10n.settings_language_ru,
    SettingsSection.about => ref.watch(appAboutSourceProvider).current().appVersion,
    _ => null,
  };

  Widget _list(BuildContext context, List<SettingsSection> visible, {required bool master}) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return ListView(
      padding: EdgeInsets.symmetric(vertical: context.space.s2),
      children: <Widget>[
        for (final SettingsSection s in visible)
          AppListTile(
            key: SettingsScreen.tileKey(s),
            title: SettingsTexts.section(l10n, s),
            // Текущее значение секции в списке compact (02 SCR-42.2): язык, версия приложения.
            subtitle: master ? null : _currentValue(l10n, s),
            leadingIcon: _icon(s),
            selected: master && s == _selected,
            showChevron: !master,
            onTap: () => _select(s),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final SettingsViewer viewer = ref.watch(settingsViewerProvider);
    final List<SettingsSection> visible = _visible(viewer);
    final SettingsSection? selected = visible.contains(_selected) ? _selected : null;
    final bool compact = context.windowClass == WindowClass.compact;

    if (compact) {
      if (selected == null) {
        return Scaffold(
          key: SettingsScreen.screenKey,
          appBar: AppBar(title: Text(l10n.settings_title)),
          body: _list(context, visible, master: false),
        );
      }
      return PopScope<Object?>(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? result) {
          if (!didPop) _select(null);
        },
        child: Scaffold(
          key: SettingsScreen.screenKey,
          appBar: AppBar(
            leading: BackButton(onPressed: () => _select(null)),
            title: Text(SettingsTexts.section(l10n, selected)),
          ),
          body: _content(context, selected),
        ),
      );
    }

    final SettingsSection current = selected ?? SettingsSection.security;
    if (_selected != current) _selected = current;
    return Scaffold(
      key: SettingsScreen.screenKey,
      appBar: AppBar(title: Text(l10n.settings_title)),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: SettingsScreen.navWidth, child: _list(context, visible, master: true)),
          VerticalDivider(width: 1, thickness: 1, color: context.colors.border),
          Expanded(child: _content(context, current)),
        ],
      ),
    );
  }
}

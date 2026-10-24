// RM-G-008 (golden): SCR-46 «Лимиты скидок и настройки» (admin — изменение; owner — только просмотр) и SCR-47
// «Аудит» (запись с разрывом цепочки `chainOk=false`) на трёх брейкпоинтах compact / medium / expanded
// (03 §7.2; D-18 — эталоны Windows), палитра B. Данные синтетические.
//
// Обновить эталоны: flutter test test/features/admin/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/presentation/audit/audit_screen.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_screen.dart';

import '../support/fake_admin_repository.dart';
import '../support/fake_admin_settings.dart';

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(360, 760),
  'medium': Size(800, 900),
  'expanded': Size(1280, 800),
};

List<Override> _overrides(AdminViewer me) => <Override>[
  ...adminTestOverrides(
    FakeAdminUsersRepository(
      me: me,
      users: [staff(adminId, role: RoleCode.admin, name: 'Гульнара Админова')],
    ),
  ),
  adminSettingsRepositoryProvider.overrideWithValue(FakeAdminSettingsRepository()),
  auditLogRepositoryProvider.overrideWithValue(FakeAuditLogRepository()),
];

Widget _app(Size size, List<Override> overrides, Widget home) => SizedBox(
  width: size.width,
  height: size.height,
  child: ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
        child: child!,
      ),
      home: home,
    ),
  ),
);

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, AdminViewer> modes = <String, AdminViewer>{'admin': adminViewer, 'owner': ownerViewer};
  for (final MapEntry<String, AdminViewer> mode in modes.entries) {
    for (final MapEntry<String, Size> w in _windows.entries) {
      unawaited(
        goldenTest(
          'SCR-46 ${mode.key} · ${w.key}',
          fileName: 'admin_scr46_${mode.key}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          builder: () => _app(w.value, _overrides(mode.value), const AdminSettingsScreen()),
        ),
      );
    }
  }
  for (final MapEntry<String, Size> w in _windows.entries) {
    unawaited(
      goldenTest(
        'SCR-47 owner · ${w.key}',
        fileName: 'admin_scr47_${w.key}',
        constraints: BoxConstraints.tight(w.value),
        builder: () => _app(w.value, _overrides(ownerViewer), const AuditScreen()),
      ),
    );
  }
}

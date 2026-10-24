// RM-D-010 п. 2 (golden): SCR-45 «Пользователи и роли» на трёх брейкпоинтах compact / medium / expanded
// (03 §7.2; D-18 — эталоны Windows), палитра B: режим `admin` (список, вкладки, приглашение) и режим `owner`
// (просмотр, ядро §21 п.3). Данные синтетические (номера +99670000000N).
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
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_screen.dart';

import '../support/fake_admin_repository.dart';

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(360, 760),
  'medium': Size(800, 900),
  'expanded': Size(1280, 800),
};

FakeAdminUsersRepository _seed(AdminViewer me) => FakeAdminUsersRepository(
  me: me,
  users: <AdminUser>[
    staff(adminId, role: RoleCode.admin, name: 'Гульнара Админова', phone: '+996700000010'),
    staff(cashierId, name: 'Иван Петров', phone: '+996700000001'),
    staff(otherAdminId, role: RoleCode.admin, name: 'Бакыт Асанов', phone: '+996700000002'),
    staff(ownerId, role: RoleCode.owner, name: 'Нурлан Руководитель', phone: '+996700000003'),
    staff(pendingId, role: RoleCode.seller, name: 'Айгуль Продавец', status: 'blocked', phone: '+996700000004'),
  ],
  invitations: <Invitation>[
    Invitation(
      id: 'inv-1',
      phoneMasked: '+996 7** *** *07',
      roles: const <String>['seller'],
      status: 'pending',
      createdByName: 'Г. А.',
      createdAt: t0,
      expiresAt: t0.add(const Duration(days: 30)),
    ),
  ],
);

Widget _app(Size size, List<Override> overrides) => SizedBox(
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
      home: const AdminUsersScreen(),
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
          'SCR-45 ${mode.key} · ${w.key}',
          fileName: 'admin_scr45_${mode.key}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          builder: () => _app(w.value, adminTestOverrides(_seed(mode.value))),
        ),
      );
    }
  }
}

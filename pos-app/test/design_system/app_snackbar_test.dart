// AppSnackbar (03 §9.48, редакция 1.10; ADR-112): тост «Добавлено: {name}» внизу справа (≤ 360, поля 24, 2 с;
// 8 с при screen reader), поля внутри drawer корзины по свободной ширине окна (AppSnackbarRegion), прежние
// варианты compact (во всю ширину) и medium+ (по центру, 480).
// Тест-кейсы 12_TEST_PLAN: T-CART-038 (длительность и поля тоста).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

AppSnackbarRegion _region(double endInset, {double bottom = 0}) =>
    AppSnackbarRegion(endInset: endInset, bottomInset: ValueNotifier<double>(bottom), child: const SizedBox.shrink());

void main() {
  test('длительность: 4 с; с действием или при screen reader — 8 с; тост — 2 с (8 с при screen reader)', () {
    expect(AppSnackbar.durationFor(hasAction: false, accessibleNavigation: false), const Duration(seconds: 4));
    expect(AppSnackbar.durationFor(hasAction: true, accessibleNavigation: false), const Duration(seconds: 8));
    expect(
      AppSnackbar.durationFor(hasAction: false, accessibleNavigation: false, brief: true),
      const Duration(seconds: 2),
    );
    expect(
      AppSnackbar.durationFor(hasAction: false, accessibleNavigation: true, brief: true),
      const Duration(seconds: 8),
    );
  });

  test('поля: compact — во всю ширину; medium+ — по центру (null, ширина 480); тост — внизу справа ≤ 360', () {
    expect(
      AppSnackbar.marginFor(windowWidth: 390, windowClass: WindowClass.compact, placement: AppSnackbarPlacement.auto),
      const EdgeInsets.fromLTRB(16, 0, 16, 8),
    );
    expect(
      AppSnackbar.marginFor(
        windowWidth: 390,
        windowClass: WindowClass.compact,
        placement: AppSnackbarPlacement.bottomEnd,
      ),
      const EdgeInsets.fromLTRB(16, 0, 16, 8),
      reason: 'на compact тост — как обычный снекбар',
    );
    expect(
      AppSnackbar.marginFor(windowWidth: 1280, windowClass: WindowClass.expanded, placement: AppSnackbarPlacement.auto),
      isNull,
    );
    final EdgeInsets toast = AppSnackbar.marginFor(
      windowWidth: 1440,
      windowClass: WindowClass.large,
      placement: AppSnackbarPlacement.bottomEnd,
    )!;
    expect(toast.right, 24);
    expect(toast.bottom, 24);
    expect(1440 - toast.left - toast.right, 360);
  });

  test('drawer 420: широкое окно — слева от drawer (поля 24, до 480); узкое — внутри drawer над низом', () {
    final EdgeInsets side = AppSnackbar.marginFor(
      windowWidth: 1280,
      windowClass: WindowClass.expanded,
      placement: AppSnackbarPlacement.auto,
      region: _region(420),
    )!;
    expect(side.right, 420 + 24, reason: 'у левого края drawer');
    expect(1280 - side.left - side.right, 480);
    expect(side.bottom, 24);

    final EdgeInsets inside = AppSnackbar.marginFor(
      windowWidth: 700,
      windowClass: WindowClass.medium,
      placement: AppSnackbarPlacement.auto,
      region: _region(420, bottom: 210),
    )!;
    expect(inside.left, 700 - 420 + 16, reason: 'внутри drawer, а не по ширине окна');
    expect(inside.right, 16);
    expect(inside.bottom, 210 + 8, reason: 'над итогами и кнопками');
  });
}

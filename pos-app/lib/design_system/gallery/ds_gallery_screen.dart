import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/gallery/ds_showcase.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Витрина дизайн-системы `/dev/gallery` (RM-C-003) — **только debug**: в release-сборке
/// экран пуст, маршрут регистрирует `app/router` под `kDebugMode`.
class DsGalleryScreen extends StatelessWidget {
  /// Создаёт витрину.
  const DsGalleryScreen({super.key});

  /// Путь маршрута.
  static const String routePath = '/dev/gallery';

  /// Ключ корневого виджета.
  static const Key screenKey = Key('dev-gallery');

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) {
      return const SizedBox.shrink(key: screenKey);
    }
    return Scaffold(
      key: screenKey,
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: CustomScrollView(
          slivers: <Widget>[
            const SliverToBoxAdapter(
              child: TopAppBarPos(variant: TopAppBarVariant.compact, title: 'Дизайн-система · палитра B'),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: context.windowClass.index == 0 ? 16 : 24, vertical: 16),
              sliver: SliverList.list(
                children: <Widget>[
                  const _LiveOverlays(),
                  for (final DsShowcaseSection s in DsShowcase.sections) _Section(section: s),
                  _Section(
                    section: DsShowcaseSection(
                      'scaffold',
                      'AdaptiveScaffold (текущий класс окна)',
                      (BuildContext c) => SizedBox(height: 560, child: DsShowcase.scaffold(c)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.section});

  final DsShowcaseSection section;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(section.title, style: context.text.h3.copyWith(color: context.colors.textPrimary)),
          const SizedBox(height: 12),
          section.builder(context),
        ],
      ),
    );
  }
}

/// Живые оверлеи: настоящие диалог, нижний/боковой лист и снекбар.
class _LiveOverlays extends StatelessWidget {
  const _LiveOverlays();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          AppButton(
            label: 'ConfirmDialog',
            variant: AppButtonVariant.outlined,
            onPressed: () => unawaited(
              ConfirmDialog.show(
                context,
                title: 'Очистить корзину?',
                message: 'Будут удалены 5 позиций',
                confirmLabel: 'Очистить',
                variant: ConfirmDialogVariant.destructive,
                onConfirm: (String? _) => Future<void>.delayed(const Duration(seconds: 1)),
              ),
            ),
          ),
          AppButton(
            label: 'AppBottomSheet',
            variant: AppButtonVariant.outlined,
            onPressed: () => unawaited(
              AppBottomSheet.show<void>(
                context,
                title: 'Сортировка',
                body: const AppRadio<int>(value: 1, groupValue: 1, onChanged: null, label: 'По названию'),
              ),
            ),
          ),
          AppButton(
            label: 'AppBottomSheet.side',
            variant: AppButtonVariant.outlined,
            onPressed: () => unawaited(
              AppBottomSheet.showSide<void>(
                context,
                title: 'Детали',
                width: AppBottomSheet.sideExpanded,
                body: const Text('Боковая панель 480'),
              ),
            ),
          ),
          AppButton(
            label: 'AppSnackbar',
            variant: AppButtonVariant.outlined,
            onPressed: () => AppSnackbar.show(
              context,
              message: 'Добавлено в корзину',
              variant: AppSnackbarVariant.success,
              actionLabel: 'Отменить',
              onAction: () {},
            ),
          ),
        ],
      ),
    );
  }
}

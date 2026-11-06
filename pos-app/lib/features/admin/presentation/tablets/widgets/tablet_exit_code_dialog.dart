// Аварийный код выхода SCR-54 UI-54-014 (02 SCR-54.3, SCR-54.11; FLOW-043.S5; 11 SEC-140; AC-UI-54-005): код из 8
// цифр показывается один раз крупно (`h1`, цифры одной ширины — tnum, группы по 4) с «Запишите код и уберите в конверт в
// сейфе…»; без отмены, без закрытия по затемнению и «Назад» — только «Готово». Копирования нет (обычный `Text`, без
// выделения); `SecureContent` — `FLAG_SECURE` на Android и заливка в переключателе приложений. Код живёт только в
// параметре этого виджета: не пишется в журналы, адрес, буфер обмена и хранилища. «Готово» → [TabletExitCodeDialog.onDone]
// (устройство уходит в режим планшета, SCR-51); во время перехода кнопка в состоянии loading.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';

class TabletExitCodeDialog extends StatefulWidget {
  const TabletExitCodeDialog({super.key, required this.code, required this.onDone});

  /// Аварийный код (8 цифр).
  final String code;

  /// «Готово»: переход в режим планшета (исключений не бросает — ошибки показывает вызывающий).
  final Future<void> Function() onDone;

  static const Key codeKey = ValueKey<String>('tablet-exit-code');
  static const Key doneKey = ValueKey<String>('tablet-exit-code-done');

  /// Диалог 480 по центру; закрывается только «Готово».
  static Future<void> show(BuildContext context, {required String code, required Future<void> Function() onDone}) =>
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext ctx) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: TabletExitCodeDialog(code: code, onDone: onDone),
          ),
        ),
      );

  @override
  State<TabletExitCodeDialog> createState() => _TabletExitCodeDialogState();
}

class _TabletExitCodeDialogState extends State<TabletExitCodeDialog> {
  bool _busy = false;

  Future<void> _done() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onDone();
    // Переход в режим планшета (G-15 → `/kiosk`) снимает экран SCR-54 вместе с диалогом; если диалог остался — закрыть
    // именно его. Маршрут диалога уже снят (виджет ещё в дереве на анимации ухода) — `pop` снял бы последнюю страницу
    // маршрутизатора (`/kiosk`; integration_test/kiosk_flow_test.dart, WP-A11).
    if (!mounted) return;
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      route.navigator?.removeRoute(route);
    }
  }

  /// Текст строки `kiosk_admin_exit_code` до и после `{code}` (код показывается отдельно, крупно).
  static (String, String) _around(AppLocalizations l10n) {
    const String marker = '\u{E000}';
    final String full = l10n.kiosk_admin_exit_code(marker);
    final int at = full.indexOf(marker);
    if (at < 0) return (full, '');
    final String before = full.substring(0, at).trim();
    final String after = full.substring(at + marker.length).replaceFirst(RegExp(r'^[\s.,;:]+'), '').trim();
    return (before, after);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final (String before, String after) = _around(l10n);
    final TextStyle body = context.text.body.copyWith(color: context.colors.textPrimary);
    return PopScope(
      canPop: false,
      child: SecureContent(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(context.space.s5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Semantics(
                liveRegion: true,
                label: l10n.kiosk_admin_exit_code(KioskEnrollment.grouped(widget.code)),
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (before.isNotEmpty)
                        Text(before, style: context.text.h3.copyWith(color: context.colors.textPrimary)),
                      SizedBox(height: context.space.s3),
                      Text(
                        KioskEnrollment.grouped(widget.code),
                        key: TabletExitCodeDialog.codeKey,
                        textAlign: TextAlign.center,
                        style: context.text.h1.copyWith(
                          color: context.colors.textPrimary,
                          // Цифры одной ширины (tnum) — код читается и переписывается без ошибок.
                          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                          letterSpacing: 4,
                        ),
                      ),
                      if (after.isNotEmpty) ...<Widget>[
                        SizedBox(height: context.space.s3),
                        Text(after, textAlign: TextAlign.center, style: body),
                      ],
                    ],
                  ),
                ),
              ),
              SizedBox(height: context.space.s4),
              Container(
                padding: EdgeInsets.all(context.space.s3),
                decoration: BoxDecoration(
                  color: context.colors.warningContainer,
                  borderRadius: BorderRadius.all(context.radii.md),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.lock_outline_rounded, size: 20, color: context.colors.warning),
                    SizedBox(width: context.space.s2),
                    Expanded(child: Text(l10n.kiosk_admin_exit_code_keep, style: body)),
                  ],
                ),
              ),
              SizedBox(height: context.space.s5),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AppButton(
                  key: TabletExitCodeDialog.doneKey,
                  label: l10n.ds_button_ok,
                  loading: _busy,
                  onPressed: () => unawaited(_done()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

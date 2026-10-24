// Секция «Устройства и сессии» SCR-42 (02 SCR-42.2–SCR-42.7; UI-42-013, UI-42-015…017; 09 §8.4).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/notifiers/settings_controllers.dart';
import 'package:optomstroy/features/settings/presentation/settings_texts.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

/// Ключи для тестов.
abstract final class SessionsSectionKeys {
  static const Key loading = ValueKey<String>('settings-sessions-loading');
  static const Key error = ValueKey<String>('settings-sessions-error');
  static const Key staleBanner = ValueKey<String>('settings-sessions-stale');
  static const Key logoutAll = ValueKey<String>('settings-logout-all');
  static const Key offlineHint = ValueKey<String>('settings-sessions-offline');
  static const Key renameField = ValueKey<String>('settings-session-rename-field');

  static Key row(String id) => ValueKey<String>('settings-session-$id');
  static Key revoke(String id) => ValueKey<String>('settings-session-revoke-$id');
  static Key rename(String id) => ValueKey<String>('settings-session-rename-$id');
  static Key logoutCurrent(String id) => ValueKey<String>('settings-session-logout-$id');
}

class SessionsSection extends ConsumerWidget {
  const SessionsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final SessionsViewState s = ref.watch(sessionsControllerProvider);
    final bool online = ref.watch(settingsOnlineProvider);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final SessionsController controller = ref.read(sessionsControllerProvider.notifier);

    if (!s.loaded && s.loading) {
      return Column(
        key: SessionsSectionKeys.loading,
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s1),
              child: const SkeletonBox(height: 72),
            ),
        ],
      );
    }
    if (!s.loaded && s.failure != null) {
      return ErrorState.inline(
        key: SessionsSectionKeys.error,
        message: SettingsTexts.sessionsLoadFailure(l10n, s.failure!),
        onRetry: () => unawaited(controller.refresh()),
        retrying: s.loading,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (s.stale)
          Padding(
            padding: EdgeInsets.only(bottom: context.space.s3),
            child: ErrorState.banner(
              key: SessionsSectionKeys.staleBanner,
              message: l10n.settings_sessions_stale_banner(SettingsTexts.dateTime(s.asOf!, locale)),
              tone: ErrorStateTone.warning,
              onRetry: () => unawaited(controller.refresh()),
              retrying: s.loading,
            ),
          ),
        for (final DeviceSession session in s.items)
          _SessionRow(session: session, busy: s.busy.contains(session.id), online: online, locale: locale),
        SizedBox(height: context.space.s6),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppButton(
            key: SessionsSectionKeys.logoutAll,
            label: l10n.profile_logout_all,
            variant: AppButtonVariant.danger,
            loading: s.loggingOutAll,
            onPressed: online ? () => unawaited(_logoutAll(context, ref)) : null,
          ),
        ),
        if (!online)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text(
              l10n.settings_offline_disabled,
              key: SessionsSectionKeys.offlineHint,
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
      ],
    );
  }

  Future<void> _logoutAll(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.profile_logout_all,
      message: l10n.profile_logout_all_confirm,
      confirmLabel: l10n.profile_logout_all,
      cancelLabel: l10n.ds_button_cancel,
      variant: ConfirmDialogVariant.destructive,
      destructiveCta: true,
    );
    if (!ok || !context.mounted) return;
    final Failure? failure = await ref.read(sessionsControllerProvider.notifier).logoutAll();
    if (!context.mounted) return;
    if (failure == null) {
      // Сессия завершена локально: роутер уводит на SCR-01 (стек очищается, 02 SCR-42.6).
      AppSnackbar.show(context, message: l10n.profile_logout_all_done, variant: AppSnackbarVariant.success);
    } else if (failure is! AuthFailure || failure.reason != AuthReason.stepUpRequired) {
      AppSnackbar.show(context, message: SettingsTexts.failure(l10n, failure), variant: AppSnackbarVariant.error);
    }
  }
}

class _SessionRow extends ConsumerWidget {
  const _SessionRow({required this.session, required this.busy, required this.online, required this.locale});

  final DeviceSession session;
  final bool busy;
  final bool online;
  final String locale;

  IconData get _icon => switch (session.platform) {
    DevicePlatform.windows => Icons.desktop_windows_outlined,
    DevicePlatform.ios || DevicePlatform.android => Icons.smartphone_rounded,
    null => Icons.devices_other_rounded,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool compact = context.windowClass == WindowClass.compact;
    final String title = session.deviceName ?? SettingsTexts.platform(session.platform);
    final DateTime? active = session.lastUsedAt ?? session.createdAt;
    final String subtitle = <String>[
      SettingsTexts.platform(session.platform),
      ?session.appVersion,
      if (active != null) l10n.settings_sessions_last_active(SettingsTexts.dateTime(active, locale)),
      ?session.ipMasked,
    ].join(' · ');

    final List<Widget> actions = <Widget>[
      AppIconButton(
        key: SessionsSectionKeys.rename(session.id),
        icon: Icons.edit_outlined,
        semanticLabel: l10n.settings_session_rename,
        tooltip: l10n.settings_session_rename,
        onPressed: online && !busy ? () => unawaited(_rename(context, ref)) : null,
      ),
      if (session.isCurrent)
        AppButton(
          key: SessionsSectionKeys.logoutCurrent(session.id),
          label: l10n.profile_logout,
          variant: AppButtonVariant.outlined,
          size: AppButtonSize.s,
          onPressed: () => unawaited(_logoutCurrent(context, ref)),
        )
      else
        AppButton(
          key: SessionsSectionKeys.revoke(session.id),
          label: l10n.settings_session_revoke,
          variant: AppButtonVariant.danger,
          size: AppButtonSize.s,
          loading: busy,
          onPressed: online && !busy ? () => unawaited(_revoke(context, ref, title)) : null,
        ),
    ];

    final Widget info = Row(
      children: <Widget>[
        Icon(_icon, size: 24, color: context.colors.textSecondary),
        SizedBox(width: context.space.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Wrap(
                spacing: context.space.s2,
                runSpacing: context.space.s1,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(title, style: context.text.bodyLg.copyWith(color: context.colors.textPrimary)),
                  if (session.isCurrent)
                    StatusChip(label: l10n.settings_sessions_this_device, variant: StatusChipVariant.info, dense: true),
                ],
              ),
              SizedBox(height: context.space.s1),
              Text(subtitle, style: context.text.caption.copyWith(color: context.colors.textSecondary)),
            ],
          ),
        ),
        if (!compact) ...<Widget>[SizedBox(width: context.space.s3), ...actions],
      ],
    );

    return Container(
      key: SessionsSectionKeys.row(session.id),
      constraints: const BoxConstraints(minHeight: 72),
      padding: EdgeInsets.symmetric(vertical: context.space.s3),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.border)),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                info,
                SizedBox(height: context.space.s2),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
              ],
            )
          : info,
    );
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref, String device) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.settings_session_revoke,
      message: l10n.settings_session_revoke_confirm(device),
      confirmLabel: l10n.settings_session_revoke,
      cancelLabel: l10n.ds_button_cancel,
      destructiveCta: true,
    );
    if (!ok || !context.mounted) return;
    final Failure? failure = await ref.read(sessionsControllerProvider.notifier).revoke(session.id);
    if (!context.mounted) return;
    if (failure == null) {
      AppSnackbar.show(context, message: l10n.settings_session_revoked, variant: AppSnackbarVariant.success);
    } else if (failure is! AuthFailure || failure.reason != AuthReason.stepUpRequired) {
      AppSnackbar.show(context, message: l10n.settings_session_revoke_error, variant: AppSnackbarVariant.error);
    }
  }

  Future<void> _logoutCurrent(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.profile_logout_confirm,
      message: l10n.profile_logout_confirm,
      confirmLabel: l10n.profile_logout,
      cancelLabel: l10n.ds_button_cancel,
    );
    if (!ok || !context.mounted) return;
    await ref.read(sessionsControllerProvider.notifier).logoutCurrent();
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _RenameDialog(initial: session.deviceName ?? ''),
    );
    if (name == null || !context.mounted) return;
    final Failure? failure = await ref.read(sessionsControllerProvider.notifier).rename(session.id, name);
    if (failure != null && context.mounted) {
      final AppLocalizations l10n = AppLocalizations.of(context);
      AppSnackbar.show(context, message: SettingsTexts.failure(l10n, failure), variant: AppSnackbarVariant.error);
    }
  }
}

/// Диалог «Переименовать» (UI-42-016): 1…60 символов без управляющих.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final String? name = DeviceNameRule.normalize(_text.text);
    if (name == null) {
      setState(() => _error = AppLocalizations.of(context).settings_device_name_error);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: context.colors.surface,
      title: Text(l10n.settings_session_rename, style: context.text.h3.copyWith(color: context.colors.textPrimary)),
      content: SizedBox(
        width: 360,
        child: AppTextField(
          key: SessionsSectionKeys.renameField,
          controller: _text,
          label: l10n.settings_session_rename,
          semanticLabel: l10n.settings_session_rename,
          errorText: _error,
          maxLength: DeviceNameRule.maxLength,
          autofocus: true,
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: <Widget>[
        AppButton(
          label: l10n.ds_button_cancel,
          variant: AppButtonVariant.text,
          onPressed: () => Navigator.of(context).pop(),
        ),
        AppButton(label: l10n.ds_button_apply, onPressed: _submit),
      ],
    );
  }
}

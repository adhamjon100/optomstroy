// SCR-07 «Аккаунт ожидает активации» (`/pending-activation`; только при CUSTOMER_SELF_SERVICE=false;
// 02 SCR-07; 09 §7.5). Свой номер показывается полностью (только память, из `GET /me`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/phone_number.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/registration/presentation/controllers/pending_activation_controller.dart';
import 'package:optomstroy/features/registration/presentation/widgets/registration_frame.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

class PendingActivationScreen extends ConsumerStatefulWidget {
  const PendingActivationScreen({super.key});

  static const Key screenKey = ValueKey<String>('scr07');
  static const Key checkKey = ValueKey<String>('scr07.check');
  static const Key logoutKey = ValueKey<String>('scr07.logout');
  static const Key statusKey = ValueKey<String>('scr07.status');

  @override
  ConsumerState<PendingActivationScreen> createState() => _PendingActivationScreenState();
}

class _PendingActivationScreenState extends ConsumerState<PendingActivationScreen> with WidgetsBindingObserver {
  Timer? _poll;
  bool _left = false;

  PendingActivationController get _ctrl => ref.read(pendingActivationProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_ctrl.autoCheck()));
    _poll = Timer.periodic(PendingActivationController.pollInterval, (_) => unawaited(_ctrl.autoCheck()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_ctrl.autoCheck());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _logout() async {
    final l10n = AppLocalizations.of(context);
    final ok = await ConfirmDialog.show(
      context,
      title: l10n.pending_logout_title,
      message: l10n.pending_logout_body,
      confirmLabel: l10n.pending_logout,
    );
    if (!ok || !mounted) return;
    await _ctrl.logout();
    if (mounted) ref.read(registrationNavigatorProvider).toPhone(context, RegistrationExitReason.loggedOut);
  }

  String _roleLabel(AppLocalizations l10n, List<String> roles) => roles
      .map(
        (r) => switch (r) {
          'seller' => l10n.role_seller,
          'cashier' => l10n.role_cashier,
          'admin' => l10n.role_admin,
          'customer' => l10n.role_customer,
          _ => r,
        },
      )
      .join(', ');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(pendingActivationProvider);
    ref.listen(pendingActivationProvider.select((v) => v.activated), (prev, activated) {
      if (activated && !(prev ?? false) && !_left) {
        _left = true;
        AppSnackbar.show(context, message: l10n.pending_activated_snackbar, variant: AppSnackbarVariant.success);
        ref.read(registrationNavigatorProvider).toHome(context);
      }
    });
    final c = context.colors;
    final account = s.account;
    final phone = account?.phone == null ? '—' : (PhoneNumber.tryParseE164(account!.phone!)?.grouped ?? account.phone!);
    final (chipLabel, chipVariant) = switch (s) {
      PendingActivationState(checking: true) => (l10n.pending_status_checking, StatusChipVariant.neutral),
      PendingActivationState(blocked: true) => (l10n.pending_status_blocked, StatusChipVariant.error),
      PendingActivationState(activated: true) => (
        l10n.pending_status_active(_roleLabel(l10n, account!.roles)),
        StatusChipVariant.success,
      ),
      _ => (l10n.pending_status_waiting, StatusChipVariant.warning),
    };
    // Время и дата — по часам магазина Asia/Bishkek (02 §0.1), не пояса машины.
    final checked = s.checkedAt;
    final checkedText = checked == null ? null : l10n.pending_checked_at(DsBishkekTime.time(checked));

    Widget row(String key, String value) => Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.s2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(key, style: context.text.label.copyWith(color: c.textSecondary)),
          ),
          Text(value, style: context.text.body.copyWith(fontWeight: FontWeight.w500)),
        ],
      ),
    );

    return PopScope(
      canPop: false,
      child: RegistrationFrame(
        screenKey: PendingActivationScreen.screenKey,
        largeRadius: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              s.blocked ? l10n.pending_blocked_title : l10n.pending_title,
              textAlign: TextAlign.center,
              style: context.text.h2,
            ),
            SizedBox(height: context.space.s2),
            if (s.blocked)
              ErrorState.banner(message: l10n.pending_blocked_body)
            else
              Text(
                l10n.pending_body,
                textAlign: TextAlign.center,
                style: context.text.body.copyWith(color: c.textSecondary),
              ),
            SizedBox(height: context.space.s6),
            row(l10n.pending_field_name, account?.fullName ?? '—'),
            row(l10n.pending_field_phone, phone),
            if (account?.registeredAt != null)
              row(l10n.pending_field_registered, DsBishkekTime.date(account!.registeredAt!)),
            SizedBox(height: context.space.s4),
            Wrap(
              spacing: context.space.s2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                StatusChip(key: PendingActivationScreen.statusKey, label: chipLabel, variant: chipVariant, dense: true),
                if (checkedText != null)
                  Text(checkedText, style: context.text.caption.copyWith(color: c.textSecondary)),
              ],
            ),
            if (s.checkError) ...<Widget>[
              SizedBox(height: context.space.s2),
              Text(l10n.pending_check_error, style: context.text.caption.copyWith(color: c.error)),
            ],
            SizedBox(height: context.space.s6),
            if (!s.blocked)
              AppButton(
                key: PendingActivationScreen.checkKey,
                label: l10n.pending_check,
                variant: AppButtonVariant.outlined,
                size: AppButtonSize.l,
                loading: s.checking,
                onPressed: s.checking ? null : () => unawaited(_ctrl.manualCheck()),
              ),
            AppButton(
              label: l10n.pending_contact_shop,
              variant: AppButtonVariant.text,
              onPressed: () => unawaited(
                AppBottomSheet.show<void>(
                  context,
                  title: l10n.pending_contact_shop,
                  body: Text(l10n.auth_support_fallback, style: context.text.body),
                ),
              ),
            ),
            AppButton(
              key: PendingActivationScreen.logoutKey,
              label: l10n.pending_logout,
              variant: AppButtonVariant.text,
              onPressed: () => unawaited(_logout()),
            ),
          ],
        ),
      ),
    );
  }
}

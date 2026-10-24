// SCR-06 «Привязка аккаунта к карточке клиента 1С» (`/register/customer-link`; R1 при CUSTOMER_SELF_SERVICE=true;
// 02 SCR-06). Показывается только маскированное наименование; без долгов, истории, скидок, ИНН, адреса.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/presentation/controllers/customer_link_controller.dart';
import 'package:optomstroy/features/registration/presentation/widgets/registration_frame.dart';
import 'package:optomstroy/features/registration/presentation/widgets/registration_stepper.dart';
import 'package:optomstroy/features/registration/presentation/widgets/success_check.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

class CustomerLinkScreen extends ConsumerStatefulWidget {
  const CustomerLinkScreen({super.key});

  static const Key screenKey = ValueKey<String>('scr06');
  static const Key confirmKey = ValueKey<String>('scr06.confirm');
  static const Key rejectKey = ValueKey<String>('scr06.reject');
  static const Key continueKey = ValueKey<String>('scr06.continue');
  static const Key cardKey = ValueKey<String>('scr06.card');
  static const Key waitAdminKey = ValueKey<String>('scr06.waitAdmin');
  static const Key successKey = ValueKey<String>('scr06.success');

  @override
  ConsumerState<CustomerLinkScreen> createState() => _CustomerLinkScreenState();
}

class _CustomerLinkScreenState extends ConsumerState<CustomerLinkScreen> {
  bool _left = false;

  CustomerLinkController get _ctrl => ref.read(customerLinkProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_ctrl.load()));
  }

  void _toHome() {
    if (_left || !mounted) return;
    _left = true;
    ref.read(registrationNavigatorProvider).toHome(context);
  }

  Future<void> _reject() async {
    final l10n = AppLocalizations.of(context);
    final ok = await ConfirmDialog.show(
      context,
      title: l10n.link_reject_title,
      message: l10n.link_reject_body,
      confirmLabel: l10n.link_reject,
    );
    if (ok) await _ctrl.reject();
  }

  Future<void> _contactShop() => AppBottomSheet.show<void>(
    context,
    title: AppLocalizations.of(context).link_contact_shop,
    body: Text(AppLocalizations.of(context).auth_support_fallback, style: context.text.body),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(customerLinkProvider);
    ref.listen(customerLinkProvider, (prev, next) {
      if (next.actionError && !(prev?.actionError ?? false)) {
        AppSnackbar.show(
          context,
          message: l10n.reg_error_network,
          variant: AppSnackbarVariant.error,
          actionLabel: l10n.ds_button_retry,
          onAction: () => unawaited(_ctrl.retry()),
        );
      }
      if (next.match.status == CustomerLinkStatus.rejected && prev?.match.status != CustomerLinkStatus.rejected) {
        _toHome();
      }
    });
    final compact = context.windowClass == WindowClass.compact;
    final selfService = ref.watch(customerSelfServiceProvider);

    final Widget body;
    if (s.phase == CustomerLinkPhase.loading) {
      body = Column(
        key: const ValueKey<String>('scr06.loading'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.link_searching, style: context.text.body),
          SizedBox(height: context.space.s4),
          const SkeletonBox(height: 48),
          SizedBox(height: context.space.s2),
          const SkeletonBox(height: 48),
        ],
      );
    } else if (s.phase == CustomerLinkPhase.loadError) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ErrorState.inline(message: l10n.reg_error_network, onRetry: () => unawaited(_ctrl.load())),
          SizedBox(height: context.space.s4),
          AppButton(key: CustomerLinkScreen.continueKey, label: l10n.reg_continue, onPressed: _toHome),
        ],
      );
    } else if (s.phase == CustomerLinkPhase.confirmed) {
      body = Column(
        key: CustomerLinkScreen.successKey,
        children: <Widget>[
          SuccessCheck(size: 72, onCompleted: () => Future<void>.delayed(const Duration(milliseconds: 400), _toHome)),
          SizedBox(height: context.space.s4),
          Semantics(liveRegion: true, child: Text(l10n.link_success, style: context.text.h2)),
        ],
      );
    } else {
      body = _decision(context, l10n, s, compact);
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: s.phase == CustomerLinkPhase.confirmed ? _toHome : null,
      child: PopScope(
        // Регистрация завершена: «Назад» не возвращает в неё (02 SCR-06.4).
        canPop: false,
        child: RegistrationFrame(
          screenKey: CustomerLinkScreen.screenKey,
          largeRadius: false,
          header: RegistrationHeader(title: l10n.profile_customer_link_title),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              RegistrationStepper(
                current: s.phase == CustomerLinkPhase.confirmed ? RegistrationStep.done : RegistrationStep.customerLink,
                withCustomerLink: selfService,
              ),
              SizedBox(height: context.space.s6),
              body,
            ],
          ),
        ),
      ),
    );
  }

  Widget _decision(BuildContext context, AppLocalizations l10n, CustomerLinkState s, bool compact) {
    final c = context.colors;
    final match = s.match;
    final (title, text) = switch (match.status) {
      CustomerLinkStatus.proposed when !s.waitAdmin => (l10n.link_title_found, l10n.link_body_found),
      CustomerLinkStatus.conflict => (l10n.link_title_conflict, l10n.link_body_conflict),
      CustomerLinkStatus.proposed => (l10n.link_title_found, l10n.link_wait_admin),
      _ => (l10n.link_title_none, l10n.link_body_none),
    };
    final showCard = match.status == CustomerLinkStatus.proposed && match.shownName != null;
    final confirm = AppButton(
      key: CustomerLinkScreen.confirmKey,
      label: l10n.link_confirm,
      size: AppButtonSize.l,
      expand: compact,
      autofocus: true,
      loading: s.phase == CustomerLinkPhase.confirming,
      onPressed: s.busy ? null : () => unawaited(_ctrl.confirm()),
    );
    final reject = AppButton(
      key: CustomerLinkScreen.rejectKey,
      label: l10n.link_reject,
      variant: AppButtonVariant.outlined,
      size: AppButtonSize.l,
      expand: compact,
      loading: s.phase == CustomerLinkPhase.rejecting,
      onPressed: s.busy ? null : () => unawaited(_reject()),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(title, style: compact ? context.text.h2 : context.text.h1),
        SizedBox(height: context.space.s2),
        Text(text, style: context.text.body.copyWith(color: c.textSecondary)),
        SizedBox(height: context.space.s6),
        if (showCard) ...<Widget>[
          Container(
            key: CustomerLinkScreen.cardKey,
            padding: EdgeInsets.all(context.space.s4),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.all(context.radii.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(match.shownName ?? '', style: context.text.title),
                SizedBox(height: context.space.s2),
                StatusChip(
                  label: l10n.reg_phone_verified,
                  variant: StatusChipVariant.success,
                  icon: Icons.check_rounded,
                  dense: true,
                ),
              ],
            ),
          ),
          SizedBox(height: context.space.s3),
          Text(l10n.link_finance_hidden, style: context.text.caption.copyWith(color: c.textSecondary)),
          SizedBox(height: context.space.s6),
        ],
        if (s.waitAdmin && match.status == CustomerLinkStatus.proposed) ...<Widget>[
          ErrorState.banner(
            key: CustomerLinkScreen.waitAdminKey,
            message: l10n.link_wait_admin,
            tone: ErrorStateTone.info,
          ),
          SizedBox(height: context.space.s4),
        ],
        if (s.canDecide)
          compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    confirm,
                    SizedBox(height: context.space.s3),
                    reject,
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    reject,
                    SizedBox(width: context.space.s3),
                    confirm,
                  ],
                )
        else
          AppButton(
            key: CustomerLinkScreen.continueKey,
            label: l10n.reg_continue,
            size: AppButtonSize.l,
            expand: compact,
            onPressed: _toHome,
          ),
        SizedBox(height: context.space.s2),
        AppButton(
          label: l10n.link_contact_shop,
          variant: AppButtonVariant.text,
          onPressed: () => unawaited(_contactShop()),
        ),
      ],
    );
  }
}

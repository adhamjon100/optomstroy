// SCR-26 «Новый клиент» (`/customers/new?returnTo=checkout`; seller, cashier, senior_seller, admin; дедупликация по
// 1С — `409 CUSTOMER_DUPLICATE_SUSPECTED`). RM-F-006, RM-D-005; 02 SCR-26.
//
// Результат экрана — ID клиента (`Navigator.pop(customerId)`): созданного или выбранного среди найденных дублей;
// SCR-21 сразу выбирает его (`POST /cart/customer`). expanded/medium — диалог 560–640 lp; compact — полный экран.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/customer_card.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/customers/domain/entities/new_customer.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart' show customerNewPrefillProvider;
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart';

/// SCR-26.
class NewCustomerScreen extends ConsumerStatefulWidget {
  /// Экран SCR-26.
  const NewCustomerScreen({this.returnTo, super.key});

  /// Куда вернуться после создания (`checkout` — на SCR-21 с выбранным клиентом).
  final String? returnTo;

  /// Ключ заглушки (тесты маршрутов): `stub-SCR-26`.
  static const ValueKey<String> stubKey = ValueKey<String>('stub-SCR-26');

  /// Ключ «Создать клиента».
  static const ValueKey<String> createKey = ValueKey<String>('customer-new-create');

  /// Баннер UI-26-016 «Проверка в 1С сейчас недоступна — возможен дубль» (ответ `201` с `STALE_DATA`).
  static const ValueKey<String> onecCheckSkippedKey = ValueKey<String>('customer-new-stale');

  @override
  ConsumerState<NewCustomerScreen> createState() => _NewCustomerScreenState();
}

class _NewCustomerScreenState extends ConsumerState<NewCustomerScreen> {
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _inn = TextEditingController();
  final TextEditingController _address = TextEditingController();
  final TextEditingController _comment = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  final FocusNode _reasonFocus = FocusNode(debugLabel: 'customer-new-reason');
  bool _showAll = false;

  NewCustomerController get _ctl => ref.read(newCustomerControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Номер из строки поиска SCR-31 (UI-31-005): только память процесса, одноразово (аналог `extra`, N-3) — в URL,
    // логи роутера и `lastLocation` не попадает; после перезапуска поле пустое.
    final String? prefill = ref.read(customerNewPrefillProvider).take();
    final String? national = prefill == null ? null : DsPhoneFormat.nationalDigits(prefill);
    if (national != null && national.length == DsPhoneFormat.nationalLength) {
      _phone.text = DsPhoneFormat.groupNational(national);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ctl.setPhone(DsPhoneFormat.normalize(national));
      });
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    _inn.dispose();
    _address.dispose();
    _comment.dispose();
    _reason.dispose();
    _reasonFocus.dispose();
    super.dispose();
  }

  void _finish(String customerId, {bool created = false}) {
    if (created) {
      AppSnackbar.show(
        context,
        message: AppLocalizations.of(context).customer_new_created_snackbar,
        variant: AppSnackbarVariant.success,
      );
    }
    _pop(customerId);
  }

  /// Закрыть экран с результатом [customerId]. SCR-26 открывается `push` из корневого маршрута (SCR-21 `/checkout`)
  /// поверх оболочки: `Navigator.of(context)` — навигатор ветки «Клиенты», и его `pop` не завершает `push` вызвавшего
  /// экрана (клиент не выбирался в заказе). Поэтому — `GoRouter.pop` (верхний маршрут графа); без go_router (тесты
  /// экрана) — ближайший `Navigator`.
  void _pop([String? customerId]) {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router != null && router.canPop()) {
      router.pop(customerId);
    } else {
      Navigator.of(context).pop(customerId);
    }
  }

  Future<void> _close() async {
    final NewCustomerState now = ref.read(newCustomerControllerProvider);
    if (now.creating) return;
    // Клиент уже создан (ответ с `STALE_DATA` оставил экран открытым, UI-26-016) — закрытие возвращает его.
    final String? created = now.createdId;
    if (created != null) {
      _finish(created, created: true);
      return;
    }
    if (_ctl.isDirty() || _phone.text.isNotEmpty) {
      final AppLocalizations l10n = AppLocalizations.of(context);
      final bool abort = await ConfirmDialog.show(
        context,
        title: l10n.customer_new_abort_title,
        message: l10n.customer_new_abort_body,
        confirmLabel: l10n.customer_new_abort_confirm,
        cancelLabel: l10n.ds_button_cancel,
      );
      if (!abort || !mounted) return;
    }
    _pop();
  }

  Future<void> _create() async {
    final bool online = ref.read(newCustomerOnlineProvider);
    if (!_ctl.canCreate(online: online)) {
      if (online) await _ctl.create();
      return;
    }
    await _ctl.create();
  }

  @override
  Widget build(BuildContext context) {
    final NewCustomerState s = ref.watch(newCustomerControllerProvider);
    final bool online = ref.watch(newCustomerOnlineProvider);
    ref.listen<String?>(newCustomerControllerProvider.select((NewCustomerState x) => x.createdId), (
      String? prev,
      String? next,
    ) {
      // `STALE_DATA` (UI-26-016): экран остаётся с баннером, результат — при закрытии ([_close]).
      final bool stale = ref.read(newCustomerControllerProvider).onecCheckSkippedAt != null;
      if (next != null && prev == null && !stale) _finish(next, created: true);
    });
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final WindowClass wc = context.windowClass;
    final Map<NewCustomerField, NewCustomerFieldError> errors = s.showErrors
        ? _ctl.errors()
        : const <NewCustomerField, NewCustomerFieldError>{};
    String? err(NewCustomerField f) => switch (errors[f]) {
      NewCustomerFieldError.phoneInvalid => l10n.customer_new_phone_invalid,
      NewCustomerFieldError.nameRequired => l10n.customer_new_name_required,
      NewCustomerFieldError.innInvalid => l10n.customer_new_inn_invalid,
      NewCustomerFieldError.forceReasonRequired => l10n.customer_new_force_reason_required,
      null => null,
    };
    final bool wide = wc != WindowClass.compact;
    final Widget phone = PhoneField(
      key: const ValueKey<String>('customer-new-phone'),
      controller: _phone,
      autofocus: true,
      label: l10n.customer_new_phone_label,
      semanticLabel: l10n.customer_new_phone_label,
      loading: s.check == DuplicateCheck.checking,
      enabled: !s.creating,
      errorText: err(NewCustomerField.phone),
      onChanged: _ctl.setPhone,
    );
    final Widget type = Wrap(
      spacing: 24,
      children: <Widget>[
        for (final (CustomerType t, String label) in <(CustomerType, String)>[
          (CustomerType.individual, l10n.customer_new_type_individual),
          (CustomerType.entrepreneur, l10n.customer_new_type_entrepreneur),
          (CustomerType.legal, l10n.customer_new_type_legal),
        ])
          IntrinsicWidth(
            child: AppRadio<CustomerType>(
              key: ValueKey<String>('customer-new-type-${t.value}'),
              value: t,
              groupValue: s.type,
              label: label,
              onChanged: s.creating ? null : _ctl.setType,
            ),
          ),
      ],
    );
    final List<Widget> fields = <Widget>[
      if (wide)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: phone),
            const SizedBox(width: 16),
            Expanded(child: type),
          ],
        )
      else
        phone,
      _checkStatus(context, l10n, s),
      RevealSize(
        child: s.onecCheckSkippedAt == null
            ? const SizedBox.shrink()
            : Padding(
                padding: EdgeInsets.only(top: context.space.s3),
                child: ErrorState.banner(
                  key: NewCustomerScreen.onecCheckSkippedKey,
                  message: l10n.customer_new_stale_check(_hhmm(s.onecCheckSkippedAt!)),
                  tone: ErrorStateTone.warning,
                ),
              ),
      ),
      const SizedBox(height: 12),
      AppTextField(
        key: const ValueKey<String>('customer-new-name'),
        controller: _name,
        label: l10n.customer_new_name_label,
        maxLength: NewCustomerRequest.nameMax,
        enabled: !s.creating,
        errorText: err(NewCustomerField.name),
        onChanged: _ctl.setName,
      ),
      if (!wide) ...<Widget>[const SizedBox(height: 12), type],
      RevealSize(
        child: s.innVisible
            ? Padding(
                padding: EdgeInsets.only(top: context.space.s3),
                child: AppTextField(
                  key: const ValueKey<String>('customer-new-inn'),
                  controller: _inn,
                  label: l10n.customer_new_inn_label,
                  variant: AppTextFieldVariant.number,
                  loading: s.innCheck == DuplicateCheck.checking,
                  enabled: !s.creating,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(14),
                  ],
                  errorText: err(NewCustomerField.inn),
                  onChanged: _ctl.setInn,
                ),
              )
            : const SizedBox(width: double.infinity), // money-double: allow — геометрия UI (ширина окна), не деньги
      ),
      const SizedBox(height: 12),
      AppTextField(
        key: const ValueKey<String>('customer-new-address'),
        controller: _address,
        label: l10n.customer_new_address_label,
        variant: AppTextFieldVariant.multiline,
        maxLength: NewCustomerRequest.addressMax,
        enabled: !s.creating,
        onChanged: _ctl.setAddress,
      ),
      const SizedBox(height: 12),
      AppTextField(
        key: const ValueKey<String>('customer-new-comment'),
        controller: _comment,
        label: l10n.customer_new_comment_label,
        variant: AppTextFieldVariant.multiline,
        enabled: !s.creating,
        inputFormatters: <TextInputFormatter>[LengthLimitingTextInputFormatter(NewCustomerRequest.commentMax)],
        onChanged: _ctl.setComment,
      ),
      Align(
        alignment: Alignment.centerRight,
        child: Text(
          l10n.customer_new_comment_counter(s.comment.characters.length),
          style: context.text.caption.copyWith(color: c.textSecondary),
        ),
      ),
      const SizedBox(height: 12),
      ErrorState.banner(message: l10n.customer_new_onec_note, tone: ErrorStateTone.info),
      if (!online) ...<Widget>[
        const SizedBox(height: 12),
        ErrorState.banner(
          key: const ValueKey<String>('customer-new-offline'),
          message: l10n.customer_new_offline,
          tone: ErrorStateTone.warning,
        ),
      ],
      if (s.createFailure != null && s.createFailure is! ValidationFailure) ...<Widget>[
        const SizedBox(height: 12),
        ErrorState.banner(
          key: const ValueKey<String>('customer-new-error'),
          message: s.createFailure is NetworkFailure
              ? l10n.customer_new_create_failed
              : ErrorTexts.message(l10n, UiErrorMapper.fromFailure(s.createFailure!)),
          onRetry: s.createFailure is NetworkFailure ? () => unawaited(_create()) : null,
        ),
      ],
    ];
    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(context.space.s6, context.space.s3, context.space.s3, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(l10n.customer_new_title, style: context.text.h3.copyWith(color: c.textPrimary)),
            ),
          ),
          AppIconButton(
            key: const ValueKey<String>('customer-new-close'),
            icon: Icons.close_rounded,
            semanticLabel: l10n.ds_button_close,
            onPressed: s.creating ? null : () => unawaited(_close()),
          ),
        ],
      ),
    );
    final Widget footer = Container(
      padding: EdgeInsets.fromLTRB(
        wide ? 24 : context.space.s4,
        context.space.s3,
        wide ? 24 : context.space.s4,
        context.space.s3,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: <Widget>[
          _flex(
            wide,
            2,
            AppButton(
              key: const ValueKey<String>('customer-new-cancel'),
              label: l10n.ds_button_cancel,
              variant: AppButtonVariant.outlined,
              size: AppButtonSize.l,
              expand: !wide,
              onPressed: s.creating ? null : () => unawaited(_close()),
            ),
          ),
          if (wide) const Spacer() else const SizedBox(width: 12),
          _flex(
            wide,
            3,
            AppButton(
              key: NewCustomerScreen.createKey,
              label: l10n.customer_new_create,
              size: AppButtonSize.l,
              expand: !wide,
              loading: s.creating,
              onPressed: _ctl.canCreate(online: online) ? () => unawaited(_create()) : null,
            ),
          ),
        ],
      ),
    );
    final Widget content = Column(
      mainAxisSize: wide ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        Flexible(
          fit: wide ? FlexFit.loose : FlexFit.tight,
          child: SingleChildScrollView(
            padding: EdgeInsets.all(context.space.s6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: fields),
          ),
        ),
        footer,
      ],
    );
    final Widget screen = wide
        ? Scaffold(
            key: const ValueKey<String>('customer-new-screen'),
            backgroundColor: c.background,
            body: ColoredBox(
              color: c.overlay,
              child: Center(
                child: Container(
                  width: wc == WindowClass.medium ? 560 : 640,
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.all(context.radii.lg),
                    boxShadow: context.elevation.e3,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: content,
                ),
              ),
            ),
          )
        : Scaffold(
            key: const ValueKey<String>('customer-new-screen'),
            backgroundColor: c.surface,
            resizeToAvoidBottomInset: true,
            body: SafeArea(child: content),
          );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) unawaited(_close());
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () => unawaited(_close()),
        },
        child: screen,
      ),
    );
  }

  static Widget _flex(bool wide, int flex, Widget child) => wide ? child : Expanded(flex: flex, child: child);

  Widget _checkStatus(BuildContext context, AppLocalizations l10n, NewCustomerState s) {
    final DsColors c = context.colors;
    final bool anyFound = s.check == DuplicateCheck.found || s.innCheck == DuplicateCheck.found;
    if (s.check == DuplicateCheck.checking) {
      return Padding(
        padding: EdgeInsets.only(top: context.space.s2),
        child: Row(
          children: <Widget>[
            const AppProgress.circular(size: 16),
            const SizedBox(width: 8),
            Text(l10n.customer_new_checking, style: context.text.caption.copyWith(color: c.textSecondary)),
          ],
        ),
      );
    }
    if (s.check == DuplicateCheck.error) {
      return Padding(
        key: const ValueKey<String>('customer-new-check-error'),
        padding: EdgeInsets.only(top: context.space.s2),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: context.space.s3, vertical: context.space.s1),
          decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.all(context.radii.sm)),
          child: Row(
            children: <Widget>[
              Icon(Icons.error_outline_rounded, size: 20, color: c.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(l10n.customer_new_check_failed, style: context.text.body.copyWith(color: c.error)),
              ),
              AppButton(
                key: const ValueKey<String>('customer-new-check-retry'),
                label: l10n.customer_new_check_retry,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                onPressed: () => unawaited(_ctl.checkPhone()),
              ),
            ],
          ),
        ),
      );
    }
    if (s.check == DuplicateCheck.clear && !anyFound) {
      return Padding(
        key: const ValueKey<String>('customer-new-no-duplicates'),
        padding: EdgeInsets.only(top: context.space.s2),
        child: Row(
          children: <Widget>[
            Icon(Icons.check_circle_rounded, size: 16, color: c.success),
            const SizedBox(width: 6),
            Text(l10n.customer_new_no_duplicates, style: context.text.caption.copyWith(color: c.success)),
          ],
        ),
      );
    }
    if (!anyFound || s.candidates.isEmpty) return const SizedBox.shrink();
    final bool byInn = s.candidates.every((DuplicateView d) => d.byInn);
    final List<DuplicateView> shown = _showAll ? s.candidates : s.candidates.take(3).toList();
    return Container(
      key: const ValueKey<String>('customer-new-duplicates'),
      margin: EdgeInsets.only(top: context.space.s3),
      padding: EdgeInsets.all(context.space.s3),
      decoration: BoxDecoration(color: c.warningContainer, borderRadius: BorderRadius.all(context.radii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Text(
              byInn ? l10n.customer_new_duplicate_inn_title : l10n.customer_new_duplicate_title,
              style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.warning),
            ),
          ),
          for (final DuplicateView d in shown) ...<Widget>[
            const SizedBox(height: 8),
            CustomerCard.compact(name: d.name, phone: d.phone),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                key: ValueKey<String>('customer-new-use-${d.id}'),
                label: l10n.customer_new_use_existing,
                onPressed: s.creating ? null : () => _finish(d.id),
              ),
            ),
          ],
          if (!_showAll && s.candidates.length > 3)
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                label: l10n.customer_new_show_more(s.candidates.length - 3),
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                onPressed: () => setState(() => _showAll = true),
              ),
            ),
          const SizedBox(height: 8),
          if (s.canForce && !s.force)
            Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: l10n.customer_new_force_tooltip,
                child: AppButton(
                  key: const ValueKey<String>('customer-new-force'),
                  label: l10n.customer_new_force_create,
                  variant: AppButtonVariant.text,
                  onPressed: () {
                    _ctl.startForce();
                    _reasonFocus.requestFocus();
                  },
                ),
              ),
            )
          else if (!s.canForce)
            Text(
              l10n.customer_new_seller_duplicate_hint,
              key: const ValueKey<String>('customer-new-seller-hint'),
              style: context.text.caption.copyWith(color: c.textSecondary),
            ),
          if (s.force)
            AppTextField(
              key: const ValueKey<String>('customer-new-force-reason'),
              controller: _reason,
              focusNode: _reasonFocus,
              label: l10n.customer_new_force_reason_label,
              maxLength: NewCustomerRequest.forceReasonMax,
              errorText: s.showErrors && s.forceReason.trim().length < NewCustomerRequest.forceReasonMin
                  ? l10n.customer_new_force_reason_required
                  : null,
              onChanged: _ctl.setForceReason,
            ),
        ],
      ),
    );
  }
}

/// `HH:mm` по часам магазина Asia/Bishkek (02 §0.1).
String _hhmm(DateTime at) => DsBishkekTime.time(at);

/// Раскрытие поля (ANIM-020); при reduce-motion — мгновенно.
class RevealSize extends StatelessWidget {
  const RevealSize({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Duration d = context.motion.of(context.motion.base);
    if (d == Duration.zero) return child;
    return AnimatedSize(duration: d, alignment: Alignment.topCenter, curve: context.motion.standard, child: child);
  }
}

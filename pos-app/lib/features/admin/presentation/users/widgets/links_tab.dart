// Вкладка «Привязки клиентов» (UI-45-017, UI-45-018; D-08; 09 §7.9; ядро §19.2, §19.3, §22.12).
// Только `admin`. «Подтвердить»/«Отклонить» — ConfirmDialog (комментарий) → step-up
// `customer.link.resolve` (AC-UI-45-017); `409 CUSTOMER_LINK_CONFLICT` → баннер `admin_links_error_conflict`.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/domain/users/customer_link_case.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_controller.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_actions.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';

class LinksTab extends ConsumerWidget {
  const LinksTab({super.key});

  static Future<void> openPanel(BuildContext context, String customerId) {
    final panel = LinkCasePanel(customerId: customerId);
    if (DsBreakpoints.of(context) == WindowClass.compact) {
      return AppBottomSheet.show<void>(context, body: panel, variant: AppBottomSheetVariant.fullHeight);
    }
    return AppBottomSheet.showSide<void>(context, body: panel, width: AppBottomSheet.sideExpanded);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final slice = ref.watch(adminUsersControllerProvider.select((s) => s.links));
    if (slice.loading && slice.items.isEmpty) {
      return ListView(
        children: [for (var i = 0; i < 4; i++) const Padding(padding: EdgeInsets.all(16), child: SkeletonBox.text())],
      );
    }
    if (slice.failure != null && slice.items.isEmpty) {
      return Center(
        child: ErrorState.inline(
          message: AdminFailureText.of(l10n, slice.failure!),
          onRetry: () => unawaited(ref.read(adminUsersControllerProvider.notifier).reloadLinks()),
        ),
      );
    }
    if (slice.items.isEmpty) {
      return EmptyState(variant: EmptyStateVariant.customers, title: l10n.admin_links_empty);
    }
    return ListView.separated(
      key: const ValueKey<String>('admin-links-list'),
      itemCount: slice.items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final item = slice.items[i];
        final status = item.hasConflict ? 'conflict' : (item.links.firstOrNull?.status ?? 'proposed');
        return AppListTile(
          key: ValueKey<String>('admin-link-case-${item.customerId}'),
          title: item.title,
          subtitle: item.links.map((l) => l.userDisplayName ?? '—').join(', '),
          leadingIcon: Icons.person_search_rounded,
          showChevron: true,
          trailing: StatusChip(
            label: AdminLabels.linkStatus(l10n, status),
            variant: AdminLabels.linkStatusVariant(status),
          ),
          onTap: () => unawaited(openPanel(context, item.customerId)),
        );
      },
    );
  }
}

/// Панель разрешения привязки (UI-45-018).
class LinkCasePanel extends ConsumerStatefulWidget {
  const LinkCasePanel({super.key, required this.customerId});

  final String customerId;

  @override
  ConsumerState<LinkCasePanel> createState() => _LinkCasePanelState();
}

class _LinkCasePanelState extends ConsumerState<LinkCasePanel> {
  bool _conflict = false;

  AdminUsersController get _controller => ref.read(adminUsersControllerProvider.notifier);

  Future<void> _resolve(CustomerLinkCandidate link, {required bool confirm}) async {
    final l10n = AppLocalizations.of(context);
    final key = newIdempotencyKey();
    final obtain = adminStepUpObtainer(context, ref);
    final result = await confirmAndRun<CustomerLinkCandidate>(
      context,
      title: confirm ? l10n.admin_links_confirm : l10n.admin_links_reject,
      message: '${link.userDisplayName ?? '—'} ${link.userPhoneMasked ?? ''}'.trim(),
      confirmLabel: confirm ? l10n.admin_links_confirm : l10n.admin_links_reject,
      destructiveCta: !confirm,
      run: (comment) => confirm
          ? _controller.confirmLink(link, comment: comment, idempotencyKey: key, obtain: obtain)
          : _controller.rejectLink(link, comment: comment, idempotencyKey: key, obtain: obtain),
    );
    if (!mounted || result == null) return;
    _handle(result);
  }

  void _handle(AdminActionResult<CustomerLinkCandidate> result) {
    final failure = result.failureOrNull;
    if (failure is ConflictFailure && failure.kind == ConflictKind.customerLinkConflict) {
      setState(() => _conflict = true);
      return;
    }
    if (result is ActionFailed<CustomerLinkCandidate>) {
      showAdminFailure(context, result, kind: AdminFailureContext.links);
    }
  }

  /// «Отклонить все»: `reject` для каждой открытой связи (одна причина, отдельные ключи).
  Future<void> _rejectAll(CustomerLinkCase item) async {
    final l10n = AppLocalizations.of(context);
    final obtain = adminStepUpObtainer(context, ref);
    final open = item.links.where((l) => l.isOpen).toList();
    final keys = {for (final l in open) l.id: newIdempotencyKey()};
    final result = await confirmAndRun<CustomerLinkCandidate>(
      context,
      title: l10n.admin_links_reject_all,
      message: item.title,
      confirmLabel: l10n.admin_links_reject_all,
      destructiveCta: true,
      run: (comment) async {
        AdminActionResult<CustomerLinkCandidate> last = const ActionCancelled();
        for (final link in open) {
          last = await _controller.rejectLink(link, comment: comment, idempotencyKey: keys[link.id]!, obtain: obtain);
          if (last is! ActionDone<CustomerLinkCandidate>) return last;
        }
        return last;
      },
    );
    if (!mounted || result == null) return;
    _handle(result);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final item = ref.watch(
      adminUsersControllerProvider.select(
        (s) => s.links.items.where((i) => i.customerId == widget.customerId).firstOrNull,
      ),
    );
    if (item == null) return const SizedBox.shrink();
    final caption = context.text.caption.copyWith(color: c.textSecondary);
    return Padding(
      key: ValueKey<String>('admin-link-panel-${item.customerId}'),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_conflict) ...[
            ErrorState.banner(message: l10n.admin_links_error_conflict, tone: ErrorStateTone.warning),
            const SizedBox(height: 12),
          ],
          Text(item.title, style: context.text.h3.copyWith(color: c.textPrimary)),
          if (item.inn != null) Text(l10n.customer_card_inn(item.inn!), style: caption),
          for (final p in item.phones) Text(DsPhoneFormat.display(p), style: caption),
          const SizedBox(height: 12),
          Text(l10n.customer_card_links_title, style: context.text.title.copyWith(color: c.textPrimary)),
          const SizedBox(height: 8),
          for (final link in item.links)
            Padding(
              key: ValueKey<String>('admin-link-${link.id}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${link.userDisplayName ?? '—'} ${link.userPhoneMasked ?? ''}'.trim(),
                          style: context.text.body.copyWith(color: c.textPrimary),
                        ),
                      ),
                      StatusChip(
                        label: AdminLabels.linkStatus(l10n, link.status),
                        variant: AdminLabels.linkStatusVariant(link.status),
                      ),
                    ],
                  ),
                  if (link.isOpen) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        AppButton(
                          key: ValueKey<String>('admin-link-confirm-${link.id}'),
                          label: l10n.admin_links_confirm,
                          size: AppButtonSize.s,
                          onPressed: () => unawaited(_resolve(link, confirm: true)),
                        ),
                        AppButton(
                          key: ValueKey<String>('admin-link-reject-${link.id}'),
                          label: l10n.admin_links_reject,
                          variant: AppButtonVariant.outlined,
                          size: AppButtonSize.s,
                          onPressed: () => unawaited(_resolve(link, confirm: false)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          if (item.links.where((l) => l.isOpen).length > 1) ...[
            const SizedBox(height: 8),
            AppButton(
              key: const ValueKey<String>('admin-link-reject-all'),
              label: l10n.admin_links_reject_all,
              variant: AppButtonVariant.danger,
              size: AppButtonSize.s,
              onPressed: () => unawaited(_rejectAll(item)),
            ),
          ],
        ],
      ),
    );
  }
}

// Тексты ошибок SCR-45 (02 SCR-45.8): машинный код → ключ ARB; повторяемость ошибок.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('ru'));
  String t(Failure f, [AdminFailureContext c = AdminFailureContext.generic]) =>
      AdminFailureText.of(l10n, f, context: c);

  test('сеть', () {
    expect(t(const NetworkFailure(NetworkFailureKind.offline)), l10n.stepup_offline);
    expect(t(const NetworkFailure(NetworkFailureKind.timeout)), l10n.ds_server_down);
  });

  test('403 FORBIDDEN по причинам', () {
    expect(
      t(const PermissionFailure(serverReason: 'owner_role_reserved'), AdminFailureContext.roles),
      l10n.admin_users_owner_hint,
    );
    expect(
      t(const PermissionFailure(serverReason: 'self_target'), AdminFailureContext.block),
      l10n.admin_users_error_self_block,
    );
    expect(
      t(const PermissionFailure(serverReason: 'self_target'), AdminFailureContext.roles),
      l10n.admin_users_error_self_demotion,
    );
    expect(t(const PermissionFailure()), l10n.error_forbidden);
  });

  test('VALIDATION_FAILED: self_demotion, self_block, аварийный код, телефон приглашения', () {
    expect(
      t(
        const ValidationFailure(
          errors: [FieldError(field: 'roles', rule: 'self_demotion')],
        ),
      ),
      l10n.admin_users_error_self_demotion,
    );
    expect(
      t(
        const ValidationFailure(
          errors: [FieldError(field: 'id', rule: 'self_block')],
        ),
      ),
      l10n.admin_users_error_self_block,
    );
    expect(t(const ValidationFailure(), AdminFailureContext.emergencyCode), l10n.admin_users_emergency_not_allowed);
    expect(
      t(
        const ValidationFailure(
          errors: [FieldError(field: 'phone', rule: 'phone_e164')],
        ),
        AdminFailureContext.invitation,
      ),
      l10n.admin_invites_error_phone,
    );
    expect(t(const ValidationFailure()), l10n.error_internal);
  });

  test('409 конфликты', () {
    expect(t(const ConflictFailure(ConflictKind.versionConflict)), l10n.admin_users_conflict_banner);
    expect(t(const ConflictFailure(ConflictKind.phoneAlreadyRegistered)), l10n.admin_invites_error_registered);
    // FA-07: номер клиента (`reason: customer_account`) — отдельный текст (03 §16.7).
    expect(
      t(const ConflictFailure(ConflictKind.phoneAlreadyRegistered, reason: 'customer_account')),
      l10n.admin_invites_error_customer_account,
    );
    expect(t(const ConflictFailure(ConflictKind.customerLinkConflict)), l10n.admin_links_error_conflict);
    expect(t(const ConflictFailure(ConflictKind.idempotencyInProgress)), l10n.error_idempotency_in_progress);
  });

  test('429, 404, step-up, прочее', () {
    expect(
      t(const ServerFailure(code: 'RATE_LIMITED', status: 429), AdminFailureContext.emergencyCode),
      l10n.admin_users_emergency_rate_limited,
    );
    expect(
      t(const ServerFailure(code: 'RATE_LIMITED', status: 429, retryAfter: Duration(seconds: 30))),
      l10n.error_rate_limited(30),
    );
    expect(t(const ServerFailure(code: 'NOT_FOUND', status: 404)), l10n.error_not_found);
    expect(t(const AuthFailure(AuthReason.stepUpRequired)), l10n.error_step_up_required);
    expect(t(const UnknownFailure()), l10n.error_internal);
    expect(t(const OnecUnavailableFailure()), l10n.error_onec_unavailable);
  });

  test('повторяемые ошибки оставляют диалог подтверждения открытым', () {
    expect(AdminFailureText.isTransient(const NetworkFailure(NetworkFailureKind.offline)), isTrue);
    expect(AdminFailureText.isTransient(const ServerFailure(code: 'INTERNAL', status: 500)), isTrue);
    expect(AdminFailureText.isTransient(const ConflictFailure(ConflictKind.idempotencyInProgress)), isTrue);
    expect(AdminFailureText.isTransient(const PermissionFailure()), isFalse);
    expect(AdminFailureText.isTransient(const ConflictFailure(ConflictKind.versionConflict)), isFalse);
  });
}

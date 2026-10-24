import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';

/// Статус заявки на возврат (02 SCR-39 UI-39-007; 10 RET-007, ядро §22.11) — `StatusChip` по таблице 03 §9.39
/// (`return_request_status`: draft neutral · submitted info · accepted success · rejected error · completed success).
///
/// Подписи 03 §9.39 (`status_return_<code>`) в словаре 02 §7 / ARB отсутствуют (GQ-FERET-01). До их появления
/// подпись берётся из ключей SCR-39 с тем же смыслом (только ARB, D-38): `draft` — «Черновик сохранён»,
/// `submitted` — «Заявка отправлена в 1С», `accepted` — «Заявка согласована», `rejected` — «Заявка отклонена»,
/// `completed` — «Возвращён» (`status_payment_refunded`). Замена — только в [labelOf].
class ReturnStatusChip extends StatelessWidget {
  /// Создаёт чип статуса заявки.
  const ReturnStatusChip({super.key, required this.status, this.dense = false});

  /// Статус заявки.
  final ReturnRequestStatus status;

  /// Высота 20.
  final bool dense;

  /// Подпись статуса (временная, см. описание класса).
  static String labelOf(AppLocalizations l10n, ReturnRequestStatus status) => switch (status) {
    ReturnRequestStatus.draft => l10n.return_draft_saved,
    ReturnRequestStatus.submitted => l10n.return_submitted,
    ReturnRequestStatus.accepted => l10n.return_accepted,
    ReturnRequestStatus.rejected => l10n.return_rejected_done,
    ReturnRequestStatus.completed => l10n.status_payment_refunded,
  };

  /// Вариант по таблице 03 §9.39 (`return.<значение>`).
  static StatusChipVariant variantOf(ReturnRequestStatus status) =>
      StatusChipMapping.variantOf('return', status.value) ?? StatusChipVariant.neutral;

  @override
  Widget build(BuildContext context) =>
      StatusChip(label: labelOf(AppLocalizations.of(context), status), variant: variantOf(status), dense: dense);
}

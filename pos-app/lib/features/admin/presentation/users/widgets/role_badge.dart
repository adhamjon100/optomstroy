// `RoleBadge` (03 §9.61) для SCR-45. [ДОПУЩЕНИЕ RM-D-010] Компонента нет в design_system (RM-C-003);
// реализован в фиче по спецификации 03 §9.61 — перенос в DS — запрос владельцу 03 (D_spec_questions.md).
// Стиль: старшие роли (`senior_seller`, `admin`, `owner`) — `primaryContainer`/`primaryText`,
// остальные — `surfaceVariant`/`textSecondary`; иконка 14 + `label 13/500`; ≤ 3 бейджа, далее «+N».
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';

class RoleBadge extends StatelessWidget {
  const RoleBadge({super.key, required this.role, this.textOnly = false});

  final RoleCode role;

  /// Вариант `text` (compact в строках списка): только `caption textSecondary`.
  final bool textOnly;

  static bool _senior(RoleCode r) => r == RoleCode.seniorSeller || r == RoleCode.admin || r == RoleCode.owner;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final label = AdminLabels.role(l10n, role);
    if (textOnly) {
      return Text(label, style: context.text.caption.copyWith(color: c.textSecondary), maxLines: 1);
    }
    final senior = _senior(role);
    final bg = senior ? c.primaryContainer : c.surfaceVariant;
    final fg = senior ? c.primaryText : c.textSecondary;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AdminLabels.roleIcon(role), size: 14, color: fg),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.label.copyWith(color: fg, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Набор бейджей: не более 3, далее «+N» (03 §9.61).
class RoleBadges extends StatelessWidget {
  const RoleBadges({super.key, required this.roles, this.textOnly = false});

  final List<RoleCode> roles;
  final bool textOnly;

  @override
  Widget build(BuildContext context) {
    final shown = roles.take(3).toList();
    final rest = roles.length - shown.length;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final r in shown) RoleBadge(role: r, textOnly: textOnly),
        if (rest > 0) Text('+$rest', style: context.text.caption.copyWith(color: context.colors.textSecondary)),
      ],
    );
  }
}

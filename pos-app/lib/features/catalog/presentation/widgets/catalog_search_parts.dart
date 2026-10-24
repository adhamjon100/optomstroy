// Части SCR-11 (02 SCR-11.2, UI-11-006, UI-11-011, UI-11-012): состояние «Ввод < 2 символов» —
// «Введите ещё N символ», недавние запросы (до 5, только память процесса) и недавние товары (до 5);
// подвал «Не нашли? … · Отсканировать штрихкод».
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/catalog/presentation/state/search_input_policy.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';

class SearchTooShortPanel extends ConsumerWidget {
  const SearchTooShortPanel({
    super.key,
    required this.text,
    required this.onQuery,
    required this.onProduct,
    this.padding = EdgeInsets.zero,
  });

  final String text;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onProduct;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final List<String> history = ref.watch(searchHistoryProvider);
    final List<RecentProduct> recent = ref.watch(catalogRecentProductsProvider).value ?? const <RecentProduct>[];
    final int missing = SearchInputPolicy.missingChars(text);
    return ListView(
      key: const ValueKey<String>('search-too-short'),
      padding: padding,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(vertical: context.space.s4),
          child: Text(
            l10n.search_hint_more_chars(missing == 0 ? SearchInputPolicy.missingChars('') : missing),
            key: const ValueKey<String>('search-more-chars'),
            style: context.text.body.copyWith(color: c.textSecondary),
          ),
        ),
        if (history.isNotEmpty) ...<Widget>[
          AppSectionHeader(title: l10n.search_recent_queries_title, padding: EdgeInsets.zero),
          for (final String q in history)
            AppListTile(
              key: ValueKey<String>('search-history-$q'),
              leading: Icon(Icons.history_rounded, size: 20, color: c.textSecondary),
              title: q,
              onTap: () => onQuery(q),
              trailing: AppIconButton(
                icon: Icons.close_rounded,
                small: true,
                semanticLabel: l10n.ds_button_reset,
                onPressed: () => ref.read(searchHistoryProvider.notifier).remove(q),
              ),
            ),
        ],
        if (recent.isNotEmpty) ...<Widget>[
          SizedBox(height: context.space.s4),
          AppSectionHeader(title: l10n.catalog_recent_title, padding: EdgeInsets.zero),
          for (final RecentProduct r in recent.take(5))
            AppListTile(
              key: ValueKey<String>('search-recent-${r.product.id}'),
              leading: Icon(Icons.inventory_2_outlined, size: 20, color: c.textSecondary),
              title: r.product.name,
              onTap: () => onProduct(r.product.id),
            ),
        ],
      ],
    );
  }
}

class SearchNotFoundHint extends StatelessWidget {
  const SearchNotFoundHint({super.key, this.onScan});

  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.s4),
      child: Column(
        children: <Widget>[
          Text(
            l10n.search_not_found_hint,
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(color: c.textSecondary),
          ),
          if (onScan != null)
            AppButton(
              label: l10n.search_scanner_tooltip,
              icon: Icons.qr_code_scanner_rounded,
              onPressed: onScan,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
            ),
        ],
      ),
    );
  }
}

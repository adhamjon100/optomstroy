// Заголовок экранов SCR-33/34/35: название раздела + имя клиента подзаголовком (из памяти сессии, без запроса).
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Заголовок с подзаголовком.
class CustomerScreenTitle extends StatelessWidget {
  /// Создаёт заголовок.
  const CustomerScreenTitle({required this.title, this.subtitle, super.key});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      if (subtitle != null)
        Text(
          subtitle!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.text.caption.copyWith(color: context.colors.textSecondary),
        ),
    ],
  );
}

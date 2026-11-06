// SCR-52 состояние «Отправляем заявку…» UI-52-013 (02 ч. F SCR-52.3, SCR-52.5; P-002 §8.5 п. 3 «Ожидание», п. 10;
// 12 T-KIOSK-053; 13 TAB-2-04): индикатор 48 и подпись поверх правой колонки, форма под ним затемнена и не принимает
// касаний. Пока он на экране, кнопки, клавиатура, «Изменить номер», «Назад» и корзина недоступны, второй запрос не
// уходит (повторы и восстановление по ключу идут под этим же состоянием — ответ до ≈ 19 с, таймаут клиента 30 с).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Слой «Отправляем заявку…» над формой [child] (кнопки → индикатор crossfade 150 мс; reduce-motion — мгновенно).
class KioskSendingView extends StatelessWidget {
  const KioskSendingView({required this.sending, required this.child, super.key});

  /// Ключ слоя (тесты).
  static const Key overlayKey = ValueKey<String>('kiosk-sending');

  /// Идёт отправка.
  final bool sending;

  /// Правая колонка шага.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Duration fade = context.motion.of(context.motion.fast);
    return Stack(
      children: <Widget>[
        IgnorePointer(
          ignoring: sending,
          child: ExcludeSemantics(
            excluding: sending,
            child: AnimatedOpacity(opacity: sending ? 0.24 : 1, duration: fade, child: child),
          ),
        ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: fade,
            child: !sending
                ? const SizedBox.shrink()
                : Semantics(
                    key: overlayKey,
                    container: true,
                    liveRegion: true,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const AppProgress.circular(size: 48),
                          SizedBox(height: context.space.s4),
                          Text(
                            AppLocalizations.of(context).kiosk_sending,
                            textAlign: TextAlign.center,
                            style: context.text.title.copyWith(color: c.textPrimary),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

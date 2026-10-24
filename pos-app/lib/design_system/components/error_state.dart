import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Вид `ErrorState` (03 §9.44).
enum ErrorStateKind { inline, banner, fullScreen }

/// Тон баннера (03 §9.44: `error/warning/info/success`).
enum ErrorStateTone { error, warning, info, success }

/// Состояние ошибки `ErrorState` (03 §9.44). Текст — из ARB `error_<code>` (подбирает экран
/// по `problem+json.code`); «Повторить» повторяет исходный запрос с тем же `Idempotency-Key`
/// (логика — у вызывающего кода). Без стек-трейсов; `requestId` копируется по тапу.
class ErrorState extends StatelessWidget {
  /// Инлайн-строка 40: иконка `error` 20 + текст `label error` + `AppButton.text S` «Повторить».
  const ErrorState.inline({super.key, required this.message, this.onRetry, this.retrying = false})
    : kind = ErrorStateKind.inline,
      tone = ErrorStateTone.error,
      title = null,
      requestId = null,
      onClose = null,
      onBack = null,
      backLabel = null;

  /// Баннер 48 на контейнере тона с закрытием для неблокирующих.
  const ErrorState.banner({
    super.key,
    required this.message,
    this.tone = ErrorStateTone.error,
    this.onRetry,
    this.retrying = false,
    this.onClose,
  }) : kind = ErrorStateKind.banner,
       title = null,
       requestId = null,
       onBack = null,
       backLabel = null;

  /// Полноэкранная: иллюстрация 160 + `h3` + `body textSecondary` + «Повторить» `primary`
  /// + «Назад» `text` + `caption` «Код: {requestId}».
  const ErrorState.fullScreen({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
    this.retrying = false,
    this.onBack,
    this.backLabel,
    this.requestId,
  }) : kind = ErrorStateKind.fullScreen,
       tone = ErrorStateTone.error,
       onClose = null;

  /// Вид.
  final ErrorStateKind kind;

  /// Тон (баннер).
  final ErrorStateTone tone;

  /// Заголовок (`fullScreen`).
  final String? title;

  /// Текст ошибки.
  final String message;

  /// «Повторить»; `null` — кнопки нет.
  final VoidCallback? onRetry;

  /// Повтор выполняется («Повторить» → loading).
  final bool retrying;

  /// Закрытие баннера (неблокирующие).
  final VoidCallback? onClose;

  /// «Назад» (`fullScreen`).
  final VoidCallback? onBack;

  /// Подпись «Назад».
  final String? backLabel;

  /// Код запроса для поддержки.
  final String? requestId;

  /// Пара (контейнер, цвет) и иконка тона.
  static (Color, Color, IconData) toneOf(DsColors c, ErrorStateTone t) => switch (t) {
    ErrorStateTone.error => (c.errorContainer, c.error, Icons.error_rounded),
    ErrorStateTone.warning => (c.warningContainer, c.warning, Icons.warning_rounded),
    ErrorStateTone.info => (c.infoContainer, c.info, Icons.info_rounded),
    ErrorStateTone.success => (c.successContainer, c.success, Icons.check_circle_rounded),
  };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return switch (kind) {
      ErrorStateKind.inline => _inline(context, l10n),
      ErrorStateKind.banner => _banner(context, l10n),
      ErrorStateKind.fullScreen => _fullScreen(context, l10n),
    };
  }

  Widget _retry(AppLocalizations l10n, {AppButtonVariant variant = AppButtonVariant.text, AppButtonSize? size}) =>
      AppButton(
        label: l10n.ds_button_retry,
        onPressed: onRetry,
        loading: retrying,
        variant: variant,
        size: size ?? AppButtonSize.s,
      );

  Widget _inline(BuildContext context, AppLocalizations l10n) {
    final DsColors c = context.colors;
    return Semantics(
      liveRegion: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: <Widget>[
            Icon(Icons.error_rounded, size: 20, color: c.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: context.text.label.copyWith(color: c.error)),
            ),
            if (onRetry != null) _retry(l10n),
          ],
        ),
      ),
    );
  }

  Widget _banner(BuildContext context, AppLocalizations l10n) {
    final DsColors c = context.colors;
    final (Color bg, Color fg, IconData icon) = toneOf(c, tone);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
        decoration: BoxDecoration(color: bg),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(message, style: context.text.body.copyWith(color: c.textPrimary)),
              ),
            ),
            if (onRetry != null) _retry(l10n),
            if (onClose != null)
              AppIconButton(
                icon: Icons.close_rounded,
                iconSize: 20,
                semanticLabel: l10n.ds_button_close,
                onPressed: onClose,
              ),
          ],
        ),
      ),
    );
  }

  Widget _fullScreen(BuildContext context, AppLocalizations l10n) {
    final DsColors c = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ExcludeSemantics(
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(color: c.errorContainer, shape: BoxShape.circle),
                  child: Icon(Icons.error_outline_rounded, size: 48, color: c.error),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                title ?? '',
                textAlign: TextAlign.center,
                style: context.text.h3.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.text.body.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: 24),
              if (onRetry != null) _retry(l10n, variant: AppButtonVariant.primary, size: AppButtonSize.m),
              if (onBack != null) ...<Widget>[
                const SizedBox(height: 8),
                AppButton(label: backLabel ?? '', onPressed: onBack, variant: AppButtonVariant.text),
              ],
              if (requestId != null) ...<Widget>[
                const SizedBox(height: 16),
                _RequestId(text: l10n.ds_request_id(requestId!), value: requestId!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RequestId extends StatelessWidget {
  const _RequestId({required this.text, required this.value});

  final String text;
  final String value;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      child: DsInteractive(
        onTap: () => Clipboard.setData(ClipboardData(text: value)).ignore(),
        builder: (BuildContext context, DsInteractionState s) => DsTapTarget(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(text, style: context.text.caption.copyWith(color: c.textSecondary)),
              const SizedBox(width: 4),
              Icon(Icons.content_copy_rounded, size: 16, color: c.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

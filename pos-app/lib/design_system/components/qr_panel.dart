import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Вариант `QrPanel` (03 §9.58): `inline` — карточка SCR-22/SCR-38 (QR 240; compact — min(ширина − 64, 280));
/// `fullscreen` — «Показать покупателю» (QR 320+, крупная сумма).
enum QrPanelVariant { inline, fullscreen }

/// Что показывает панель — отображение статуса платежа (автомат ядра §22.2; компонент своих статусов не вводит).
enum QrPanelView {
  /// `qr_pending`: скелетон 240 + «Формируем QR…».
  loading,

  /// `qr_shown`: QR (или текст QR-таблички при `provider=none`) + «Ожидаем оплату».
  shown,

  /// `qr_expired`: QR приглушён 40 %.
  expired,

  /// `manual_confirm`: QR приглушён 40 %, чип «Требует разбора».
  review,

  /// `received`: QR заменён галочкой.
  received,

  /// `voided`: QR скрыт.
  voided,

  /// QR не сформирован (`warnings[QR_UNAVAILABLE]`) — текст и действия запасного пути.
  unavailable,
}

/// Панель QR-оплаты `QrPanel` (03 §9.58; 02 UI-22-003…UI-22-006, UI-22-013): заголовок → сумма → QR чёрным на
/// белом (#000000 / #FFFFFF, тихая зона ≥ 4 модуля, без логотипа — не токенизируется) → подпись и таймер →
/// статус → действия. Тексты и действия — от вызывающего кода; QR рисуется из [payload] (`qr_flutter`) или
/// [imageUrl].
class QrPanel extends StatelessWidget {
  /// Создаёт панель.
  const QrPanel({
    super.key,
    required this.view,
    required this.title,
    required this.amountText,
    this.variant = QrPanelVariant.inline,
    this.payload,
    this.imageUrl,
    this.purpose,
    this.timerText,
    this.timerWarning = false,
    this.statusLabel,
    this.statusVariant = StatusChipVariant.info,
    this.statusBusy = false,
    this.message,
    this.receivedText,
    this.receivedNote,
    this.qrSemanticLabel,
    this.loadingText,
    this.actions = const <Widget>[],
  });

  /// Вариант.
  final QrPanelVariant variant;

  /// Отображаемое состояние.
  final QrPanelView view;

  /// «Оплата по QR · Бакай Банк».
  final String title;

  /// Сумма («16 007,50 сом»; только с сервера).
  final String amountText;

  /// EMVCo/ELQR payload (`QrInfo.payload`) — на диск не пишется.
  final String? payload;

  /// Готовое изображение QR (`QrInfo.imageUrl`).
  final String? imageUrl;

  /// Назначение («Оплата заказа POS-2026-000123 · Бакай Банк»).
  final String? purpose;

  /// «Действует до 10:11 · осталось 14:32» (без срока — `null`).
  final String? timerText;

  /// Последние 60 с — `warning`.
  final bool timerWarning;

  /// Статус платежа («Ожидаем оплату»).
  final String? statusLabel;

  /// Вариант чипа статуса.
  final StatusChipVariant statusVariant;

  /// Спиннер 16 у статуса (ожидание).
  final bool statusBusy;

  /// Текст вместо QR (QR-табличка при `provider=none`, `QR_UNAVAILABLE`).
  final String? message;

  /// «Оплата получена».
  final String? receivedText;

  /// «Получено автоматически» / «Оплата подтверждена вручную».
  final String? receivedNote;

  /// Подпись QR для screen reader.
  final String? qrSemanticLabel;

  /// «Формируем QR…».
  final String? loadingText;

  /// Кнопки («Перевыпустить QR», «Подтвердить оплату вручную», «Показать покупателю»…).
  final List<Widget> actions;

  /// Сторона QR по варианту и ширине (03 §9.58).
  static double qrSizeFor(QrPanelVariant variant, double width) {
    if (variant == QrPanelVariant.fullscreen) return width >= 400 ? 320 : (width - 48).clamp(200, 320);
    if (width < 600) return (width - 64).clamp(160, 280);
    return 240;
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final double width = MediaQuery.sizeOf(context).width;
    final double qrSize = qrSizeFor(variant, width);
    final bool full = variant == QrPanelVariant.fullscreen;
    return Container(
      constraints: BoxConstraints(maxWidth: full ? 480 : 420),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.all(context.radii.lg),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(
            title,
            textAlign: TextAlign.center,
            style: context.text.h3.copyWith(color: c.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            amountText,
            textAlign: TextAlign.center,
            style: (full ? context.text.display : context.text.h2).copyWith(
              color: c.primaryText,
              fontWeight: FontWeight.w700,
              fontFeatures: DsTypography.numeric,
            ),
          ),
          if (purpose != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              purpose!,
              textAlign: TextAlign.center,
              style: context.text.caption.copyWith(color: c.textSecondary),
            ),
          ],
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: BoxConstraints(minWidth: qrSize, maxWidth: qrSize, minHeight: qrSize),
            child: _qr(context, qrSize),
          ),
          if (timerText != null && (view == QrPanelView.shown || view == QrPanelView.expired)) ...<Widget>[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: timerWarning,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.schedule_rounded, size: 16, color: timerWarning ? c.warning : c.textSecondary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      timerText!,
                      style: context.text.label.copyWith(
                        color: timerWarning ? c.warning : c.textSecondary,
                        fontFeatures: DsTypography.numeric,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (statusLabel != null) ...<Widget>[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  StatusChip(label: statusLabel!, variant: statusVariant),
                  if (statusBusy) ...<Widget>[const SizedBox(width: 8), const AppProgress.circular(size: 16)],
                ],
              ),
            ),
          ],
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }

  Widget _qr(BuildContext context, double size) {
    final DsColors c = context.colors;
    switch (view) {
      case QrPanelView.loading:
        return Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            SkeletonBox.image(size: size - 32),
            if (loadingText != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(loadingText!, style: context.text.caption.copyWith(color: c.textSecondary)),
            ],
          ],
        );
      case QrPanelView.received:
        return Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(shape: BoxShape.circle, color: c.success),
              child: Icon(Icons.check_rounded, size: 56, color: c.onSuccess),
            ),
            if (receivedText != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                receivedText!,
                textAlign: TextAlign.center,
                style: context.text.title.copyWith(color: c.success, fontWeight: FontWeight.w600),
              ),
            ],
            if (receivedNote != null) Text(receivedNote!, style: context.text.caption.copyWith(color: c.textSecondary)),
          ],
        );
      case QrPanelView.voided:
      case QrPanelView.unavailable:
        return _message(context, view == QrPanelView.voided ? Icons.block_rounded : Icons.qr_code_2_rounded);
      case QrPanelView.shown:
      case QrPanelView.expired:
      case QrPanelView.review:
        final Widget? image = _image(size);
        if (image == null) return _message(context, Icons.qr_code_2_rounded);
        return Opacity(opacity: view == QrPanelView.shown ? 1 : 0.4, child: image);
    }
  }

  Widget _message(BuildContext context, IconData icon) {
    final DsColors c = context.colors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.md)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 48, color: c.textSecondary),
          if (message != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: context.text.body.copyWith(color: c.textPrimary),
            ),
          ],
        ],
      ),
    );
  }

  Widget? _image(double size) {
    // QR — всегда чёрный на белом (03 §9.58: контраст QR не токенизируется).
    const Color qrBackground = Color(0xFFFFFFFF);
    const Color qrModules = Color(0xFF000000);
    if (payload != null && payload!.isNotEmpty) {
      return Semantics(
        image: true,
        label: qrSemanticLabel,
        child: SizedBox.square(
          dimension: size,
          child: QrImageView(
            key: const ValueKey<String>('qr-panel-image'),
            data: payload!,
            size: size,
            // Тихая зона ≥ 4 модулей: ≈ 8 % стороны для версий до 10.
            padding: EdgeInsets.all(size * 0.08),
            backgroundColor: qrBackground,
            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: qrModules),
            dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: qrModules),
            semanticsLabel: qrSemanticLabel ?? '',
          ),
        ),
      );
    }
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return Semantics(
        image: true,
        label: qrSemanticLabel,
        child: ColoredBox(
          color: qrBackground,
          child: Image.network(imageUrl!, width: size, height: size, fit: BoxFit.contain),
        ),
      );
    }
    return null;
  }
}

// Документы заказа (02 SCR-24 UI-24-009, SCR-25 UI-25-009; 10 PRINT-001…005; ядро §19.4): PDF формирует backend
// (`GET /orders/{id}/documents/{invoice|receipt}.pdf`), клиент только показывает и печатает — байты в памяти,
// без файлов вне временного каталога (раздел 3.9, AC-UI-24-017); «Скачать PDF» — только после `ConfirmDialog`
// с `order_doc_pdn_warning` и через системный диалог сохранения; «Поделиться» в R1 нет (Q-264).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';

/// Действие над документом.
enum OrderDocCommand { preview, print, download }

/// Формат бумаги документа: счёт — A4, товарный чек — 80 мм (PRINT-002, 03 §9.59).
PrintPaper paperOf(OrderDocumentKind kind) => switch (kind) {
  OrderDocumentKind.invoice => PrintPaper.a4,
  OrderDocumentKind.receipt => PrintPaper.thermal80,
};

/// Выполнить [command] для документа [kind] заказа [orderId]; ошибки — снекбар. `true` — выполнено.
Future<bool> runOrderDocument(
  BuildContext context,
  WidgetRef ref, {
  required String orderId,
  required OrderDocumentKind kind,
  required OrderDocCommand command,
}) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  if (command == OrderDocCommand.download) {
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.order_doc_download,
      message: l10n.order_doc_pdn_warning,
      confirmLabel: l10n.order_doc_download,
    );
    if (!ok || !context.mounted) return false;
  }
  final Result<OrderDocumentFile> r;
  try {
    r = await ref.read(ordersRepositoryProvider).document(orderId, kind, format: paperOf(kind));
  } on Object catch (e) {
    if (context.mounted) _fail(context, l10n, UnknownFailure(cause: e), command);
    return false;
  }
  if (!context.mounted) return false;
  switch (r) {
    case FailureResult<OrderDocumentFile>(:final Failure failure):
      _fail(context, l10n, failure, command);
      return false;
    case Success<OrderDocumentFile>(:final OrderDocumentFile value):
      try {
        switch (command) {
          case OrderDocCommand.preview:
            final OrderDocumentPrinter? printer = ref.read(orderDocumentPrinterProvider);
            if (printer == null) return false;
            await printer.preview(context, value);
            return true;
          case OrderDocCommand.print:
            final OrderDocumentPrinter? printer = ref.read(orderDocumentPrinterProvider);
            if (printer == null) return false;
            final bool printed = await printer.print(value);
            if (printed && context.mounted) AppSnackbar.show(context, message: l10n.order_created_doc_printed);
            return printed;
          case OrderDocCommand.download:
            final OrderDocumentSaver? saver = ref.read(orderDocumentSaverProvider);
            return saver != null && await saver.saveAs(value);
        }
      } on Object {
        if (context.mounted) {
          AppSnackbar.show(context, message: l10n.order_created_doc_failed, variant: AppSnackbarVariant.error);
        }
        return false;
      }
  }
}

void _fail(BuildContext context, AppLocalizations l10n, Failure failure, OrderDocCommand command) {
  final String message = command == OrderDocCommand.print && failure is! ServerFailure
      ? l10n.order_created_doc_failed
      : ErrorTexts.message(l10n, UiErrorMapper.fromFailure(failure));
  AppSnackbar.show(context, message: message, variant: AppSnackbarVariant.error);
}

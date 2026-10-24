// «Скачать PDF» SCR-24 (02 SCR-24.4, AC-UI-24-017; RM-F-004): только системный диалог «Сохранить как…»
// (`file_selector.getSaveLocation`) после предупреждения о ПДн — без тихой записи в «Загрузки» и без «Поделиться»
// (Q-264). Байты документа — только память, файл пишется туда, куда указал пользователь.
//
// Платформы: `getSaveLocation` реализован в file_selector для Windows/macOS/Linux; на Android/iOS (SAF
// `ACTION_CREATE_DOCUMENT` / UIDocumentPicker) — нет, поэтому там порт не подключается и кнопка скрыта
// (FQ-INT-F-01 в docs/stages/F_spec_questions.md).

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';

/// Платформа поддерживает «Сохранить как…» через file_selector.
bool fileSelectorSaveSupported(TargetPlatform platform) =>
    !kIsWeb &&
    (platform == TargetPlatform.windows || platform == TargetPlatform.macOS || platform == TargetPlatform.linux);

/// Функция выбора места сохранения (в тестах подменяется).
typedef SaveLocationPicker = Future<String?> Function(String suggestedName);

/// `OrderDocumentSaver` на file_selector.
final class FileSelectorOrderDocumentSaver implements OrderDocumentSaver {
  const FileSelectorOrderDocumentSaver({SaveLocationPicker? pick}) : _pick = pick;

  final SaveLocationPicker? _pick;

  static const XTypeGroup _pdf = XTypeGroup(
    label: 'PDF',
    extensions: <String>['pdf'],
    mimeTypes: <String>['application/pdf'],
  );

  @override
  Future<bool> saveAs(OrderDocumentFile file) async {
    final String? path = await (_pick ?? _systemDialog)(file.fileName);
    if (path == null) return false;
    await XFile.fromData(Uint8List.fromList(file.bytes), mimeType: 'application/pdf', name: file.fileName).saveTo(path);
    return true;
  }

  static Future<String?> _systemDialog(String suggestedName) async {
    final FileSaveLocation? location = await getSaveLocation(
      acceptedTypeGroups: const <XTypeGroup>[_pdf],
      suggestedName: suggestedName,
    );
    return location?.path;
  }
}

// Мост [CancelSignal] (core/utils, порты domain) → `CancelToken` dio (06 §6.7, D-31): отмена сигнала отменяет
// HTTP-запрос; dio завершает его `DioException(type: cancel)`, ErrorMapper — `UnknownFailure` (вызывающий такой ответ
// отбрасывает по номеру поколения).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';

/// `CancelToken` для [signal]; `null` — запрос без отмены.
CancelToken? dioCancelToken(CancelSignal? signal) {
  if (signal == null) return null;
  final CancelToken token = CancelToken();
  if (signal.isCancelled) {
    token.cancel('superseded');
  } else {
    unawaited(signal.whenCancelled.then((_) => token.cancel('superseded')));
  }
  return token;
}

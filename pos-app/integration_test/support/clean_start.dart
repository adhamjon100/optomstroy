/// Ключи защищённого хранилища, которые удаляет «чистый старт» каждого потока integration_test: сессия, черновик
/// регистрации и признак режима «Планшет магазина» (`SecureKey.kiosk`: признак, склад планшета, хэш, соль, счётчик и
/// пауза аварийного кода), признаки Windows Hello по `userId` — «перед PIN» и «ключ» (вне ключей сессии, 09 BIO-034,
/// BIO-038 — иначе гейт или ключ, включённые вручную на этом ПК, меняли бы SCR-08 потока). Идентификатор устройства остаётся (07 §11.4).
///
/// Признак планшета `SessionController._restore` читает первым (02 SCR-00.6, строка 1а): если прерванный прогон
/// `kiosk_flow_test` оставил его на устройстве, без этой очистки поток сотрудника или покупателя стартовал бы на
/// `/kiosk` вместо SCR-01 / SCR-08, и регрессия паритета 12 T-KIOSK-035 (п. 3; 10 KIOSK-029) падала бы или ничего не
/// доказывала по причинам вне проверяемого кода (ревью P-002 parity-1).
library;

import 'package:optomstroy/core/storage/secure_storage.dart';

/// Ключи чистого старта (сессия, черновик регистрации, признак планшета, признаки Windows Hello).
const List<SecureKey> kCleanStartKeys = <SecureKey>[
  ...SecureKey.session,
  ...SecureKey.registration,
  ...SecureKey.kiosk,
  SecureKey.helloGateUsers,
  SecureKey.helloKeyUsers,
];

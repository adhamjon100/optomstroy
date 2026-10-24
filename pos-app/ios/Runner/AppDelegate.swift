import Flutter
import LocalAuthentication
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var biometricCrypto: BiometricCrypto?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "BiometricCrypto") {
      biometricCrypto = BiometricCrypto(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

// Криптопривязка `biometric_refresh` (D-13; 09 §9.2; ADR-013 и уточнение этапа D).
// Элемент Keychain с SecAccessControl(kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet):
// чтение только после Face ID / Touch ID (не код устройства); смена набора биометрии делает элемент
// недоступным → сигнал `invalidated`; элемент не попадает в резервные копии и удаляется при снятии кода.
// Класс размещён в AppDelegate.swift, чтобы не менять состав цели Runner в project.pbxproj.
// Протокол канала — lib/core/biometrics/biometric_crypto_channel.dart. Секрет не логируется.
final class BiometricCrypto {
  static let channelName = "kg.optomstroy/biometric_crypto"
  private static let service = "kg.optomstroy.biometric_refresh"
  private static let account = "biometric_refresh.v1"
  private static let enrolledMarker = "kg.optomstroy.biometric_refresh.enrolled"

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: BiometricCrypto.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "capability":
      result(capability())
    case "has":
      result(UserDefaults.standard.bool(forKey: BiometricCrypto.enrolledMarker))
    case "clear":
      clear()
      result(nil)
    case "store":
      guard let secret = args["secret"] as? String, !secret.isEmpty else {
        result(failure("failed"))
        return
      }
      store(secret: secret, title: (args["title"] as? String) ?? " ", cancel: args["cancel"] as? String, result: result)
    case "replace":
      guard let secret = args["secret"] as? String, !secret.isEmpty else {
        result(failure("failed"))
        return
      }
      replace(secret: secret, title: (args["title"] as? String) ?? " ", cancel: args["cancel"] as? String, result: result)
    case "read":
      read(title: (args["title"] as? String) ?? " ", cancel: args["cancel"] as? String, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func capability() -> [String: Any] {
    let context = LAContext()
    var error: NSError?
    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
      return ["kind": "ios", "availability": "available", "cryptoBinding": true]
    }
    let code = (error as? LAError)?.code
    switch code {
    case .some(.biometryNotEnrolled):
      return ["kind": "ios", "availability": "not_enrolled", "cryptoBinding": true, "reason": "not_enrolled"]
    case .some(.biometryLockout):
      return ["kind": "ios", "availability": "locked_out", "cryptoBinding": true, "reason": "lockout"]
    case .some(.passcodeNotSet):
      return ["kind": "ios", "availability": "unsupported", "cryptoBinding": true, "reason": "no_passcode"]
    default:
      return ["kind": "none", "availability": "unsupported", "cryptoBinding": false, "reason": "no_hardware"]
    }
  }

  /// Подтверждение биометрией → новый элемент Keychain с ACL `.biometryCurrentSet`.
  private func store(secret: String, title: String, cancel: String?, result: @escaping FlutterResult) {
    let context = LAContext()
    if let cancel = cancel { context.localizedCancelTitle = cancel }
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: title) { ok, error in
      let reply: [String: Any]
      if ok {
        reply = self.add(secret: secret, context: context)
      } else {
        reply = self.failure(BiometricCrypto.mapLAError(error))
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  private func add(secret: String, context: LAContext) -> [String: Any] {
    deleteItem()
    var aclError: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
        .biometryCurrentSet,
        &aclError
      ),
      let data = secret.data(using: .utf8)
    else {
      return failure("failed")
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: BiometricCrypto.service,
      kSecAttrAccount as String: BiometricCrypto.account,
      kSecValueData as String: data,
      kSecAttrAccessControl as String: access,
      kSecUseAuthenticationContext as String: context,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { return failure("failed") }
    UserDefaults.standard.set(true, forKey: BiometricCrypto.enrolledMarker)
    return ["ok": true]
  }

  /// AU-07 (02 SCR-08.4 п. 3; 09 §9.2): новое значение пишется в тот же элемент Keychain (SecItemUpdate) — ACL
  /// `.biometryCurrentSet` и элемент не пересоздаются; нет элемента → `no_credential` (вызывающий выполнит store).
  private func replace(secret: String, title: String, cancel: String?, result: @escaping FlutterResult) {
    guard UserDefaults.standard.bool(forKey: BiometricCrypto.enrolledMarker), let data = secret.data(using: .utf8) else {
      result(failure("no_credential"))
      return
    }
    let context = LAContext()
    if let cancel = cancel { context.localizedCancelTitle = cancel }
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: title) { ok, error in
      let reply: [String: Any]
      if ok {
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: BiometricCrypto.service,
          kSecAttrAccount as String: BiometricCrypto.account,
          kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
          reply = ["ok": true]
        case errSecItemNotFound:
          self.clear()
          reply = self.failure("invalidated")
        default:
          reply = self.failure("failed")
        }
      } else {
        reply = self.failure(BiometricCrypto.mapLAError(error))
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  /// Чтение элемента: системный диалог Face ID / Touch ID вызывает сам Keychain (kSecUseAuthenticationContext).
  private func read(title: String, cancel: String?, result: @escaping FlutterResult) {
    let enrolled = UserDefaults.standard.bool(forKey: BiometricCrypto.enrolledMarker)
    DispatchQueue.global(qos: .userInitiated).async {
      let context = LAContext()
      context.localizedReason = title
      if let cancel = cancel { context.localizedCancelTitle = cancel }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: BiometricCrypto.service,
        kSecAttrAccount as String: BiometricCrypto.account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context,
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      let reply: [String: Any]
      switch status {
      case errSecSuccess:
        if let data = item as? Data, let value = String(data: data, encoding: .utf8) {
          reply = ["ok": true, "value": value]
        } else {
          reply = self.failure("failed")
        }
      case errSecUserCanceled:
        reply = self.failure("cancelled")
      case errSecItemNotFound:
        // Элемент был, но стал недоступен: набор биометрии изменён (.biometryCurrentSet) или снят код.
        if enrolled { self.clear() }
        reply = self.failure(enrolled ? "invalidated" : "no_credential")
      case errSecAuthFailed:
        reply = self.failure("failed")
      default:
        reply = self.failure("failed")
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  private func clear() {
    deleteItem()
    UserDefaults.standard.removeObject(forKey: BiometricCrypto.enrolledMarker)
  }

  private func deleteItem() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: BiometricCrypto.service,
      kSecAttrAccount as String: BiometricCrypto.account,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private func failure(_ code: String) -> [String: Any] {
    return ["ok": false, "error": code]
  }

  private static func mapLAError(_ error: Error?) -> String {
    guard let la = error as? LAError else { return "failed" }
    switch la.code {
    case .userCancel, .appCancel, .systemCancel, .userFallback:
      return "cancelled"
    case .biometryLockout:
      return "lockout"
    case .biometryNotEnrolled:
      return "not_enrolled"
    case .biometryNotAvailable, .passcodeNotSet:
      return "not_available"
    default:
      return "failed"
    }
  }
}

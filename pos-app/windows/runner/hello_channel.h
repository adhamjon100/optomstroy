// Method channel kg.optomstroy/windows_hello: Windows Hello key for signing in without the app PIN (mode W2) and
// the reasons Windows Hello is unavailable (spec 15 ADR-116 p. 3; 09 section 9.2 "W2", BIO-038, BIO-039;
// 06 sections 6.2 and 16.1; 02 UI-42-029; the optional plan package LF-1-04 is folded in here).
// Dart wrapper: lib/core/biometrics/windows_hello_key_channel.dart.
//
// Methods (every reply is a map; only malformed arguments are reported as an error):
//   availability          -> {availability: available | device_not_present | not_configured | disabled_by_policy |
//                             device_busy | unknown, keysSupported: bool}
//                             (UserConsentVerifier::CheckAvailabilityAsync, KeyCredentialManager::IsSupportedAsync;
//                             no dialog);
//   createKey {name}      -> {status: ok, publicKey: X.509 SubjectPublicKeyInfo DER} | {status}
//                             (KeyCredentialManager::RequestCreateAsync with ReplaceExisting: Windows Hello dialog);
//   sign {name, data}     -> {status: ok, signature: RSASSA-PKCS1-v1_5 / SHA-256} | {status}
//                             (KeyCredentialManager::OpenAsync + KeyCredential::RequestSignAsync: Windows Hello
//                             dialog);
//   deleteKey {name}      -> {status: ok | failed} (KeyCredentialManager::DeleteAsync; no dialog).
// status: ok, cancelled, not_found, user_prefers_password, already_exists, security_device_locked, unknown_error,
// failed (a WinRT exception).
//
// The channel only touches the app's own keys ("optomstroy.hello.v1.<userId>") and only signs sign-in challenges
// ("optomstroy-hello-unlock/v1:" + base64url), never arbitrary data. The private key never leaves the Windows key
// store (TPM when present); neither keys nor signatures are logged. Replies are sent on the platform thread:
// C++/WinRT resumes an awaited operation in the caller's apartment (the runner thread is an STA, main.cpp).
#ifndef RUNNER_HELLO_CHANNEL_H_
#define RUNNER_HELLO_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

namespace optomstroy {

// Registers the kg.optomstroy/windows_hello handler for the lifetime of the object.
class HelloChannel {
 public:
  explicit HelloChannel(flutter::BinaryMessenger* messenger);
  ~HelloChannel();

  HelloChannel(const HelloChannel&) = delete;
  HelloChannel& operator=(const HelloChannel&) = delete;

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace optomstroy

#endif  // RUNNER_HELLO_CHANNEL_H_

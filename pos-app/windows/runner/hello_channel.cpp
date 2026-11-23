// Windows Hello key channel (W2): see hello_channel.h for the protocol. Spec: 15 ADR-116 p. 3; 09 section 9.2
// "W2" steps 1-4, BIO-038, BIO-039; 11 SEC-146, RR-10; tests 12 T-BIO-032 (build, availability on this machine)
// and T-BIO-036 (Dart side with a fake channel). Automated runs never call createKey or sign: both show the
// Windows Hello dialog.
#include "hello_channel.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.UI.h>
#include <winrt/Windows.Security.Credentials.h>
#include <winrt/Windows.Security.Cryptography.Core.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace optomstroy {
namespace {

namespace credentials = winrt::Windows::Security::Credentials;
namespace credentials_ui = winrt::Windows::Security::Credentials::UI;
namespace cryptography = winrt::Windows::Security::Cryptography;
namespace streams = winrt::Windows::Storage::Streams;

using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;

constexpr char kChannelName[] = "kg.optomstroy/windows_hello";

// Key name: "optomstroy.hello.v1." + server userId (UUID); 09 BIO-038.
constexpr char kKeyPrefix[] = "optomstroy.hello.v1.";
constexpr size_t kMaxKeyNameLength = 64;

// Sign-in challenge of POST /auth/unlock/challenge: prefix + base64url of 32 random bytes (08 section 4.1.10).
constexpr char kChallengePrefix[] = "optomstroy-hello-unlock/v1:";
constexpr size_t kMaxChallengeLength = 96;

// Window class of the Windows Hello (credential) dialog.
constexpr wchar_t kPromptWindowClass[] = L"Credential Dialog Xaml Host";

bool IsHex(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

bool IsBase64Url(uint8_t c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-' || c == '_';
}

// Only the app's own keys: prefix + UUID characters.
bool IsKeyName(const std::string& name) {
  const size_t prefix = sizeof(kKeyPrefix) - 1;
  if (name.size() <= prefix || name.size() > kMaxKeyNameLength || name.compare(0, prefix, kKeyPrefix) != 0) {
    return false;
  }
  for (size_t i = prefix; i < name.size(); ++i) {
    if (!IsHex(name[i]) && name[i] != '-') {
      return false;
    }
  }
  return true;
}

// Only sign-in challenges: the key never signs arbitrary data from the Dart side.
bool IsChallenge(const std::vector<uint8_t>& data) {
  const size_t prefix = sizeof(kChallengePrefix) - 1;
  if (data.size() <= prefix || data.size() > kMaxChallengeLength) {
    return false;
  }
  for (size_t i = 0; i < prefix; ++i) {
    if (data[i] != static_cast<uint8_t>(kChallengePrefix[i])) {
      return false;
    }
  }
  for (size_t i = prefix; i < data.size(); ++i) {
    if (!IsBase64Url(data[i])) {
      return false;
    }
  }
  return true;
}

const char* AvailabilityName(credentials_ui::UserConsentVerifierAvailability availability) {
  switch (availability) {
    case credentials_ui::UserConsentVerifierAvailability::Available:
      return "available";
    case credentials_ui::UserConsentVerifierAvailability::DeviceNotPresent:
      return "device_not_present";
    case credentials_ui::UserConsentVerifierAvailability::NotConfiguredForUser:
      return "not_configured";
    case credentials_ui::UserConsentVerifierAvailability::DisabledByPolicy:
      return "disabled_by_policy";
    case credentials_ui::UserConsentVerifierAvailability::DeviceBusy:
      return "device_busy";
  }
  return "unknown";
}

const char* StatusName(credentials::KeyCredentialStatus status) {
  switch (status) {
    case credentials::KeyCredentialStatus::Success:
      return "ok";
    case credentials::KeyCredentialStatus::UnknownError:
      return "unknown_error";
    case credentials::KeyCredentialStatus::NotFound:
      return "not_found";
    case credentials::KeyCredentialStatus::UserCanceled:
      return "cancelled";
    case credentials::KeyCredentialStatus::UserPrefersPassword:
      return "user_prefers_password";
    case credentials::KeyCredentialStatus::CredentialAlreadyExists:
      return "already_exists";
    case credentials::KeyCredentialStatus::SecurityDeviceLocked:
      return "security_device_locked";
  }
  return "unknown_error";
}

EncodableValue StatusReply(const char* status) {
  return EncodableValue(EncodableMap{{EncodableValue("status"), EncodableValue(std::string(status))}});
}

EncodableValue BytesReply(const char* field, std::vector<uint8_t> bytes) {
  return EncodableValue(EncodableMap{
      {EncodableValue("status"), EncodableValue(std::string("ok"))},
      {EncodableValue(field), EncodableValue(std::move(bytes))},
  });
}

std::vector<uint8_t> BytesOf(const streams::IBuffer& buffer) {
  winrt::com_array<uint8_t> bytes;
  cryptography::CryptographicBuffer::CopyToByteArray(buffer, bytes);
  return std::vector<uint8_t>(bytes.begin(), bytes.end());
}

// A desktop app cannot attach the KeyCredentialManager dialog to its window (unlike
// IUserConsentVerifierInterop for the W1 gate), so the dialog may open behind the app window [typical behaviour,
// checked by hand in 12 T-BIO-031 (5)]. A short-lived thread looks for the dialog window for up to 3 s and brings
// it to the foreground; the app is in the foreground at that moment because the user has just pressed the
// button. If no dialog appears, the thread does nothing.
void BringPromptToFront() {
  std::thread([] {
    for (int attempt = 0; attempt < 30; ++attempt) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      const HWND prompt = ::FindWindowW(kPromptWindowClass, nullptr);
      if (prompt != nullptr) {
        ::SetForegroundWindow(prompt);
        return;
      }
    }
  }).detach();
}

// availability: no dialog. A WinRT failure is reported as "unknown" / keysSupported=false.
winrt::fire_and_forget Availability(std::shared_ptr<Result> result) {
  std::string availability = "unknown";
  bool keys_supported = false;
  try {
    const credentials_ui::UserConsentVerifierAvailability value =
        co_await credentials_ui::UserConsentVerifier::CheckAvailabilityAsync();
    availability = AvailabilityName(value);
  } catch (...) {
    availability = "unknown";
  }
  try {
    keys_supported = co_await credentials::KeyCredentialManager::IsSupportedAsync();
  } catch (...) {
    keys_supported = false;
  }
  result->Success(EncodableValue(EncodableMap{
      {EncodableValue("availability"), EncodableValue(availability)},
      {EncodableValue("keysSupported"), EncodableValue(keys_supported)},
  }));
}

// createKey: RSA-2048 key protected by the Windows Hello gesture; replaces an earlier key with the same name
// (re-enabling replaces the device key, 09 BIO-038). Only the public key (SPKI) is returned.
winrt::fire_and_forget CreateKey(winrt::hstring name, std::shared_ptr<Result> result) {
  EncodableValue reply = StatusReply("failed");
  try {
    BringPromptToFront();
    const credentials::KeyCredentialRetrievalResult created = co_await credentials::KeyCredentialManager::
        RequestCreateAsync(name, credentials::KeyCredentialCreationOption::ReplaceExisting);
    if (created.Status() != credentials::KeyCredentialStatus::Success) {
      reply = StatusReply(StatusName(created.Status()));
    } else {
      const streams::IBuffer public_key = created.Credential().RetrievePublicKey(
          cryptography::Core::CryptographicPublicKeyBlobType::X509SubjectPublicKeyInfo);
      reply = BytesReply("publicKey", BytesOf(public_key));
    }
  } catch (...) {
    reply = StatusReply("failed");
  }
  result->Success(reply);
}

// sign: opening the key shows no dialog; the signature itself requires the Windows Hello gesture (face,
// fingerprint or Windows PIN; 09 section 9.4). not_found from OpenAsync means the key is gone in Windows
// (09 section 9.2 "W2" step 4: the app removes its flag and offers the PIN with helloKeyInvalidated).
winrt::fire_and_forget Sign(winrt::hstring name, std::vector<uint8_t> data, std::shared_ptr<Result> result) {
  EncodableValue reply = StatusReply("failed");
  try {
    const credentials::KeyCredentialRetrievalResult opened =
        co_await credentials::KeyCredentialManager::OpenAsync(name);
    if (opened.Status() != credentials::KeyCredentialStatus::Success) {
      reply = StatusReply(StatusName(opened.Status()));
    } else {
      BringPromptToFront();
      const credentials::KeyCredentialOperationResult signed_data =
          co_await opened.Credential().RequestSignAsync(cryptography::CryptographicBuffer::CreateFromByteArray(data));
      if (signed_data.Status() != credentials::KeyCredentialStatus::Success) {
        reply = StatusReply(StatusName(signed_data.Status()));
      } else {
        reply = BytesReply("signature", BytesOf(signed_data.Result()));
      }
    }
  } catch (...) {
    reply = StatusReply("failed");
  }
  result->Success(reply);
}

// deleteKey: no dialog; a missing key is reported as "failed" (the Dart side treats deletion as best effort).
winrt::fire_and_forget DeleteKey(winrt::hstring name, std::shared_ptr<Result> result) {
  const char* status = "ok";
  try {
    co_await credentials::KeyCredentialManager::DeleteAsync(name);
  } catch (...) {
    status = "failed";
  }
  result->Success(StatusReply(status));
}

const std::string* StringArgument(const EncodableMap& arguments, const char* key) {
  const auto it = arguments.find(EncodableValue(key));
  return it == arguments.end() ? nullptr : std::get_if<std::string>(&it->second);
}

const std::vector<uint8_t>* BytesArgument(const EncodableMap& arguments, const char* key) {
  const auto it = arguments.find(EncodableValue(key));
  return it == arguments.end() ? nullptr : std::get_if<std::vector<uint8_t>>(&it->second);
}

void HandleMethodCall(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
  std::shared_ptr<Result> reply(std::move(result));
  const std::string& method = call.method_name();
  if (method == "availability") {
    Availability(reply);
    return;
  }
  if (method != "createKey" && method != "sign" && method != "deleteKey") {
    reply->NotImplemented();
    return;
  }
  const EncodableMap* arguments = std::get_if<EncodableMap>(call.arguments());
  const std::string* name = arguments == nullptr ? nullptr : StringArgument(*arguments, "name");
  if (name == nullptr || !IsKeyName(*name)) {
    reply->Error("bad_args", "name");
    return;
  }
  const winrt::hstring key_name = winrt::to_hstring(*name);
  if (method == "createKey") {
    CreateKey(key_name, reply);
  } else if (method == "deleteKey") {
    DeleteKey(key_name, reply);
  } else {
    const std::vector<uint8_t>* data = BytesArgument(*arguments, "data");
    if (data == nullptr || !IsChallenge(*data)) {
      reply->Error("bad_args", "data");
      return;
    }
    Sign(key_name, *data, reply);
  }
}

}  // namespace

HelloChannel::HelloChannel(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(HandleMethodCall);
}

HelloChannel::~HelloChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

}  // namespace optomstroy

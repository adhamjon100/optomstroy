// DTO `PublicSettings` — `GET /settings/public` (ядро §19.2; 08 §4.23.1): несекретные
// настройки и флаги функций. Серверные флаги важнее локальных FEATURE_* (06 §6.9).
import 'package:freezed_annotation/freezed_annotation.dart';

part 'public_settings.freezed.dart';
part 'public_settings.g.dart';

@freezed
abstract class PublicSettings with _$PublicSettings {
  const factory PublicSettings({
    List<DeliverySlot>? deliverySlots,
    List<SupportContact>? supportContacts,
    String? privacyContact,
    int? lowStockThreshold,

    /// `platform=semver[,…]` (08 §2.11).
    String? minAppVersion,
    String? recommendedAppVersion,
    String? customerStockDisplay,
    PublicFeatures? features,
  }) = _PublicSettings;

  factory PublicSettings.fromJson(Map<String, dynamic> json) => _$PublicSettingsFromJson(json);
}

/// `DeliverySlot` (`HH:MM`).
@freezed
abstract class DeliverySlot with _$DeliverySlot {
  const factory DeliverySlot({required String from, required String to}) = _DeliverySlot;

  factory DeliverySlot.fromJson(Map<String, dynamic> json) => _$DeliverySlotFromJson(json);
}

/// `SupportContact`.
@freezed
abstract class SupportContact with _$SupportContact {
  const factory SupportContact({required String kind, required String value, String? label}) = _SupportContact;

  factory SupportContact.fromJson(Map<String, dynamic> json) => _$SupportContactFromJson(json);
}

/// `PublicSettings.features`.
@freezed
abstract class PublicFeatures with _$PublicFeatures {
  const factory PublicFeatures({
    bool? customerSelfService,
    bool? returnsFromPos,
    String? qrProvider,
    bool? qrWebhook,
    bool? debtPaymentsFromPos,
  }) = _PublicFeatures;

  factory PublicFeatures.fromJson(Map<String, dynamic> json) => _$PublicFeaturesFromJson(json);
}

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'public_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_PublicSettings _$PublicSettingsFromJson(Map<String, dynamic> json) =>
    _PublicSettings(
      deliverySlots: (json['deliverySlots'] as List<dynamic>?)
          ?.map((e) => DeliverySlot.fromJson(e as Map<String, dynamic>))
          .toList(),
      supportContacts: (json['supportContacts'] as List<dynamic>?)
          ?.map((e) => SupportContact.fromJson(e as Map<String, dynamic>))
          .toList(),
      privacyContact: json['privacyContact'] as String?,
      lowStockThreshold: (json['lowStockThreshold'] as num?)?.toInt(),
      minAppVersion: json['minAppVersion'] as String?,
      recommendedAppVersion: json['recommendedAppVersion'] as String?,
      customerStockDisplay: json['customerStockDisplay'] as String?,
      kiosk: json['kiosk'] == null
          ? null
          : PublicKioskSettings.fromJson(json['kiosk'] as Map<String, dynamic>),
      features: json['features'] == null
          ? null
          : PublicFeatures.fromJson(json['features'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$PublicSettingsToJson(_PublicSettings instance) =>
    <String, dynamic>{
      'deliverySlots': instance.deliverySlots,
      'supportContacts': instance.supportContacts,
      'privacyContact': instance.privacyContact,
      'lowStockThreshold': instance.lowStockThreshold,
      'minAppVersion': instance.minAppVersion,
      'recommendedAppVersion': instance.recommendedAppVersion,
      'customerStockDisplay': instance.customerStockDisplay,
      'kiosk': instance.kiosk,
      'features': instance.features,
    };

_DeliverySlot _$DeliverySlotFromJson(Map<String, dynamic> json) =>
    _DeliverySlot(from: json['from'] as String, to: json['to'] as String);

Map<String, dynamic> _$DeliverySlotToJson(_DeliverySlot instance) =>
    <String, dynamic>{'from': instance.from, 'to': instance.to};

_SupportContact _$SupportContactFromJson(Map<String, dynamic> json) =>
    _SupportContact(
      kind: json['kind'] as String,
      value: json['value'] as String,
      label: json['label'] as String?,
    );

Map<String, dynamic> _$SupportContactToJson(_SupportContact instance) =>
    <String, dynamic>{
      'kind': instance.kind,
      'value': instance.value,
      'label': instance.label,
    };

_PublicKioskSettings _$PublicKioskSettingsFromJson(Map<String, dynamic> json) =>
    _PublicKioskSettings(
      idleSeconds: (json['idleSeconds'] as num?)?.toInt(),
      idleWarningSeconds: (json['idleWarningSeconds'] as num?)?.toInt(),
      doneSeconds: (json['doneSeconds'] as num?)?.toInt(),
    );

Map<String, dynamic> _$PublicKioskSettingsToJson(
  _PublicKioskSettings instance,
) => <String, dynamic>{
  'idleSeconds': instance.idleSeconds,
  'idleWarningSeconds': instance.idleWarningSeconds,
  'doneSeconds': instance.doneSeconds,
};

_PublicFeatures _$PublicFeaturesFromJson(Map<String, dynamic> json) =>
    _PublicFeatures(
      customerSelfService: json['customerSelfService'] as bool?,
      returnsFromPos: json['returnsFromPos'] as bool?,
      qrProvider: json['qrProvider'] as String?,
      qrWebhook: json['qrWebhook'] as bool?,
      debtPaymentsFromPos: json['debtPaymentsFromPos'] as bool?,
      storeTablet: json['storeTablet'] as bool?,
    );

Map<String, dynamic> _$PublicFeaturesToJson(_PublicFeatures instance) =>
    <String, dynamic>{
      'customerSelfService': instance.customerSelfService,
      'returnsFromPos': instance.returnsFromPos,
      'qrProvider': instance.qrProvider,
      'qrWebhook': instance.qrWebhook,
      'debtPaymentsFromPos': instance.debtPaymentsFromPos,
      'storeTablet': instance.storeTablet,
    };

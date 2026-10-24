// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_mode.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Текущий режим оболочки: из сессии (`sessionControllerProvider.userKind`) и профиля входа
/// (`authSessionProvider.profile.primaryRole`, RM-D-007/RM-D-010).

@ProviderFor(appMode)
final appModeProvider = AppModeProvider._();

/// Текущий режим оболочки: из сессии (`sessionControllerProvider.userKind`) и профиля входа
/// (`authSessionProvider.profile.primaryRole`, RM-D-007/RM-D-010).

final class AppModeProvider
    extends $FunctionalProvider<AppMode, AppMode, AppMode>
    with $Provider<AppMode> {
  /// Текущий режим оболочки: из сессии (`sessionControllerProvider.userKind`) и профиля входа
  /// (`authSessionProvider.profile.primaryRole`, RM-D-007/RM-D-010).
  AppModeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appModeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appModeHash();

  @$internal
  @override
  $ProviderElement<AppMode> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AppMode create(Ref ref) {
    return appMode(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AppMode value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AppMode>(value),
    );
  }
}

String _$appModeHash() => r'9d08ee9b81a7a2cbfc1ca314f0b2cfa90e098053';

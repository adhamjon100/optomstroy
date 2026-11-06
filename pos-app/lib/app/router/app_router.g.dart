// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_router.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Единственный `GoRouter` приложения: маршруты `$appRoutes` (routes.dart), маршруты режима планшета
/// `kioskRoutes()` (kiosk_routes.dart, вне оболочки) и глобальный redirect (guards/). Пересчитывает redirect при смене
/// сессии/режима.

@ProviderFor(appRouter)
final appRouterProvider = AppRouterProvider._();

/// Единственный `GoRouter` приложения: маршруты `$appRoutes` (routes.dart), маршруты режима планшета
/// `kioskRoutes()` (kiosk_routes.dart, вне оболочки) и глобальный redirect (guards/). Пересчитывает redirect при смене
/// сессии/режима.

final class AppRouterProvider
    extends $FunctionalProvider<GoRouter, GoRouter, GoRouter>
    with $Provider<GoRouter> {
  /// Единственный `GoRouter` приложения: маршруты `$appRoutes` (routes.dart), маршруты режима планшета
  /// `kioskRoutes()` (kiosk_routes.dart, вне оболочки) и глобальный redirect (guards/). Пересчитывает redirect при смене
  /// сессии/режима.
  AppRouterProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appRouterProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appRouterHash();

  @$internal
  @override
  $ProviderElement<GoRouter> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  GoRouter create(Ref ref) {
    return appRouter(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(GoRouter value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<GoRouter>(value),
    );
  }
}

String _$appRouterHash() => r'ae832f9517900fd2ef88ccc0f0cc573f5f816b0b';

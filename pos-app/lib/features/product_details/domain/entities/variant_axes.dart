// Оси выбора варианта по характеристикам (02 SCR-14 UI-14-008, SCR-15; INV-012, INV-014).
// Чистый Dart (FL-01). Ось — характеристика, значения которой различаются между вариантами
// (`Variant.attributes`, порядок — как в 1С); если характеристик нет, ось одна — имя варианта.
import 'package:optomstroy/features/catalog/domain/entities/product.dart';

/// Вычисление осей и разрешение выбора в вариант.
abstract final class VariantAxes {
  /// Ключ оси «имя варианта» (у вариантов нет различающихся характеристик).
  static const String nameAxis = '';

  /// Видимые варианты (снятые с продажи у одного из нескольких скрываются, если есть другие).
  static List<Variant> visible(List<Variant> variants) {
    final List<Variant> sorted = <Variant>[...variants]
      ..sort((Variant a, Variant b) => a.sortOrder.compareTo(b.sortOrder));
    final List<Variant> active = <Variant>[
      for (final Variant v in sorted)
        if (!v.deletionMark) v,
    ];
    return active.isEmpty ? sorted : active;
  }

  /// Ключи осей в порядке первого появления; пусто — вариант один.
  static List<String> keys(List<Variant> variants) {
    if (variants.length < 2) return const <String>[];
    final List<String> order = <String>[];
    for (final Variant v in variants) {
      for (final String k in v.attributes.keys) {
        if (!order.contains(k)) order.add(k);
      }
    }
    final List<String> axes = <String>[
      for (final String k in order)
        if (variants.map((Variant v) => v.attributes[k]).toSet().length > 1) k,
    ];
    return axes.isEmpty ? const <String>[nameAxis] : axes;
  }

  /// Значение оси у варианта.
  static String? valueOf(Variant v, String axis) => axis == nameAxis ? (v.name ?? v.sku ?? v.id) : v.attributes[axis];

  /// Значения оси в порядке вариантов (без повторов).
  static List<String> valuesOf(List<Variant> variants, String axis) {
    final List<String> out = <String>[];
    for (final Variant v in variants) {
      final String? value = valueOf(v, axis);
      if (value != null && !out.contains(value)) out.add(value);
    }
    return out;
  }

  /// Выбор значения [value] оси [axis] при текущем варианте [current]: вариант с этим значением и
  /// теми же значениями остальных осей; если такого сочетания нет — первый вариант с этим значением.
  static Variant? resolve(List<Variant> variants, List<String> axes, Variant? current, String axis, String value) {
    Variant? fallback;
    for (final Variant v in variants) {
      if (valueOf(v, axis) != value) continue;
      fallback ??= v;
      final bool sameOthers =
          current == null ||
          axes.where((String a) => a != axis).every((String a) => valueOf(v, a) == valueOf(current, a));
      if (sameOthers) return v;
    }
    return fallback;
  }

  /// Есть ли вариант со значением [value] оси [axis] и значениями остальных осей как у [current].
  static bool combinationExists(
    List<Variant> variants,
    List<String> axes,
    Variant? current,
    String axis,
    String value,
  ) {
    if (current == null) return true;
    return variants.any(
      (Variant v) =>
          valueOf(v, axis) == value &&
          axes.where((String a) => a != axis).every((String a) => valueOf(v, a) == valueOf(current, a)),
    );
  }
}

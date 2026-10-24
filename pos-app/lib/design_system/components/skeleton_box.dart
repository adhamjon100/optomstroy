import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Форма `SkeletonBox` (03 §9.42).
enum SkeletonShape {
  /// Прямоугольник с заданным радиусом.
  box,

  /// Строка текста: высота = line-height, радиус `xs`.
  text,

  /// Круг (аватар).
  avatar,

  /// Изображение 1:1, радиус `md`.
  image,
}

/// Заполнитель загрузки `SkeletonBox` (03 §9.42): блок `skeletonBase` с шиммером
/// `skeletonHighlight` (ANIM-013, цикл 1,2 с; блик 40 % ширины). Под reduce-motion — статичный.
/// Для screen reader — один узел «Загрузка» на группу (передайте [semanticLabel] у первого блока
/// или оберните группу); сами блоки исключены из семантики.
class SkeletonBox extends StatefulWidget {
  /// Прямоугольник.
  const SkeletonBox({super.key, this.width, this.height = 16, this.radius, this.semanticLabel})
    : shape = SkeletonShape.box;

  /// Строка текста (высота = line-height шкалы, по умолчанию `body` 20).
  const SkeletonBox.text({super.key, this.width, this.height = 20, this.semanticLabel})
    : shape = SkeletonShape.text,
      radius = null;

  /// Круг диаметром [size].
  const SkeletonBox.avatar({super.key, double size = 40, this.semanticLabel})
    : shape = SkeletonShape.avatar,
      width = size,
      height = size,
      radius = null;

  /// Изображение 1:1 шириной [size] (по умолчанию — по ширине родителя).
  const SkeletonBox.image({super.key, double? size, this.semanticLabel})
    : shape = SkeletonShape.image,
      width = size,
      height = size,
      radius = null;

  /// Форма.
  final SkeletonShape shape;

  /// Ширина (`null` — по родителю).
  final double? width;

  /// Высота (`null` у `image` — квадрат по ширине).
  final double? height;

  /// Радиус прямоугольника (по умолчанию `xs`).
  final Radius? radius;

  /// «Загрузка» для screen reader.
  final String? semanticLabel;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: DsAnimations.skeletonShimmer.duration);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.motion.reduceMotion) {
      _c.stop();
    } else if (!_c.isAnimating) {
      unawaited(_c.repeat());
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool reduce = context.motion.reduceMotion;
    final BorderRadius? radius = switch (widget.shape) {
      SkeletonShape.avatar => null,
      SkeletonShape.image => BorderRadius.all(context.radii.md),
      SkeletonShape.text => BorderRadius.all(context.radii.xs),
      SkeletonShape.box => BorderRadius.all(widget.radius ?? context.radii.xs),
    };
    final BoxShape shape = widget.shape == SkeletonShape.avatar ? BoxShape.circle : BoxShape.rectangle;
    Widget box = reduce
        ? DecoratedBox(
            decoration: BoxDecoration(color: c.skeletonBase, borderRadius: radius, shape: shape),
          )
        : AnimatedBuilder(
            animation: _c,
            builder: (BuildContext context, Widget? _) {
              // Блик 40 % ширины едет слева направо (−0.4 … 1.4).
              final double x = -0.4 + 1.8 * _c.value;
              return DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  shape: shape,
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: <Color>[c.skeletonBase, c.skeletonHighlight, c.skeletonBase],
                    stops: <double>[(x - 0.2).clamp(0.0, 1.0), x.clamp(0.0, 1.0), (x + 0.2).clamp(0.0, 1.0)],
                  ),
                ),
              );
            },
          );
    if (widget.shape == SkeletonShape.image && widget.height == null) {
      box = AspectRatio(aspectRatio: 1, child: box);
    } else {
      box = SizedBox(width: widget.width, height: widget.height, child: box);
    }
    if (widget.semanticLabel != null) {
      return Semantics(
        label: widget.semanticLabel,
        liveRegion: false,
        child: ExcludeSemantics(child: box),
      );
    }
    return ExcludeSemantics(child: box);
  }
}

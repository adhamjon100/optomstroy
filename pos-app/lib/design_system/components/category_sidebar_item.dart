import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/word_safe_label.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Предок категории для подбора иконки ([CategoryIcons.resolve]): ключ иконки и название.
typedef CategoryIconSource = ({String? key, String name});

/// Иконки категорий (03 §14.4; указание владельца 2026-11-07 (15 §5.6): иконка у каждой категории и подкатегории,
/// как у корневых): по `iconKey` — глиф Material Symbols → ближайший глиф `Icons`; без ключа — по смыслу названия;
/// без совпадения — иконка ближайшего предка; иначе `category`. Дерева категорий дизайн-система не знает — предков даёт
/// фича (`categoryIcon`).
abstract final class CategoryIcons {
  /// Глиф по ключу; неизвестный ключ, `category` и `null` — `category`.
  static IconData of(String? key) => switch (key) {
    'plumbing' || 'valve' => Icons.plumbing_rounded,
    'bathtub' => Icons.bathtub_rounded,
    'heat' || 'thermostat' => Icons.thermostat_rounded,
    'water_drop' => Icons.water_drop_rounded,
    'electrical_services' => Icons.electrical_services_rounded,
    'grid_on' => Icons.grid_on_rounded,
    'hardware' => Icons.hardware_rounded,
    'water_damage' => Icons.water_damage_rounded,
    'star' => Icons.star_rounded,
    'history' => Icons.history_rounded,
    _ => Icons.category_rounded,
  };

  /// Глиф категории без картинки — одно правило для всех мест, где рисуется категория (колонка, лента, «Все
  /// категории», главная клиента, список SB, киоск; картинка категории из данных — выше по приоритету, её здесь нет):
  /// 1) известный [key] (03 §14.4); 2) по смыслу названия [name] ([match]); 3) то же у предков [ancestors] — от
  /// ближайшего (родитель) к корню; 4) запасной `category`. Пустого места и глифа «четыре квадрата» у категории нет
  /// («четыре квадрата» — только у «Все товары», это не категория). Картинка не выдумывается: это только иконка.
  static IconData resolve({
    String? key,
    String? name,
    Iterable<CategoryIconSource> ancestors = const <CategoryIconSource>[],
  }) {
    final IconData? own = match(key: key, name: name);
    if (own != null) {
      return own;
    }
    for (final CategoryIconSource a in ancestors) {
      final IconData? inherited = match(key: a.key, name: a.name);
      if (inherited != null) {
        return inherited;
      }
    }
    return Icons.category_rounded;
  }

  /// Иконка самой категории — по известному [key], иначе по названию [name]; `null` — не подобрать (у
  /// [resolve] — следующая ступень: предок). Название: нижний регистр, «ё» → «е», слова — буквы и цифры (в т. ч.
  /// кыргызские «ү», «ө», «ң»); слова перебираются по порядку (главное слово названия идёт первым: «Трубы отопления» —
  /// трубы), для каждого — правила [_byName] по порядку; совпадение — начало слова (корень), а не любая подстрока:
  /// «Утеплитель» — не «тепл», «Экраны для ванн» — не «кран», «Воздушные» — не «душ».
  static IconData? match({String? key, String? name}) {
    final IconData byKey = of(key);
    if (byKey != Icons.category_rounded) {
      return byKey;
    }
    if (name == null || name.isEmpty) {
      return null;
    }
    final String n = name.toLowerCase().replaceAll('ё', 'е');
    for (final RegExpMatch m in _word.allMatches(n)) {
      final String word = m[0]!;
      for (final (List<String> stems, IconData icon) in _byName) {
        if (stems.any(word.startsWith)) {
          return icon;
        }
      }
    }
    return null;
  }

  /// Слово названия: буквы и цифры Unicode.
  static final RegExp _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  /// Корни слов названий → глиф (03 §14.4; порядок важен — первое совпадение; составные слова — отдельными корнями
  /// раньше общих: «воздуховод» до «воздух», «вентилятор» до «вентил», «теплоизол»/«утепл» до «тепл»,
  /// «электроинструмент» и «электроды» до «электр»; у электродов — формы «электроды», «электродов» и
  /// «электрододерж», а не корень «электрод»: он поймал бы «электродвигатель», «электродрель», «электродный котёл»).
  /// Русские корни и кыргызские [ТИПОВО] (проверить у переводчика `app_ky.arb`).
  static const List<(List<String>, IconData)> _byName = <(List<String>, IconData)>[
    (<String>['воздуховод', 'вытяжк', 'рекуперат'], Icons.hvac_rounded),
    (<String>['вентиляц', 'вентилятор', 'кондицион', 'воздух', 'воздуш', 'сплит', 'желдет'], Icons.air_rounded),
    (<String>['смесител', 'кран', 'вентил', 'клапан', 'сифон', 'аралаштыргыч'], Icons.plumbing_rounded),
    (<String>['канализац'], Icons.water_damage_rounded),
    (<String>['унитаз', 'инсталляц', 'биде', 'писсуар', 'даараткан'], Icons.wc_rounded),
    (<String>['душ', 'поддон'], Icons.shower_rounded),
    (<String>['раковин', 'умывальн', 'мойк'], Icons.wash_rounded),
    (<String>['сантехник', 'санфаянс', 'ванн'], Icons.bathtub_rounded),
    (<String>['котл', 'котел', 'газов', 'горелк', 'камин'], Icons.local_fire_department_rounded),
    (
      <String>['теплоизол', 'утепл', 'изоляц', 'гидроизол', 'пароизол', 'минват', 'пенопласт', 'пеноплекс', 'жылуулоо'],
      Icons.texture_rounded,
    ),
    (<String>['отоплен', 'радиатор', 'тепл', 'термо', 'полотенцесуш', 'жылыт', 'жылуу'], Icons.thermostat_rounded),
    (<String>['водоснаб', 'водопровод', 'водонагрев', 'бойлер', 'насос', 'суу'], Icons.water_drop_rounded),
    (<String>['труб', 'фитинг', 'металлопласт', 'ппр', 'муфт', 'тройник', 'түтүк'], Icons.plumbing_rounded),
    (<String>['кабел', 'провод', 'зым'], Icons.cable_rounded),
    (<String>['розет', 'выключат'], Icons.outlet_rounded),
    (<String>['светил', 'освещ', 'ламп', 'люстр', 'прожектор', 'фонар', 'чырак', 'жарык'], Icons.lightbulb_rounded),
    (<String>['электроинструмент', 'дрел', 'перфорат', 'шуруповерт', 'болгарк', 'лобзик'], Icons.construction_rounded),
    (<String>['сварк', 'сварочн', 'электроды', 'электродов', 'электрододерж'], Icons.bolt_rounded),
    (<String>['электр'], Icons.electrical_services_rounded),
    (<String>['плитк', 'плиточ', 'кафел', 'керамогран', 'мозаик', 'брусчат', 'тротуарн'], Icons.grid_on_rounded),
    (
      <String>[
        'крепеж',
        'метиз',
        'саморез',
        'шуруп',
        'болт',
        'гайк',
        'шайб',
        'дюбел',
        'анкер',
        'гвозд',
        'заклеп',
        'фурнитур',
        'бекит',
      ],
      Icons.hardware_rounded,
    ),
    (<String>['инструмент', 'курал'], Icons.handyman_rounded),
    (<String>['обои', 'обоев'], Icons.wallpaper_rounded),
    (<String>['краск', 'лакокрас', 'эмал', 'грунтовк', 'лак', 'боек'], Icons.format_paint_rounded),
    (<String>['гипсокартон', 'гкл', 'профил', 'фанер', 'осб', 'дсп', 'двп', 'лист'], Icons.layers_rounded),
    (<String>['кровл', 'черепиц', 'профнастил', 'водосток', 'шифер'], Icons.roofing_rounded),
    (<String>['двер', 'замк', 'скобян', 'эшик'], Icons.door_front_door_rounded),
    (<String>['окн', 'окон', 'подоконник', 'терезе'], Icons.window_rounded),
    (<String>['сад', 'огород', 'полив', 'шланг', 'бакча'], Icons.yard_rounded),
    (<String>['пиломатериал', 'древесин', 'брус', 'доск', 'вагонк', 'жыгач'], Icons.carpenter_rounded),
    (<String>['лестниц', 'стремян'], Icons.stairs_rounded),
    (<String>['химия', 'чистящ', 'моющ', 'уборк', 'хозтовар', 'хозяйствен'], Icons.cleaning_services_rounded),
    (<String>['спецодежд', 'перчатк', 'одежд'], Icons.checkroom_rounded),
    (
      <String>[
        'строител',
        'стройматериал',
        'смес',
        'цемент',
        'кирпич',
        'бетон',
        'штукатур',
        'шпакл',
        'шпатл',
        'наливн',
        'клей',
        'затирк',
        'курулуш',
      ],
      Icons.foundation_rounded,
    ),
    (<String>['герметик', 'силикон', 'пена', 'пены'], Icons.format_color_fill_rounded),
    (<String>['ламинат', 'линолеум', 'паркет', 'ковролин', 'плинтус'], Icons.table_rows_rounded),
    (<String>['счетчик', 'водомер', 'манометр'], Icons.speed_rounded),
  ];
}

/// Изображение категории из 1С (Q-022), иначе иконка категории ([CategoryIcons.resolve]: `iconKey`, название, предок,
/// `category`; CAT-009): поле [size] ([width] × [height]), картинка вписывается [fit] (по умолчанию `contain`) с
/// качеством [filterQuality] (по умолчанию `high`), без фона и скругления (ADR-114: плитки колонки и ленты каталога);
/// фон [background] и скругление [radius] — по запросу (пункт списка `CategorySidebarItem`, плитка листа «Все
/// категории»). Нет картинки или ошибка загрузки — [fallback] (по умолчанию — иконка [icon], иначе по
/// `iconKey`/названию); фото товара не подставляется. Появление — fade 200 мс только у первого кадра, смена URL — без
/// мигания (`gaplessPlayback`).
class CategoryImage extends StatelessWidget {
  /// Создаёт изображение.
  const CategoryImage({
    super.key,
    this.imageUrl,
    this.iconKey,
    this.name,
    this.icon,
    this.size = 32,
    this.width,
    this.height,
    this.iconSize = 24,
    this.color,
    this.background,
    this.radius,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.high,
    this.fallback,
  });

  /// URL изображения категории (`thumb`).
  final String? imageUrl;

  /// Ключ иконки.
  final String? iconKey;

  /// Название категории — подбор иконки по смыслу, если [iconKey] нет ([CategoryIcons.resolve]).
  final String? name;

  /// Иконка категории, подобранная вызывающим с учётом предков (`categoryIcon` фичи); `null` — по
  /// [iconKey]/[name] самой категории.
  final IconData? icon;

  /// Сторона поля.
  final double size;

  /// Ширина/высота прямоугольного поля (лента подкатегорий); по умолчанию — [size].
  final double? width;
  final double? height;

  /// Фон поля; `null` — без фона (ADR-114).
  final Color? background;

  /// Скругление поля (обрезка картинки); `null` — без скругления и обрезки (ADR-114).
  final BorderRadius? radius;

  /// Размер иконки.
  final double iconSize;

  /// Цвет иконки (по умолчанию `textSecondary`).
  final Color? color;

  /// Вписывание картинки: `contain` (плитка колонки, прототип), `scaleDown` (карточка ленты — без увеличения),
  /// `cover` (пункт списка `CategorySidebarItem`, плитка листа «Все категории»).
  final BoxFit fit;

  /// Качество масштабирования картинки (по умолчанию `high`: картинки категорий мелкие, 45–65 px по ширине).
  final FilterQuality filterQuality;

  /// Что показать без картинки и при ошибке загрузки; `null` — иконка [icon] (иначе по `iconKey`/названию) размера
  /// [iconSize].
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Widget placeholder =
        fallback ??
        Center(
          key: const ValueKey<String>('category-image-icon'),
          child: Icon(
            icon ?? CategoryIcons.resolve(key: iconKey, name: name),
            size: iconSize,
            color: color ?? c.textSecondary,
          ),
        );
    final double w = width ?? size;
    final double h = height ?? size;
    final String? url = imageUrl;
    final Widget content;
    if (url == null || url.isEmpty) {
      content = placeholder;
    } else {
      // Путь `/images/…` от сервера — от адреса API (ProductImageBase), как у фото товара.
      final ImageProvider<Object> provider = (ProductImageScope.maybeOf(context) ?? CachedNetworkImageProvider.new)(
        ProductImageBase.resolve(context, url),
      );
      content = Image(
        image: ResizeImage.resizeIfNeeded(ProductImage.cacheWidthOf(ProductImageSize.thumb), null, provider),
        width: w,
        height: h,
        // Смена категории в ленте/сайдбаре не гасит уже показанную картинку (без мигания, заказчик 2026-10-28).
        gaplessPlayback: true,
        fit: fit,
        filterQuality: filterQuality,
        frameBuilder: (BuildContext context, Widget child, int? frame, bool sync) {
          if (sync) {
            return child;
          }
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: context.motion.of(const Duration(milliseconds: 200)),
            child: child,
          );
        },
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) => placeholder,
      );
    }
    final Widget box = Container(width: w, height: h, color: background, child: content);
    final BorderRadius? r = radius;
    return r == null || r == BorderRadius.zero ? box : ClipRRect(borderRadius: r, child: box);
  }
}

/// Вариант `CategorySidebarItem` (03 §9.8).
enum CategorySidebarItemVariant {
  /// Корневой пункт: изображение 32, `body 500`.
  root,

  /// Подкатегория: отступ +24, изображение 24, `body 400`.
  child,

  /// «★ Избранное 27» — отдельная карточка.
  favorites,
}

/// Пункт меню категорий `CategorySidebarItem` (03 §9.8; 02 UI-10-009): строка-карточка 52
/// (48 при compact-плотности) → изображение/иконка → название → счётчик-пилюля → [шеврон].
/// Иконка без картинки — [icon] (подкатегория — с учётом предка, `categoryIcon` фичи), иначе по `iconKey`/названию
/// ([CategoryIcons.resolve]), как у плиток колонки.
/// Выбранный — `primaryContainer` + полоса 3 lp `primaryText` + текст `primaryText 600`.
/// Повторный тап по выбранному — без действия (03 §9.8). Свёрнутый сайдбар (72) — [collapsed].
class CategorySidebarItem extends StatelessWidget {
  /// Создаёт пункт.
  const CategorySidebarItem({
    super.key,
    required this.label,
    required this.onTap,
    this.count,
    this.variant = CategorySidebarItemVariant.root,
    this.imageUrl,
    this.iconKey,
    this.icon,
    this.selected = false,
    this.hasChildren = false,
    this.expanded = false,
    this.onToggleExpanded,
    this.collapsed = false,
    this.dense = false,
    this.semanticLabel,
    this.expandLabel,
  });

  /// Название.
  final String label;

  /// Открыть категорию (SCR-12).
  final VoidCallback? onTap;

  /// Счётчик товаров (`productCount`); `null` — без счётчика.
  final int? count;

  /// Вариант.
  final CategorySidebarItemVariant variant;

  /// Изображение 1С.
  final String? imageUrl;

  /// Ключ иконки.
  final String? iconKey;

  /// Иконка категории без картинки, подобранная вызывающим с учётом предков; `null` — по [iconKey]/[label].
  final IconData? icon;

  /// Выбран.
  final bool selected;

  /// Есть подкатегории (шеврон).
  final bool hasChildren;

  /// Подкатегории раскрыты.
  final bool expanded;

  /// Шеврон.
  final VoidCallback? onToggleExpanded;

  /// Свёрнутый сайдбар 72: только изображение + точка-счётчик.
  final bool collapsed;

  /// Высота 48 (compact-плотность) вместо 52.
  final bool dense;

  /// «Смесители, 124 товара».
  final String? semanticLabel;

  /// Подпись шеврона для screen reader.
  final String? expandLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool isChild = variant == CategorySidebarItemVariant.child;
    final bool isFav = variant == CategorySidebarItemVariant.favorites;
    final double height = isChild ? 48 : (dense ? 48 : 52);
    final Widget image = isFav
        ? SizedBox.square(
            dimension: 32,
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Icon(Icons.star_rounded, size: 24, color: c.favorite),
                  Icon(Icons.star_border_rounded, size: 24, color: c.warning),
                ],
              ),
            ),
          )
        : CategoryImage(
            imageUrl: imageUrl,
            iconKey: iconKey,
            name: label,
            icon: icon,
            size: isChild ? 24 : 32,
            iconSize: isChild ? 18 : 24,
            color: selected ? c.primaryText : null,
            // Пункт списка — прежний вид: поле `surfaceVariant`, скругление `sm`, `cover`.
            background: c.surfaceVariant,
            radius: BorderRadius.all(context.radii.sm),
            fit: BoxFit.cover,
          );
    return Semantics(
      button: true,
      selected: selected,
      expanded: hasChildren ? expanded : null,
      label: semanticLabel ?? (count == null ? label : '$label, $count'),
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator: жест DsInteractive из семантики исключён.
      onTap: selected ? null : onTap,
      child: _MaybeTooltip(
        message: collapsed ? (semanticLabel ?? label) : null,
        child: DsInteractive(
          onTap: selected ? null : onTap,
          enabled: onTap != null,
          builder: (BuildContext context, DsInteractionState s) {
            final Color bg = selected
                ? c.primaryContainer
                : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface));
            final Widget row = collapsed
                ? Center(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        image,
                        if ((count ?? 0) > 0)
                          PositionedDirectional(
                            top: -2,
                            end: -2,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(color: c.primaryText, shape: BoxShape.circle),
                            ),
                          ),
                      ],
                    ),
                  )
                : Row(
                    children: <Widget>[
                      image,
                      SizedBox(width: context.space.s3),
                      // Длинное название — в 2 строки, а не обрезка на первом слове (FIX-EF-13); перенос только между
                      // словами — «Смесит|ели» не бывает (03 §9.10; указание владельца 2026-11-18).
                      Expanded(
                        child: DsWordSafeLabel(
                          text: label,
                          textAlign: TextAlign.start,
                          style: context.text.body.copyWith(
                            color: selected ? c.primaryText : c.textPrimary,
                            fontWeight: selected ? FontWeight.w600 : (isChild ? FontWeight.w400 : FontWeight.w500),
                          ),
                        ),
                      ),
                      if (count != null) ...<Widget>[SizedBox(width: context.space.s2), _CountPill(count: count!)],
                      if (hasChildren)
                        Semantics(
                          button: true,
                          label: expandLabel,
                          child: InkResponse(
                            onTap: onToggleExpanded,
                            radius: 20,
                            child: SizedBox.square(
                              dimension: 32,
                              child: AnimatedRotation(
                                turns: expanded ? 0.5 : 0,
                                duration: context.motion.of(context.motion.base),
                                child: Icon(Icons.expand_more_rounded, size: 20, color: c.textSecondary),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
            return DsFocusRing(
              visible: s.focused,
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: bg,
                  border: selected ? Border(left: BorderSide(color: c.primaryText, width: 3)) : null,
                ),
                padding: EdgeInsetsDirectional.only(
                  start: collapsed ? 0 : (isChild ? context.space.s3 + 24 : context.space.s3) - (selected ? 3 : 0),
                  end: collapsed ? 0 : context.space.s2,
                ),
                child: row,
              ),
            );
          },
        ),
      ),
    );
  }

  /// Скелетон пункта (loading): `SkeletonBox` 32×32 + строка 60 % + пилюля 32.
  static Widget skeleton(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.s3),
      child: Row(
        children: <Widget>[
          const SkeletonBox(width: 32, height: 32),
          SizedBox(width: context.space.s3),
          const Expanded(
            child: FractionallySizedBox(
              widthFactor: 0.6,
              alignment: AlignmentDirectional.centerStart,
              child: SkeletonBox.text(height: 14),
            ),
          ),
          SizedBox(width: context.space.s2),
          const SkeletonBox(width: 32, height: 20),
        ],
      ),
    ),
  );
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.space.s2, vertical: 2),
      decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.full)),
      child: Text(
        '$count',
        style: context.text.label.copyWith(
          color: count == 0 ? c.textTertiary : c.textSecondary,
          fontWeight: FontWeight.w500,
          fontFeatures: DsTypography.numeric,
        ),
      ),
    );
  }
}

class _MaybeTooltip extends StatelessWidget {
  const _MaybeTooltip({required this.message, required this.child});

  final String? message;
  final Widget child;

  @override
  Widget build(BuildContext context) => message == null ? child : Tooltip(message: message, child: child);
}

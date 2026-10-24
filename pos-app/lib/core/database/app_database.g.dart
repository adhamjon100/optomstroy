// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $LocalCategoriesTable extends LocalCategories
    with TableInfo<$LocalCategoriesTable, CategoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalCategoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameNormMeta = const VerificationMeta(
    'nameNorm',
  );
  @override
  late final GeneratedColumn<String> nameNorm = GeneratedColumn<String>(
    'name_norm',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _depthMeta = const VerificationMeta('depth');
  @override
  late final GeneratedColumn<int> depth = GeneratedColumn<int>(
    'depth',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _iconKeyMeta = const VerificationMeta(
    'iconKey',
  );
  @override
  late final GeneratedColumn<String> iconKey = GeneratedColumn<String>(
    'icon_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _imageShaMeta = const VerificationMeta(
    'imageSha',
  );
  @override
  late final GeneratedColumn<String> imageSha = GeneratedColumn<String>(
    'image_sha',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _productCountMeta = const VerificationMeta(
    'productCount',
  );
  @override
  late final GeneratedColumn<int> productCount = GeneratedColumn<int>(
    'product_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isVisibleMeta = const VerificationMeta(
    'isVisible',
  );
  @override
  late final GeneratedColumn<bool> isVisible = GeneratedColumn<bool>(
    'is_visible',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_visible" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _deletionMarkMeta = const VerificationMeta(
    'deletionMark',
  );
  @override
  late final GeneratedColumn<bool> deletionMark = GeneratedColumn<bool>(
    'deletion_mark',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deletion_mark" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _serverUpdatedAtMeta = const VerificationMeta(
    'serverUpdatedAt',
  );
  @override
  late final GeneratedColumn<int> serverUpdatedAt = GeneratedColumn<int>(
    'server_updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    parentId,
    name,
    nameNorm,
    path,
    depth,
    sortOrder,
    iconKey,
    imageSha,
    productCount,
    isVisible,
    deletionMark,
    serverUpdatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'categories';
  @override
  VerificationContext validateIntegrity(
    Insertable<CategoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('name_norm')) {
      context.handle(
        _nameNormMeta,
        nameNorm.isAcceptableOrUnknown(data['name_norm']!, _nameNormMeta),
      );
    } else if (isInserting) {
      context.missing(_nameNormMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('depth')) {
      context.handle(
        _depthMeta,
        depth.isAcceptableOrUnknown(data['depth']!, _depthMeta),
      );
    } else if (isInserting) {
      context.missing(_depthMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('icon_key')) {
      context.handle(
        _iconKeyMeta,
        iconKey.isAcceptableOrUnknown(data['icon_key']!, _iconKeyMeta),
      );
    }
    if (data.containsKey('image_sha')) {
      context.handle(
        _imageShaMeta,
        imageSha.isAcceptableOrUnknown(data['image_sha']!, _imageShaMeta),
      );
    }
    if (data.containsKey('product_count')) {
      context.handle(
        _productCountMeta,
        productCount.isAcceptableOrUnknown(
          data['product_count']!,
          _productCountMeta,
        ),
      );
    }
    if (data.containsKey('is_visible')) {
      context.handle(
        _isVisibleMeta,
        isVisible.isAcceptableOrUnknown(data['is_visible']!, _isVisibleMeta),
      );
    }
    if (data.containsKey('deletion_mark')) {
      context.handle(
        _deletionMarkMeta,
        deletionMark.isAcceptableOrUnknown(
          data['deletion_mark']!,
          _deletionMarkMeta,
        ),
      );
    }
    if (data.containsKey('server_updated_at')) {
      context.handle(
        _serverUpdatedAtMeta,
        serverUpdatedAt.isAcceptableOrUnknown(
          data['server_updated_at']!,
          _serverUpdatedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverUpdatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CategoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CategoryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      nameNorm: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name_norm'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      depth: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}depth'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      iconKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}icon_key'],
      ),
      imageSha: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}image_sha'],
      ),
      productCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}product_count'],
      )!,
      isVisible: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_visible'],
      )!,
      deletionMark: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deletion_mark'],
      )!,
      serverUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_updated_at'],
      )!,
    );
  }

  @override
  $LocalCategoriesTable createAlias(String alias) {
    return $LocalCategoriesTable(attachedDatabase, alias);
  }
}

class CategoryRow extends DataClass implements Insertable<CategoryRow> {
  final String id;
  final String? parentId;
  final String name;
  final String nameNorm;
  final String path;
  final int depth;
  final int sortOrder;
  final String? iconKey;
  final String? imageSha;
  final int productCount;
  final bool isVisible;
  final bool deletionMark;
  final int serverUpdatedAt;
  const CategoryRow({
    required this.id,
    this.parentId,
    required this.name,
    required this.nameNorm,
    required this.path,
    required this.depth,
    required this.sortOrder,
    this.iconKey,
    this.imageSha,
    required this.productCount,
    required this.isVisible,
    required this.deletionMark,
    required this.serverUpdatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['name'] = Variable<String>(name);
    map['name_norm'] = Variable<String>(nameNorm);
    map['path'] = Variable<String>(path);
    map['depth'] = Variable<int>(depth);
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || iconKey != null) {
      map['icon_key'] = Variable<String>(iconKey);
    }
    if (!nullToAbsent || imageSha != null) {
      map['image_sha'] = Variable<String>(imageSha);
    }
    map['product_count'] = Variable<int>(productCount);
    map['is_visible'] = Variable<bool>(isVisible);
    map['deletion_mark'] = Variable<bool>(deletionMark);
    map['server_updated_at'] = Variable<int>(serverUpdatedAt);
    return map;
  }

  LocalCategoriesCompanion toCompanion(bool nullToAbsent) {
    return LocalCategoriesCompanion(
      id: Value(id),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      name: Value(name),
      nameNorm: Value(nameNorm),
      path: Value(path),
      depth: Value(depth),
      sortOrder: Value(sortOrder),
      iconKey: iconKey == null && nullToAbsent
          ? const Value.absent()
          : Value(iconKey),
      imageSha: imageSha == null && nullToAbsent
          ? const Value.absent()
          : Value(imageSha),
      productCount: Value(productCount),
      isVisible: Value(isVisible),
      deletionMark: Value(deletionMark),
      serverUpdatedAt: Value(serverUpdatedAt),
    );
  }

  factory CategoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CategoryRow(
      id: serializer.fromJson<String>(json['id']),
      parentId: serializer.fromJson<String?>(json['parentId']),
      name: serializer.fromJson<String>(json['name']),
      nameNorm: serializer.fromJson<String>(json['nameNorm']),
      path: serializer.fromJson<String>(json['path']),
      depth: serializer.fromJson<int>(json['depth']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      iconKey: serializer.fromJson<String?>(json['iconKey']),
      imageSha: serializer.fromJson<String?>(json['imageSha']),
      productCount: serializer.fromJson<int>(json['productCount']),
      isVisible: serializer.fromJson<bool>(json['isVisible']),
      deletionMark: serializer.fromJson<bool>(json['deletionMark']),
      serverUpdatedAt: serializer.fromJson<int>(json['serverUpdatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'parentId': serializer.toJson<String?>(parentId),
      'name': serializer.toJson<String>(name),
      'nameNorm': serializer.toJson<String>(nameNorm),
      'path': serializer.toJson<String>(path),
      'depth': serializer.toJson<int>(depth),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'iconKey': serializer.toJson<String?>(iconKey),
      'imageSha': serializer.toJson<String?>(imageSha),
      'productCount': serializer.toJson<int>(productCount),
      'isVisible': serializer.toJson<bool>(isVisible),
      'deletionMark': serializer.toJson<bool>(deletionMark),
      'serverUpdatedAt': serializer.toJson<int>(serverUpdatedAt),
    };
  }

  CategoryRow copyWith({
    String? id,
    Value<String?> parentId = const Value.absent(),
    String? name,
    String? nameNorm,
    String? path,
    int? depth,
    int? sortOrder,
    Value<String?> iconKey = const Value.absent(),
    Value<String?> imageSha = const Value.absent(),
    int? productCount,
    bool? isVisible,
    bool? deletionMark,
    int? serverUpdatedAt,
  }) => CategoryRow(
    id: id ?? this.id,
    parentId: parentId.present ? parentId.value : this.parentId,
    name: name ?? this.name,
    nameNorm: nameNorm ?? this.nameNorm,
    path: path ?? this.path,
    depth: depth ?? this.depth,
    sortOrder: sortOrder ?? this.sortOrder,
    iconKey: iconKey.present ? iconKey.value : this.iconKey,
    imageSha: imageSha.present ? imageSha.value : this.imageSha,
    productCount: productCount ?? this.productCount,
    isVisible: isVisible ?? this.isVisible,
    deletionMark: deletionMark ?? this.deletionMark,
    serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
  );
  CategoryRow copyWithCompanion(LocalCategoriesCompanion data) {
    return CategoryRow(
      id: data.id.present ? data.id.value : this.id,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      name: data.name.present ? data.name.value : this.name,
      nameNorm: data.nameNorm.present ? data.nameNorm.value : this.nameNorm,
      path: data.path.present ? data.path.value : this.path,
      depth: data.depth.present ? data.depth.value : this.depth,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      iconKey: data.iconKey.present ? data.iconKey.value : this.iconKey,
      imageSha: data.imageSha.present ? data.imageSha.value : this.imageSha,
      productCount: data.productCount.present
          ? data.productCount.value
          : this.productCount,
      isVisible: data.isVisible.present ? data.isVisible.value : this.isVisible,
      deletionMark: data.deletionMark.present
          ? data.deletionMark.value
          : this.deletionMark,
      serverUpdatedAt: data.serverUpdatedAt.present
          ? data.serverUpdatedAt.value
          : this.serverUpdatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CategoryRow(')
          ..write('id: $id, ')
          ..write('parentId: $parentId, ')
          ..write('name: $name, ')
          ..write('nameNorm: $nameNorm, ')
          ..write('path: $path, ')
          ..write('depth: $depth, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('iconKey: $iconKey, ')
          ..write('imageSha: $imageSha, ')
          ..write('productCount: $productCount, ')
          ..write('isVisible: $isVisible, ')
          ..write('deletionMark: $deletionMark, ')
          ..write('serverUpdatedAt: $serverUpdatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    parentId,
    name,
    nameNorm,
    path,
    depth,
    sortOrder,
    iconKey,
    imageSha,
    productCount,
    isVisible,
    deletionMark,
    serverUpdatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CategoryRow &&
          other.id == this.id &&
          other.parentId == this.parentId &&
          other.name == this.name &&
          other.nameNorm == this.nameNorm &&
          other.path == this.path &&
          other.depth == this.depth &&
          other.sortOrder == this.sortOrder &&
          other.iconKey == this.iconKey &&
          other.imageSha == this.imageSha &&
          other.productCount == this.productCount &&
          other.isVisible == this.isVisible &&
          other.deletionMark == this.deletionMark &&
          other.serverUpdatedAt == this.serverUpdatedAt);
}

class LocalCategoriesCompanion extends UpdateCompanion<CategoryRow> {
  final Value<String> id;
  final Value<String?> parentId;
  final Value<String> name;
  final Value<String> nameNorm;
  final Value<String> path;
  final Value<int> depth;
  final Value<int> sortOrder;
  final Value<String?> iconKey;
  final Value<String?> imageSha;
  final Value<int> productCount;
  final Value<bool> isVisible;
  final Value<bool> deletionMark;
  final Value<int> serverUpdatedAt;
  final Value<int> rowid;
  const LocalCategoriesCompanion({
    this.id = const Value.absent(),
    this.parentId = const Value.absent(),
    this.name = const Value.absent(),
    this.nameNorm = const Value.absent(),
    this.path = const Value.absent(),
    this.depth = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.iconKey = const Value.absent(),
    this.imageSha = const Value.absent(),
    this.productCount = const Value.absent(),
    this.isVisible = const Value.absent(),
    this.deletionMark = const Value.absent(),
    this.serverUpdatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalCategoriesCompanion.insert({
    required String id,
    this.parentId = const Value.absent(),
    required String name,
    required String nameNorm,
    required String path,
    required int depth,
    this.sortOrder = const Value.absent(),
    this.iconKey = const Value.absent(),
    this.imageSha = const Value.absent(),
    this.productCount = const Value.absent(),
    this.isVisible = const Value.absent(),
    this.deletionMark = const Value.absent(),
    required int serverUpdatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       nameNorm = Value(nameNorm),
       path = Value(path),
       depth = Value(depth),
       serverUpdatedAt = Value(serverUpdatedAt);
  static Insertable<CategoryRow> custom({
    Expression<String>? id,
    Expression<String>? parentId,
    Expression<String>? name,
    Expression<String>? nameNorm,
    Expression<String>? path,
    Expression<int>? depth,
    Expression<int>? sortOrder,
    Expression<String>? iconKey,
    Expression<String>? imageSha,
    Expression<int>? productCount,
    Expression<bool>? isVisible,
    Expression<bool>? deletionMark,
    Expression<int>? serverUpdatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (parentId != null) 'parent_id': parentId,
      if (name != null) 'name': name,
      if (nameNorm != null) 'name_norm': nameNorm,
      if (path != null) 'path': path,
      if (depth != null) 'depth': depth,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (iconKey != null) 'icon_key': iconKey,
      if (imageSha != null) 'image_sha': imageSha,
      if (productCount != null) 'product_count': productCount,
      if (isVisible != null) 'is_visible': isVisible,
      if (deletionMark != null) 'deletion_mark': deletionMark,
      if (serverUpdatedAt != null) 'server_updated_at': serverUpdatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalCategoriesCompanion copyWith({
    Value<String>? id,
    Value<String?>? parentId,
    Value<String>? name,
    Value<String>? nameNorm,
    Value<String>? path,
    Value<int>? depth,
    Value<int>? sortOrder,
    Value<String?>? iconKey,
    Value<String?>? imageSha,
    Value<int>? productCount,
    Value<bool>? isVisible,
    Value<bool>? deletionMark,
    Value<int>? serverUpdatedAt,
    Value<int>? rowid,
  }) {
    return LocalCategoriesCompanion(
      id: id ?? this.id,
      parentId: parentId ?? this.parentId,
      name: name ?? this.name,
      nameNorm: nameNorm ?? this.nameNorm,
      path: path ?? this.path,
      depth: depth ?? this.depth,
      sortOrder: sortOrder ?? this.sortOrder,
      iconKey: iconKey ?? this.iconKey,
      imageSha: imageSha ?? this.imageSha,
      productCount: productCount ?? this.productCount,
      isVisible: isVisible ?? this.isVisible,
      deletionMark: deletionMark ?? this.deletionMark,
      serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (nameNorm.present) {
      map['name_norm'] = Variable<String>(nameNorm.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (depth.present) {
      map['depth'] = Variable<int>(depth.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (iconKey.present) {
      map['icon_key'] = Variable<String>(iconKey.value);
    }
    if (imageSha.present) {
      map['image_sha'] = Variable<String>(imageSha.value);
    }
    if (productCount.present) {
      map['product_count'] = Variable<int>(productCount.value);
    }
    if (isVisible.present) {
      map['is_visible'] = Variable<bool>(isVisible.value);
    }
    if (deletionMark.present) {
      map['deletion_mark'] = Variable<bool>(deletionMark.value);
    }
    if (serverUpdatedAt.present) {
      map['server_updated_at'] = Variable<int>(serverUpdatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalCategoriesCompanion(')
          ..write('id: $id, ')
          ..write('parentId: $parentId, ')
          ..write('name: $name, ')
          ..write('nameNorm: $nameNorm, ')
          ..write('path: $path, ')
          ..write('depth: $depth, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('iconKey: $iconKey, ')
          ..write('imageSha: $imageSha, ')
          ..write('productCount: $productCount, ')
          ..write('isVisible: $isVisible, ')
          ..write('deletionMark: $deletionMark, ')
          ..write('serverUpdatedAt: $serverUpdatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalProductsTable extends LocalProducts
    with TableInfo<$LocalProductsTable, ProductRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalProductsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _skuMeta = const VerificationMeta('sku');
  @override
  late final GeneratedColumn<String> sku = GeneratedColumn<String>(
    'sku',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _skuNormMeta = const VerificationMeta(
    'skuNorm',
  );
  @override
  late final GeneratedColumn<String> skuNorm = GeneratedColumn<String>(
    'sku_norm',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameNormMeta = const VerificationMeta(
    'nameNorm',
  );
  @override
  late final GeneratedColumn<String> nameNorm = GeneratedColumn<String>(
    'name_norm',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _brandMeta = const VerificationMeta('brand');
  @override
  late final GeneratedColumn<String> brand = GeneratedColumn<String>(
    'brand',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _categoryIdMeta = const VerificationMeta(
    'categoryId',
  );
  @override
  late final GeneratedColumn<String> categoryId = GeneratedColumn<String>(
    'category_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseUnitCodeMeta = const VerificationMeta(
    'baseUnitCode',
  );
  @override
  late final GeneratedColumn<String> baseUnitCode = GeneratedColumn<String>(
    'base_unit_code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _qtyPrecisionMeta = const VerificationMeta(
    'qtyPrecision',
  );
  @override
  late final GeneratedColumn<int> qtyPrecision = GeneratedColumn<int>(
    'qty_precision',
    aliasedName,
    false,
    check: () => ComparableExpr(qtyPrecision).isBetweenValues(0, 3),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hasVariantsMeta = const VerificationMeta(
    'hasVariants',
  );
  @override
  late final GeneratedColumn<bool> hasVariants = GeneratedColumn<bool>(
    'has_variants',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_variants" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isSellableMeta = const VerificationMeta(
    'isSellable',
  );
  @override
  late final GeneratedColumn<bool> isSellable = GeneratedColumn<bool>(
    'is_sellable',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_sellable" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _multiplicityMilliMeta = const VerificationMeta(
    'multiplicityMilli',
  );
  @override
  late final GeneratedColumn<int> multiplicityMilli = GeneratedColumn<int>(
    'multiplicity_milli',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _minQtyMilliMeta = const VerificationMeta(
    'minQtyMilli',
  );
  @override
  late final GeneratedColumn<int> minQtyMilli = GeneratedColumn<int>(
    'min_qty_milli',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _primaryImageShaMeta = const VerificationMeta(
    'primaryImageSha',
  );
  @override
  late final GeneratedColumn<String> primaryImageSha = GeneratedColumn<String>(
    'primary_image_sha',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _attributesJsonMeta = const VerificationMeta(
    'attributesJson',
  );
  @override
  late final GeneratedColumn<String> attributesJson = GeneratedColumn<String>(
    'attributes_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletionMarkMeta = const VerificationMeta(
    'deletionMark',
  );
  @override
  late final GeneratedColumn<bool> deletionMark = GeneratedColumn<bool>(
    'deletion_mark',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deletion_mark" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _serverUpdatedAtMeta = const VerificationMeta(
    'serverUpdatedAt',
  );
  @override
  late final GeneratedColumn<int> serverUpdatedAt = GeneratedColumn<int>(
    'server_updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _defaultVariantIdMeta = const VerificationMeta(
    'defaultVariantId',
  );
  @override
  late final GeneratedColumn<String> defaultVariantId = GeneratedColumn<String>(
    'default_variant_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseUnitIdMeta = const VerificationMeta(
    'baseUnitId',
  );
  @override
  late final GeneratedColumn<String> baseUnitId = GeneratedColumn<String>(
    'base_unit_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    sku,
    skuNorm,
    name,
    nameNorm,
    brand,
    categoryId,
    baseUnitCode,
    qtyPrecision,
    hasVariants,
    isSellable,
    multiplicityMilli,
    minQtyMilli,
    primaryImageSha,
    attributesJson,
    deletionMark,
    serverUpdatedAt,
    defaultVariantId,
    baseUnitId,
    description,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'products';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProductRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('sku')) {
      context.handle(
        _skuMeta,
        sku.isAcceptableOrUnknown(data['sku']!, _skuMeta),
      );
    } else if (isInserting) {
      context.missing(_skuMeta);
    }
    if (data.containsKey('sku_norm')) {
      context.handle(
        _skuNormMeta,
        skuNorm.isAcceptableOrUnknown(data['sku_norm']!, _skuNormMeta),
      );
    } else if (isInserting) {
      context.missing(_skuNormMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('name_norm')) {
      context.handle(
        _nameNormMeta,
        nameNorm.isAcceptableOrUnknown(data['name_norm']!, _nameNormMeta),
      );
    } else if (isInserting) {
      context.missing(_nameNormMeta);
    }
    if (data.containsKey('brand')) {
      context.handle(
        _brandMeta,
        brand.isAcceptableOrUnknown(data['brand']!, _brandMeta),
      );
    }
    if (data.containsKey('category_id')) {
      context.handle(
        _categoryIdMeta,
        categoryId.isAcceptableOrUnknown(data['category_id']!, _categoryIdMeta),
      );
    }
    if (data.containsKey('base_unit_code')) {
      context.handle(
        _baseUnitCodeMeta,
        baseUnitCode.isAcceptableOrUnknown(
          data['base_unit_code']!,
          _baseUnitCodeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_baseUnitCodeMeta);
    }
    if (data.containsKey('qty_precision')) {
      context.handle(
        _qtyPrecisionMeta,
        qtyPrecision.isAcceptableOrUnknown(
          data['qty_precision']!,
          _qtyPrecisionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_qtyPrecisionMeta);
    }
    if (data.containsKey('has_variants')) {
      context.handle(
        _hasVariantsMeta,
        hasVariants.isAcceptableOrUnknown(
          data['has_variants']!,
          _hasVariantsMeta,
        ),
      );
    }
    if (data.containsKey('is_sellable')) {
      context.handle(
        _isSellableMeta,
        isSellable.isAcceptableOrUnknown(data['is_sellable']!, _isSellableMeta),
      );
    }
    if (data.containsKey('multiplicity_milli')) {
      context.handle(
        _multiplicityMilliMeta,
        multiplicityMilli.isAcceptableOrUnknown(
          data['multiplicity_milli']!,
          _multiplicityMilliMeta,
        ),
      );
    }
    if (data.containsKey('min_qty_milli')) {
      context.handle(
        _minQtyMilliMeta,
        minQtyMilli.isAcceptableOrUnknown(
          data['min_qty_milli']!,
          _minQtyMilliMeta,
        ),
      );
    }
    if (data.containsKey('primary_image_sha')) {
      context.handle(
        _primaryImageShaMeta,
        primaryImageSha.isAcceptableOrUnknown(
          data['primary_image_sha']!,
          _primaryImageShaMeta,
        ),
      );
    }
    if (data.containsKey('attributes_json')) {
      context.handle(
        _attributesJsonMeta,
        attributesJson.isAcceptableOrUnknown(
          data['attributes_json']!,
          _attributesJsonMeta,
        ),
      );
    }
    if (data.containsKey('deletion_mark')) {
      context.handle(
        _deletionMarkMeta,
        deletionMark.isAcceptableOrUnknown(
          data['deletion_mark']!,
          _deletionMarkMeta,
        ),
      );
    }
    if (data.containsKey('server_updated_at')) {
      context.handle(
        _serverUpdatedAtMeta,
        serverUpdatedAt.isAcceptableOrUnknown(
          data['server_updated_at']!,
          _serverUpdatedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverUpdatedAtMeta);
    }
    if (data.containsKey('default_variant_id')) {
      context.handle(
        _defaultVariantIdMeta,
        defaultVariantId.isAcceptableOrUnknown(
          data['default_variant_id']!,
          _defaultVariantIdMeta,
        ),
      );
    }
    if (data.containsKey('base_unit_id')) {
      context.handle(
        _baseUnitIdMeta,
        baseUnitId.isAcceptableOrUnknown(
          data['base_unit_id']!,
          _baseUnitIdMeta,
        ),
      );
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ProductRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProductRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      sku: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sku'],
      )!,
      skuNorm: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sku_norm'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      nameNorm: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name_norm'],
      )!,
      brand: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}brand'],
      ),
      categoryId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category_id'],
      ),
      baseUnitCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_unit_code'],
      )!,
      qtyPrecision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}qty_precision'],
      )!,
      hasVariants: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_variants'],
      )!,
      isSellable: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_sellable'],
      )!,
      multiplicityMilli: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}multiplicity_milli'],
      ),
      minQtyMilli: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}min_qty_milli'],
      ),
      primaryImageSha: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}primary_image_sha'],
      ),
      attributesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attributes_json'],
      ),
      deletionMark: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deletion_mark'],
      )!,
      serverUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_updated_at'],
      )!,
      defaultVariantId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}default_variant_id'],
      ),
      baseUnitId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_unit_id'],
      ),
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
    );
  }

  @override
  $LocalProductsTable createAlias(String alias) {
    return $LocalProductsTable(attachedDatabase, alias);
  }
}

class ProductRow extends DataClass implements Insertable<ProductRow> {
  final String id;
  final String sku;
  final String skuNorm;
  final String name;
  final String nameNorm;
  final String? brand;
  final String? categoryId;
  final String baseUnitCode;
  final int qtyPrecision;
  final bool hasVariants;
  final bool isSellable;
  final int? multiplicityMilli;
  final int? minQtyMilli;
  final String? primaryImageSha;
  final String? attributesJson;
  final bool deletionMark;
  final int serverUpdatedAt;

  /// `Product.defaultVariantId` (08 §3.6). Схема v3.
  final String? defaultVariantId;

  /// `Product.baseUnit.id` — серверный UUID единицы (08 `Unit.id`). Схема v3.
  final String? baseUnitId;

  /// `Product.description` — для карточки офлайн (08 §4.24: «полная карточка»). Схема v3.
  final String? description;
  const ProductRow({
    required this.id,
    required this.sku,
    required this.skuNorm,
    required this.name,
    required this.nameNorm,
    this.brand,
    this.categoryId,
    required this.baseUnitCode,
    required this.qtyPrecision,
    required this.hasVariants,
    required this.isSellable,
    this.multiplicityMilli,
    this.minQtyMilli,
    this.primaryImageSha,
    this.attributesJson,
    required this.deletionMark,
    required this.serverUpdatedAt,
    this.defaultVariantId,
    this.baseUnitId,
    this.description,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['sku'] = Variable<String>(sku);
    map['sku_norm'] = Variable<String>(skuNorm);
    map['name'] = Variable<String>(name);
    map['name_norm'] = Variable<String>(nameNorm);
    if (!nullToAbsent || brand != null) {
      map['brand'] = Variable<String>(brand);
    }
    if (!nullToAbsent || categoryId != null) {
      map['category_id'] = Variable<String>(categoryId);
    }
    map['base_unit_code'] = Variable<String>(baseUnitCode);
    map['qty_precision'] = Variable<int>(qtyPrecision);
    map['has_variants'] = Variable<bool>(hasVariants);
    map['is_sellable'] = Variable<bool>(isSellable);
    if (!nullToAbsent || multiplicityMilli != null) {
      map['multiplicity_milli'] = Variable<int>(multiplicityMilli);
    }
    if (!nullToAbsent || minQtyMilli != null) {
      map['min_qty_milli'] = Variable<int>(minQtyMilli);
    }
    if (!nullToAbsent || primaryImageSha != null) {
      map['primary_image_sha'] = Variable<String>(primaryImageSha);
    }
    if (!nullToAbsent || attributesJson != null) {
      map['attributes_json'] = Variable<String>(attributesJson);
    }
    map['deletion_mark'] = Variable<bool>(deletionMark);
    map['server_updated_at'] = Variable<int>(serverUpdatedAt);
    if (!nullToAbsent || defaultVariantId != null) {
      map['default_variant_id'] = Variable<String>(defaultVariantId);
    }
    if (!nullToAbsent || baseUnitId != null) {
      map['base_unit_id'] = Variable<String>(baseUnitId);
    }
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    return map;
  }

  LocalProductsCompanion toCompanion(bool nullToAbsent) {
    return LocalProductsCompanion(
      id: Value(id),
      sku: Value(sku),
      skuNorm: Value(skuNorm),
      name: Value(name),
      nameNorm: Value(nameNorm),
      brand: brand == null && nullToAbsent
          ? const Value.absent()
          : Value(brand),
      categoryId: categoryId == null && nullToAbsent
          ? const Value.absent()
          : Value(categoryId),
      baseUnitCode: Value(baseUnitCode),
      qtyPrecision: Value(qtyPrecision),
      hasVariants: Value(hasVariants),
      isSellable: Value(isSellable),
      multiplicityMilli: multiplicityMilli == null && nullToAbsent
          ? const Value.absent()
          : Value(multiplicityMilli),
      minQtyMilli: minQtyMilli == null && nullToAbsent
          ? const Value.absent()
          : Value(minQtyMilli),
      primaryImageSha: primaryImageSha == null && nullToAbsent
          ? const Value.absent()
          : Value(primaryImageSha),
      attributesJson: attributesJson == null && nullToAbsent
          ? const Value.absent()
          : Value(attributesJson),
      deletionMark: Value(deletionMark),
      serverUpdatedAt: Value(serverUpdatedAt),
      defaultVariantId: defaultVariantId == null && nullToAbsent
          ? const Value.absent()
          : Value(defaultVariantId),
      baseUnitId: baseUnitId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseUnitId),
      description: description == null && nullToAbsent
          ? const Value.absent()
          : Value(description),
    );
  }

  factory ProductRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProductRow(
      id: serializer.fromJson<String>(json['id']),
      sku: serializer.fromJson<String>(json['sku']),
      skuNorm: serializer.fromJson<String>(json['skuNorm']),
      name: serializer.fromJson<String>(json['name']),
      nameNorm: serializer.fromJson<String>(json['nameNorm']),
      brand: serializer.fromJson<String?>(json['brand']),
      categoryId: serializer.fromJson<String?>(json['categoryId']),
      baseUnitCode: serializer.fromJson<String>(json['baseUnitCode']),
      qtyPrecision: serializer.fromJson<int>(json['qtyPrecision']),
      hasVariants: serializer.fromJson<bool>(json['hasVariants']),
      isSellable: serializer.fromJson<bool>(json['isSellable']),
      multiplicityMilli: serializer.fromJson<int?>(json['multiplicityMilli']),
      minQtyMilli: serializer.fromJson<int?>(json['minQtyMilli']),
      primaryImageSha: serializer.fromJson<String?>(json['primaryImageSha']),
      attributesJson: serializer.fromJson<String?>(json['attributesJson']),
      deletionMark: serializer.fromJson<bool>(json['deletionMark']),
      serverUpdatedAt: serializer.fromJson<int>(json['serverUpdatedAt']),
      defaultVariantId: serializer.fromJson<String?>(json['defaultVariantId']),
      baseUnitId: serializer.fromJson<String?>(json['baseUnitId']),
      description: serializer.fromJson<String?>(json['description']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'sku': serializer.toJson<String>(sku),
      'skuNorm': serializer.toJson<String>(skuNorm),
      'name': serializer.toJson<String>(name),
      'nameNorm': serializer.toJson<String>(nameNorm),
      'brand': serializer.toJson<String?>(brand),
      'categoryId': serializer.toJson<String?>(categoryId),
      'baseUnitCode': serializer.toJson<String>(baseUnitCode),
      'qtyPrecision': serializer.toJson<int>(qtyPrecision),
      'hasVariants': serializer.toJson<bool>(hasVariants),
      'isSellable': serializer.toJson<bool>(isSellable),
      'multiplicityMilli': serializer.toJson<int?>(multiplicityMilli),
      'minQtyMilli': serializer.toJson<int?>(minQtyMilli),
      'primaryImageSha': serializer.toJson<String?>(primaryImageSha),
      'attributesJson': serializer.toJson<String?>(attributesJson),
      'deletionMark': serializer.toJson<bool>(deletionMark),
      'serverUpdatedAt': serializer.toJson<int>(serverUpdatedAt),
      'defaultVariantId': serializer.toJson<String?>(defaultVariantId),
      'baseUnitId': serializer.toJson<String?>(baseUnitId),
      'description': serializer.toJson<String?>(description),
    };
  }

  ProductRow copyWith({
    String? id,
    String? sku,
    String? skuNorm,
    String? name,
    String? nameNorm,
    Value<String?> brand = const Value.absent(),
    Value<String?> categoryId = const Value.absent(),
    String? baseUnitCode,
    int? qtyPrecision,
    bool? hasVariants,
    bool? isSellable,
    Value<int?> multiplicityMilli = const Value.absent(),
    Value<int?> minQtyMilli = const Value.absent(),
    Value<String?> primaryImageSha = const Value.absent(),
    Value<String?> attributesJson = const Value.absent(),
    bool? deletionMark,
    int? serverUpdatedAt,
    Value<String?> defaultVariantId = const Value.absent(),
    Value<String?> baseUnitId = const Value.absent(),
    Value<String?> description = const Value.absent(),
  }) => ProductRow(
    id: id ?? this.id,
    sku: sku ?? this.sku,
    skuNorm: skuNorm ?? this.skuNorm,
    name: name ?? this.name,
    nameNorm: nameNorm ?? this.nameNorm,
    brand: brand.present ? brand.value : this.brand,
    categoryId: categoryId.present ? categoryId.value : this.categoryId,
    baseUnitCode: baseUnitCode ?? this.baseUnitCode,
    qtyPrecision: qtyPrecision ?? this.qtyPrecision,
    hasVariants: hasVariants ?? this.hasVariants,
    isSellable: isSellable ?? this.isSellable,
    multiplicityMilli: multiplicityMilli.present
        ? multiplicityMilli.value
        : this.multiplicityMilli,
    minQtyMilli: minQtyMilli.present ? minQtyMilli.value : this.minQtyMilli,
    primaryImageSha: primaryImageSha.present
        ? primaryImageSha.value
        : this.primaryImageSha,
    attributesJson: attributesJson.present
        ? attributesJson.value
        : this.attributesJson,
    deletionMark: deletionMark ?? this.deletionMark,
    serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
    defaultVariantId: defaultVariantId.present
        ? defaultVariantId.value
        : this.defaultVariantId,
    baseUnitId: baseUnitId.present ? baseUnitId.value : this.baseUnitId,
    description: description.present ? description.value : this.description,
  );
  ProductRow copyWithCompanion(LocalProductsCompanion data) {
    return ProductRow(
      id: data.id.present ? data.id.value : this.id,
      sku: data.sku.present ? data.sku.value : this.sku,
      skuNorm: data.skuNorm.present ? data.skuNorm.value : this.skuNorm,
      name: data.name.present ? data.name.value : this.name,
      nameNorm: data.nameNorm.present ? data.nameNorm.value : this.nameNorm,
      brand: data.brand.present ? data.brand.value : this.brand,
      categoryId: data.categoryId.present
          ? data.categoryId.value
          : this.categoryId,
      baseUnitCode: data.baseUnitCode.present
          ? data.baseUnitCode.value
          : this.baseUnitCode,
      qtyPrecision: data.qtyPrecision.present
          ? data.qtyPrecision.value
          : this.qtyPrecision,
      hasVariants: data.hasVariants.present
          ? data.hasVariants.value
          : this.hasVariants,
      isSellable: data.isSellable.present
          ? data.isSellable.value
          : this.isSellable,
      multiplicityMilli: data.multiplicityMilli.present
          ? data.multiplicityMilli.value
          : this.multiplicityMilli,
      minQtyMilli: data.minQtyMilli.present
          ? data.minQtyMilli.value
          : this.minQtyMilli,
      primaryImageSha: data.primaryImageSha.present
          ? data.primaryImageSha.value
          : this.primaryImageSha,
      attributesJson: data.attributesJson.present
          ? data.attributesJson.value
          : this.attributesJson,
      deletionMark: data.deletionMark.present
          ? data.deletionMark.value
          : this.deletionMark,
      serverUpdatedAt: data.serverUpdatedAt.present
          ? data.serverUpdatedAt.value
          : this.serverUpdatedAt,
      defaultVariantId: data.defaultVariantId.present
          ? data.defaultVariantId.value
          : this.defaultVariantId,
      baseUnitId: data.baseUnitId.present
          ? data.baseUnitId.value
          : this.baseUnitId,
      description: data.description.present
          ? data.description.value
          : this.description,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProductRow(')
          ..write('id: $id, ')
          ..write('sku: $sku, ')
          ..write('skuNorm: $skuNorm, ')
          ..write('name: $name, ')
          ..write('nameNorm: $nameNorm, ')
          ..write('brand: $brand, ')
          ..write('categoryId: $categoryId, ')
          ..write('baseUnitCode: $baseUnitCode, ')
          ..write('qtyPrecision: $qtyPrecision, ')
          ..write('hasVariants: $hasVariants, ')
          ..write('isSellable: $isSellable, ')
          ..write('multiplicityMilli: $multiplicityMilli, ')
          ..write('minQtyMilli: $minQtyMilli, ')
          ..write('primaryImageSha: $primaryImageSha, ')
          ..write('attributesJson: $attributesJson, ')
          ..write('deletionMark: $deletionMark, ')
          ..write('serverUpdatedAt: $serverUpdatedAt, ')
          ..write('defaultVariantId: $defaultVariantId, ')
          ..write('baseUnitId: $baseUnitId, ')
          ..write('description: $description')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    sku,
    skuNorm,
    name,
    nameNorm,
    brand,
    categoryId,
    baseUnitCode,
    qtyPrecision,
    hasVariants,
    isSellable,
    multiplicityMilli,
    minQtyMilli,
    primaryImageSha,
    attributesJson,
    deletionMark,
    serverUpdatedAt,
    defaultVariantId,
    baseUnitId,
    description,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProductRow &&
          other.id == this.id &&
          other.sku == this.sku &&
          other.skuNorm == this.skuNorm &&
          other.name == this.name &&
          other.nameNorm == this.nameNorm &&
          other.brand == this.brand &&
          other.categoryId == this.categoryId &&
          other.baseUnitCode == this.baseUnitCode &&
          other.qtyPrecision == this.qtyPrecision &&
          other.hasVariants == this.hasVariants &&
          other.isSellable == this.isSellable &&
          other.multiplicityMilli == this.multiplicityMilli &&
          other.minQtyMilli == this.minQtyMilli &&
          other.primaryImageSha == this.primaryImageSha &&
          other.attributesJson == this.attributesJson &&
          other.deletionMark == this.deletionMark &&
          other.serverUpdatedAt == this.serverUpdatedAt &&
          other.defaultVariantId == this.defaultVariantId &&
          other.baseUnitId == this.baseUnitId &&
          other.description == this.description);
}

class LocalProductsCompanion extends UpdateCompanion<ProductRow> {
  final Value<String> id;
  final Value<String> sku;
  final Value<String> skuNorm;
  final Value<String> name;
  final Value<String> nameNorm;
  final Value<String?> brand;
  final Value<String?> categoryId;
  final Value<String> baseUnitCode;
  final Value<int> qtyPrecision;
  final Value<bool> hasVariants;
  final Value<bool> isSellable;
  final Value<int?> multiplicityMilli;
  final Value<int?> minQtyMilli;
  final Value<String?> primaryImageSha;
  final Value<String?> attributesJson;
  final Value<bool> deletionMark;
  final Value<int> serverUpdatedAt;
  final Value<String?> defaultVariantId;
  final Value<String?> baseUnitId;
  final Value<String?> description;
  final Value<int> rowid;
  const LocalProductsCompanion({
    this.id = const Value.absent(),
    this.sku = const Value.absent(),
    this.skuNorm = const Value.absent(),
    this.name = const Value.absent(),
    this.nameNorm = const Value.absent(),
    this.brand = const Value.absent(),
    this.categoryId = const Value.absent(),
    this.baseUnitCode = const Value.absent(),
    this.qtyPrecision = const Value.absent(),
    this.hasVariants = const Value.absent(),
    this.isSellable = const Value.absent(),
    this.multiplicityMilli = const Value.absent(),
    this.minQtyMilli = const Value.absent(),
    this.primaryImageSha = const Value.absent(),
    this.attributesJson = const Value.absent(),
    this.deletionMark = const Value.absent(),
    this.serverUpdatedAt = const Value.absent(),
    this.defaultVariantId = const Value.absent(),
    this.baseUnitId = const Value.absent(),
    this.description = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalProductsCompanion.insert({
    required String id,
    required String sku,
    required String skuNorm,
    required String name,
    required String nameNorm,
    this.brand = const Value.absent(),
    this.categoryId = const Value.absent(),
    required String baseUnitCode,
    required int qtyPrecision,
    this.hasVariants = const Value.absent(),
    this.isSellable = const Value.absent(),
    this.multiplicityMilli = const Value.absent(),
    this.minQtyMilli = const Value.absent(),
    this.primaryImageSha = const Value.absent(),
    this.attributesJson = const Value.absent(),
    this.deletionMark = const Value.absent(),
    required int serverUpdatedAt,
    this.defaultVariantId = const Value.absent(),
    this.baseUnitId = const Value.absent(),
    this.description = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       sku = Value(sku),
       skuNorm = Value(skuNorm),
       name = Value(name),
       nameNorm = Value(nameNorm),
       baseUnitCode = Value(baseUnitCode),
       qtyPrecision = Value(qtyPrecision),
       serverUpdatedAt = Value(serverUpdatedAt);
  static Insertable<ProductRow> custom({
    Expression<String>? id,
    Expression<String>? sku,
    Expression<String>? skuNorm,
    Expression<String>? name,
    Expression<String>? nameNorm,
    Expression<String>? brand,
    Expression<String>? categoryId,
    Expression<String>? baseUnitCode,
    Expression<int>? qtyPrecision,
    Expression<bool>? hasVariants,
    Expression<bool>? isSellable,
    Expression<int>? multiplicityMilli,
    Expression<int>? minQtyMilli,
    Expression<String>? primaryImageSha,
    Expression<String>? attributesJson,
    Expression<bool>? deletionMark,
    Expression<int>? serverUpdatedAt,
    Expression<String>? defaultVariantId,
    Expression<String>? baseUnitId,
    Expression<String>? description,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sku != null) 'sku': sku,
      if (skuNorm != null) 'sku_norm': skuNorm,
      if (name != null) 'name': name,
      if (nameNorm != null) 'name_norm': nameNorm,
      if (brand != null) 'brand': brand,
      if (categoryId != null) 'category_id': categoryId,
      if (baseUnitCode != null) 'base_unit_code': baseUnitCode,
      if (qtyPrecision != null) 'qty_precision': qtyPrecision,
      if (hasVariants != null) 'has_variants': hasVariants,
      if (isSellable != null) 'is_sellable': isSellable,
      if (multiplicityMilli != null) 'multiplicity_milli': multiplicityMilli,
      if (minQtyMilli != null) 'min_qty_milli': minQtyMilli,
      if (primaryImageSha != null) 'primary_image_sha': primaryImageSha,
      if (attributesJson != null) 'attributes_json': attributesJson,
      if (deletionMark != null) 'deletion_mark': deletionMark,
      if (serverUpdatedAt != null) 'server_updated_at': serverUpdatedAt,
      if (defaultVariantId != null) 'default_variant_id': defaultVariantId,
      if (baseUnitId != null) 'base_unit_id': baseUnitId,
      if (description != null) 'description': description,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalProductsCompanion copyWith({
    Value<String>? id,
    Value<String>? sku,
    Value<String>? skuNorm,
    Value<String>? name,
    Value<String>? nameNorm,
    Value<String?>? brand,
    Value<String?>? categoryId,
    Value<String>? baseUnitCode,
    Value<int>? qtyPrecision,
    Value<bool>? hasVariants,
    Value<bool>? isSellable,
    Value<int?>? multiplicityMilli,
    Value<int?>? minQtyMilli,
    Value<String?>? primaryImageSha,
    Value<String?>? attributesJson,
    Value<bool>? deletionMark,
    Value<int>? serverUpdatedAt,
    Value<String?>? defaultVariantId,
    Value<String?>? baseUnitId,
    Value<String?>? description,
    Value<int>? rowid,
  }) {
    return LocalProductsCompanion(
      id: id ?? this.id,
      sku: sku ?? this.sku,
      skuNorm: skuNorm ?? this.skuNorm,
      name: name ?? this.name,
      nameNorm: nameNorm ?? this.nameNorm,
      brand: brand ?? this.brand,
      categoryId: categoryId ?? this.categoryId,
      baseUnitCode: baseUnitCode ?? this.baseUnitCode,
      qtyPrecision: qtyPrecision ?? this.qtyPrecision,
      hasVariants: hasVariants ?? this.hasVariants,
      isSellable: isSellable ?? this.isSellable,
      multiplicityMilli: multiplicityMilli ?? this.multiplicityMilli,
      minQtyMilli: minQtyMilli ?? this.minQtyMilli,
      primaryImageSha: primaryImageSha ?? this.primaryImageSha,
      attributesJson: attributesJson ?? this.attributesJson,
      deletionMark: deletionMark ?? this.deletionMark,
      serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
      defaultVariantId: defaultVariantId ?? this.defaultVariantId,
      baseUnitId: baseUnitId ?? this.baseUnitId,
      description: description ?? this.description,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (sku.present) {
      map['sku'] = Variable<String>(sku.value);
    }
    if (skuNorm.present) {
      map['sku_norm'] = Variable<String>(skuNorm.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (nameNorm.present) {
      map['name_norm'] = Variable<String>(nameNorm.value);
    }
    if (brand.present) {
      map['brand'] = Variable<String>(brand.value);
    }
    if (categoryId.present) {
      map['category_id'] = Variable<String>(categoryId.value);
    }
    if (baseUnitCode.present) {
      map['base_unit_code'] = Variable<String>(baseUnitCode.value);
    }
    if (qtyPrecision.present) {
      map['qty_precision'] = Variable<int>(qtyPrecision.value);
    }
    if (hasVariants.present) {
      map['has_variants'] = Variable<bool>(hasVariants.value);
    }
    if (isSellable.present) {
      map['is_sellable'] = Variable<bool>(isSellable.value);
    }
    if (multiplicityMilli.present) {
      map['multiplicity_milli'] = Variable<int>(multiplicityMilli.value);
    }
    if (minQtyMilli.present) {
      map['min_qty_milli'] = Variable<int>(minQtyMilli.value);
    }
    if (primaryImageSha.present) {
      map['primary_image_sha'] = Variable<String>(primaryImageSha.value);
    }
    if (attributesJson.present) {
      map['attributes_json'] = Variable<String>(attributesJson.value);
    }
    if (deletionMark.present) {
      map['deletion_mark'] = Variable<bool>(deletionMark.value);
    }
    if (serverUpdatedAt.present) {
      map['server_updated_at'] = Variable<int>(serverUpdatedAt.value);
    }
    if (defaultVariantId.present) {
      map['default_variant_id'] = Variable<String>(defaultVariantId.value);
    }
    if (baseUnitId.present) {
      map['base_unit_id'] = Variable<String>(baseUnitId.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalProductsCompanion(')
          ..write('id: $id, ')
          ..write('sku: $sku, ')
          ..write('skuNorm: $skuNorm, ')
          ..write('name: $name, ')
          ..write('nameNorm: $nameNorm, ')
          ..write('brand: $brand, ')
          ..write('categoryId: $categoryId, ')
          ..write('baseUnitCode: $baseUnitCode, ')
          ..write('qtyPrecision: $qtyPrecision, ')
          ..write('hasVariants: $hasVariants, ')
          ..write('isSellable: $isSellable, ')
          ..write('multiplicityMilli: $multiplicityMilli, ')
          ..write('minQtyMilli: $minQtyMilli, ')
          ..write('primaryImageSha: $primaryImageSha, ')
          ..write('attributesJson: $attributesJson, ')
          ..write('deletionMark: $deletionMark, ')
          ..write('serverUpdatedAt: $serverUpdatedAt, ')
          ..write('defaultVariantId: $defaultVariantId, ')
          ..write('baseUnitId: $baseUnitId, ')
          ..write('description: $description, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalProductVariantsTable extends LocalProductVariants
    with TableInfo<$LocalProductVariantsTable, ProductVariantRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalProductVariantsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isDefaultMeta = const VerificationMeta(
    'isDefault',
  );
  @override
  late final GeneratedColumn<bool> isDefault = GeneratedColumn<bool>(
    'is_default',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_default" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _skuMeta = const VerificationMeta('sku');
  @override
  late final GeneratedColumn<String> sku = GeneratedColumn<String>(
    'sku',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _skuNormMeta = const VerificationMeta(
    'skuNorm',
  );
  @override
  late final GeneratedColumn<String> skuNorm = GeneratedColumn<String>(
    'sku_norm',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _attributesJsonMeta = const VerificationMeta(
    'attributesJson',
  );
  @override
  late final GeneratedColumn<String> attributesJson = GeneratedColumn<String>(
    'attributes_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _imageShaMeta = const VerificationMeta(
    'imageSha',
  );
  @override
  late final GeneratedColumn<String> imageSha = GeneratedColumn<String>(
    'image_sha',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletionMarkMeta = const VerificationMeta(
    'deletionMark',
  );
  @override
  late final GeneratedColumn<bool> deletionMark = GeneratedColumn<bool>(
    'deletion_mark',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deletion_mark" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _serverUpdatedAtMeta = const VerificationMeta(
    'serverUpdatedAt',
  );
  @override
  late final GeneratedColumn<int> serverUpdatedAt = GeneratedColumn<int>(
    'server_updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _multiplicityMilliMeta = const VerificationMeta(
    'multiplicityMilli',
  );
  @override
  late final GeneratedColumn<int> multiplicityMilli = GeneratedColumn<int>(
    'multiplicity_milli',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _unitIdMeta = const VerificationMeta('unitId');
  @override
  late final GeneratedColumn<String> unitId = GeneratedColumn<String>(
    'unit_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    productId,
    isDefault,
    name,
    sku,
    skuNorm,
    attributesJson,
    sortOrder,
    imageSha,
    deletionMark,
    serverUpdatedAt,
    multiplicityMilli,
    unitId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'product_variants';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProductVariantRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('is_default')) {
      context.handle(
        _isDefaultMeta,
        isDefault.isAcceptableOrUnknown(data['is_default']!, _isDefaultMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sku')) {
      context.handle(
        _skuMeta,
        sku.isAcceptableOrUnknown(data['sku']!, _skuMeta),
      );
    }
    if (data.containsKey('sku_norm')) {
      context.handle(
        _skuNormMeta,
        skuNorm.isAcceptableOrUnknown(data['sku_norm']!, _skuNormMeta),
      );
    }
    if (data.containsKey('attributes_json')) {
      context.handle(
        _attributesJsonMeta,
        attributesJson.isAcceptableOrUnknown(
          data['attributes_json']!,
          _attributesJsonMeta,
        ),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('image_sha')) {
      context.handle(
        _imageShaMeta,
        imageSha.isAcceptableOrUnknown(data['image_sha']!, _imageShaMeta),
      );
    }
    if (data.containsKey('deletion_mark')) {
      context.handle(
        _deletionMarkMeta,
        deletionMark.isAcceptableOrUnknown(
          data['deletion_mark']!,
          _deletionMarkMeta,
        ),
      );
    }
    if (data.containsKey('server_updated_at')) {
      context.handle(
        _serverUpdatedAtMeta,
        serverUpdatedAt.isAcceptableOrUnknown(
          data['server_updated_at']!,
          _serverUpdatedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverUpdatedAtMeta);
    }
    if (data.containsKey('multiplicity_milli')) {
      context.handle(
        _multiplicityMilliMeta,
        multiplicityMilli.isAcceptableOrUnknown(
          data['multiplicity_milli']!,
          _multiplicityMilliMeta,
        ),
      );
    }
    if (data.containsKey('unit_id')) {
      context.handle(
        _unitIdMeta,
        unitId.isAcceptableOrUnknown(data['unit_id']!, _unitIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ProductVariantRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProductVariantRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      isDefault: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_default'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      sku: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sku'],
      ),
      skuNorm: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sku_norm'],
      ),
      attributesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attributes_json'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      imageSha: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}image_sha'],
      ),
      deletionMark: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deletion_mark'],
      )!,
      serverUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_updated_at'],
      )!,
      multiplicityMilli: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}multiplicity_milli'],
      ),
      unitId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}unit_id'],
      ),
    );
  }

  @override
  $LocalProductVariantsTable createAlias(String alias) {
    return $LocalProductVariantsTable(attachedDatabase, alias);
  }
}

class ProductVariantRow extends DataClass
    implements Insertable<ProductVariantRow> {
  final String id;
  final String productId;
  final bool isDefault;
  final String name;
  final String? sku;
  final String? skuNorm;
  final String? attributesJson;
  final int sortOrder;
  final String? imageSha;
  final bool deletionMark;
  final int serverUpdatedAt;

  /// `Variant.multiplicity` в milli-units (ядро §19.2, RM-E-014). Схема v3.
  final int? multiplicityMilli;

  /// `Variant.unitId` (08 §4.24). Схема v3.
  final String? unitId;
  const ProductVariantRow({
    required this.id,
    required this.productId,
    required this.isDefault,
    required this.name,
    this.sku,
    this.skuNorm,
    this.attributesJson,
    required this.sortOrder,
    this.imageSha,
    required this.deletionMark,
    required this.serverUpdatedAt,
    this.multiplicityMilli,
    this.unitId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['product_id'] = Variable<String>(productId);
    map['is_default'] = Variable<bool>(isDefault);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || sku != null) {
      map['sku'] = Variable<String>(sku);
    }
    if (!nullToAbsent || skuNorm != null) {
      map['sku_norm'] = Variable<String>(skuNorm);
    }
    if (!nullToAbsent || attributesJson != null) {
      map['attributes_json'] = Variable<String>(attributesJson);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || imageSha != null) {
      map['image_sha'] = Variable<String>(imageSha);
    }
    map['deletion_mark'] = Variable<bool>(deletionMark);
    map['server_updated_at'] = Variable<int>(serverUpdatedAt);
    if (!nullToAbsent || multiplicityMilli != null) {
      map['multiplicity_milli'] = Variable<int>(multiplicityMilli);
    }
    if (!nullToAbsent || unitId != null) {
      map['unit_id'] = Variable<String>(unitId);
    }
    return map;
  }

  LocalProductVariantsCompanion toCompanion(bool nullToAbsent) {
    return LocalProductVariantsCompanion(
      id: Value(id),
      productId: Value(productId),
      isDefault: Value(isDefault),
      name: Value(name),
      sku: sku == null && nullToAbsent ? const Value.absent() : Value(sku),
      skuNorm: skuNorm == null && nullToAbsent
          ? const Value.absent()
          : Value(skuNorm),
      attributesJson: attributesJson == null && nullToAbsent
          ? const Value.absent()
          : Value(attributesJson),
      sortOrder: Value(sortOrder),
      imageSha: imageSha == null && nullToAbsent
          ? const Value.absent()
          : Value(imageSha),
      deletionMark: Value(deletionMark),
      serverUpdatedAt: Value(serverUpdatedAt),
      multiplicityMilli: multiplicityMilli == null && nullToAbsent
          ? const Value.absent()
          : Value(multiplicityMilli),
      unitId: unitId == null && nullToAbsent
          ? const Value.absent()
          : Value(unitId),
    );
  }

  factory ProductVariantRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProductVariantRow(
      id: serializer.fromJson<String>(json['id']),
      productId: serializer.fromJson<String>(json['productId']),
      isDefault: serializer.fromJson<bool>(json['isDefault']),
      name: serializer.fromJson<String>(json['name']),
      sku: serializer.fromJson<String?>(json['sku']),
      skuNorm: serializer.fromJson<String?>(json['skuNorm']),
      attributesJson: serializer.fromJson<String?>(json['attributesJson']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      imageSha: serializer.fromJson<String?>(json['imageSha']),
      deletionMark: serializer.fromJson<bool>(json['deletionMark']),
      serverUpdatedAt: serializer.fromJson<int>(json['serverUpdatedAt']),
      multiplicityMilli: serializer.fromJson<int?>(json['multiplicityMilli']),
      unitId: serializer.fromJson<String?>(json['unitId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'productId': serializer.toJson<String>(productId),
      'isDefault': serializer.toJson<bool>(isDefault),
      'name': serializer.toJson<String>(name),
      'sku': serializer.toJson<String?>(sku),
      'skuNorm': serializer.toJson<String?>(skuNorm),
      'attributesJson': serializer.toJson<String?>(attributesJson),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'imageSha': serializer.toJson<String?>(imageSha),
      'deletionMark': serializer.toJson<bool>(deletionMark),
      'serverUpdatedAt': serializer.toJson<int>(serverUpdatedAt),
      'multiplicityMilli': serializer.toJson<int?>(multiplicityMilli),
      'unitId': serializer.toJson<String?>(unitId),
    };
  }

  ProductVariantRow copyWith({
    String? id,
    String? productId,
    bool? isDefault,
    String? name,
    Value<String?> sku = const Value.absent(),
    Value<String?> skuNorm = const Value.absent(),
    Value<String?> attributesJson = const Value.absent(),
    int? sortOrder,
    Value<String?> imageSha = const Value.absent(),
    bool? deletionMark,
    int? serverUpdatedAt,
    Value<int?> multiplicityMilli = const Value.absent(),
    Value<String?> unitId = const Value.absent(),
  }) => ProductVariantRow(
    id: id ?? this.id,
    productId: productId ?? this.productId,
    isDefault: isDefault ?? this.isDefault,
    name: name ?? this.name,
    sku: sku.present ? sku.value : this.sku,
    skuNorm: skuNorm.present ? skuNorm.value : this.skuNorm,
    attributesJson: attributesJson.present
        ? attributesJson.value
        : this.attributesJson,
    sortOrder: sortOrder ?? this.sortOrder,
    imageSha: imageSha.present ? imageSha.value : this.imageSha,
    deletionMark: deletionMark ?? this.deletionMark,
    serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
    multiplicityMilli: multiplicityMilli.present
        ? multiplicityMilli.value
        : this.multiplicityMilli,
    unitId: unitId.present ? unitId.value : this.unitId,
  );
  ProductVariantRow copyWithCompanion(LocalProductVariantsCompanion data) {
    return ProductVariantRow(
      id: data.id.present ? data.id.value : this.id,
      productId: data.productId.present ? data.productId.value : this.productId,
      isDefault: data.isDefault.present ? data.isDefault.value : this.isDefault,
      name: data.name.present ? data.name.value : this.name,
      sku: data.sku.present ? data.sku.value : this.sku,
      skuNorm: data.skuNorm.present ? data.skuNorm.value : this.skuNorm,
      attributesJson: data.attributesJson.present
          ? data.attributesJson.value
          : this.attributesJson,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      imageSha: data.imageSha.present ? data.imageSha.value : this.imageSha,
      deletionMark: data.deletionMark.present
          ? data.deletionMark.value
          : this.deletionMark,
      serverUpdatedAt: data.serverUpdatedAt.present
          ? data.serverUpdatedAt.value
          : this.serverUpdatedAt,
      multiplicityMilli: data.multiplicityMilli.present
          ? data.multiplicityMilli.value
          : this.multiplicityMilli,
      unitId: data.unitId.present ? data.unitId.value : this.unitId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProductVariantRow(')
          ..write('id: $id, ')
          ..write('productId: $productId, ')
          ..write('isDefault: $isDefault, ')
          ..write('name: $name, ')
          ..write('sku: $sku, ')
          ..write('skuNorm: $skuNorm, ')
          ..write('attributesJson: $attributesJson, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('imageSha: $imageSha, ')
          ..write('deletionMark: $deletionMark, ')
          ..write('serverUpdatedAt: $serverUpdatedAt, ')
          ..write('multiplicityMilli: $multiplicityMilli, ')
          ..write('unitId: $unitId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    productId,
    isDefault,
    name,
    sku,
    skuNorm,
    attributesJson,
    sortOrder,
    imageSha,
    deletionMark,
    serverUpdatedAt,
    multiplicityMilli,
    unitId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProductVariantRow &&
          other.id == this.id &&
          other.productId == this.productId &&
          other.isDefault == this.isDefault &&
          other.name == this.name &&
          other.sku == this.sku &&
          other.skuNorm == this.skuNorm &&
          other.attributesJson == this.attributesJson &&
          other.sortOrder == this.sortOrder &&
          other.imageSha == this.imageSha &&
          other.deletionMark == this.deletionMark &&
          other.serverUpdatedAt == this.serverUpdatedAt &&
          other.multiplicityMilli == this.multiplicityMilli &&
          other.unitId == this.unitId);
}

class LocalProductVariantsCompanion extends UpdateCompanion<ProductVariantRow> {
  final Value<String> id;
  final Value<String> productId;
  final Value<bool> isDefault;
  final Value<String> name;
  final Value<String?> sku;
  final Value<String?> skuNorm;
  final Value<String?> attributesJson;
  final Value<int> sortOrder;
  final Value<String?> imageSha;
  final Value<bool> deletionMark;
  final Value<int> serverUpdatedAt;
  final Value<int?> multiplicityMilli;
  final Value<String?> unitId;
  final Value<int> rowid;
  const LocalProductVariantsCompanion({
    this.id = const Value.absent(),
    this.productId = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.name = const Value.absent(),
    this.sku = const Value.absent(),
    this.skuNorm = const Value.absent(),
    this.attributesJson = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.imageSha = const Value.absent(),
    this.deletionMark = const Value.absent(),
    this.serverUpdatedAt = const Value.absent(),
    this.multiplicityMilli = const Value.absent(),
    this.unitId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalProductVariantsCompanion.insert({
    required String id,
    required String productId,
    this.isDefault = const Value.absent(),
    required String name,
    this.sku = const Value.absent(),
    this.skuNorm = const Value.absent(),
    this.attributesJson = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.imageSha = const Value.absent(),
    this.deletionMark = const Value.absent(),
    required int serverUpdatedAt,
    this.multiplicityMilli = const Value.absent(),
    this.unitId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       productId = Value(productId),
       name = Value(name),
       serverUpdatedAt = Value(serverUpdatedAt);
  static Insertable<ProductVariantRow> custom({
    Expression<String>? id,
    Expression<String>? productId,
    Expression<bool>? isDefault,
    Expression<String>? name,
    Expression<String>? sku,
    Expression<String>? skuNorm,
    Expression<String>? attributesJson,
    Expression<int>? sortOrder,
    Expression<String>? imageSha,
    Expression<bool>? deletionMark,
    Expression<int>? serverUpdatedAt,
    Expression<int>? multiplicityMilli,
    Expression<String>? unitId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (productId != null) 'product_id': productId,
      if (isDefault != null) 'is_default': isDefault,
      if (name != null) 'name': name,
      if (sku != null) 'sku': sku,
      if (skuNorm != null) 'sku_norm': skuNorm,
      if (attributesJson != null) 'attributes_json': attributesJson,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (imageSha != null) 'image_sha': imageSha,
      if (deletionMark != null) 'deletion_mark': deletionMark,
      if (serverUpdatedAt != null) 'server_updated_at': serverUpdatedAt,
      if (multiplicityMilli != null) 'multiplicity_milli': multiplicityMilli,
      if (unitId != null) 'unit_id': unitId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalProductVariantsCompanion copyWith({
    Value<String>? id,
    Value<String>? productId,
    Value<bool>? isDefault,
    Value<String>? name,
    Value<String?>? sku,
    Value<String?>? skuNorm,
    Value<String?>? attributesJson,
    Value<int>? sortOrder,
    Value<String?>? imageSha,
    Value<bool>? deletionMark,
    Value<int>? serverUpdatedAt,
    Value<int?>? multiplicityMilli,
    Value<String?>? unitId,
    Value<int>? rowid,
  }) {
    return LocalProductVariantsCompanion(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      isDefault: isDefault ?? this.isDefault,
      name: name ?? this.name,
      sku: sku ?? this.sku,
      skuNorm: skuNorm ?? this.skuNorm,
      attributesJson: attributesJson ?? this.attributesJson,
      sortOrder: sortOrder ?? this.sortOrder,
      imageSha: imageSha ?? this.imageSha,
      deletionMark: deletionMark ?? this.deletionMark,
      serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
      multiplicityMilli: multiplicityMilli ?? this.multiplicityMilli,
      unitId: unitId ?? this.unitId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (isDefault.present) {
      map['is_default'] = Variable<bool>(isDefault.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (sku.present) {
      map['sku'] = Variable<String>(sku.value);
    }
    if (skuNorm.present) {
      map['sku_norm'] = Variable<String>(skuNorm.value);
    }
    if (attributesJson.present) {
      map['attributes_json'] = Variable<String>(attributesJson.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (imageSha.present) {
      map['image_sha'] = Variable<String>(imageSha.value);
    }
    if (deletionMark.present) {
      map['deletion_mark'] = Variable<bool>(deletionMark.value);
    }
    if (serverUpdatedAt.present) {
      map['server_updated_at'] = Variable<int>(serverUpdatedAt.value);
    }
    if (multiplicityMilli.present) {
      map['multiplicity_milli'] = Variable<int>(multiplicityMilli.value);
    }
    if (unitId.present) {
      map['unit_id'] = Variable<String>(unitId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalProductVariantsCompanion(')
          ..write('id: $id, ')
          ..write('productId: $productId, ')
          ..write('isDefault: $isDefault, ')
          ..write('name: $name, ')
          ..write('sku: $sku, ')
          ..write('skuNorm: $skuNorm, ')
          ..write('attributesJson: $attributesJson, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('imageSha: $imageSha, ')
          ..write('deletionMark: $deletionMark, ')
          ..write('serverUpdatedAt: $serverUpdatedAt, ')
          ..write('multiplicityMilli: $multiplicityMilli, ')
          ..write('unitId: $unitId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalUnitsTable extends LocalUnits
    with TableInfo<$LocalUnitsTable, UnitRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalUnitsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _codeMeta = const VerificationMeta('code');
  @override
  late final GeneratedColumn<String> code = GeneratedColumn<String>(
    'code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _qtyPrecisionMeta = const VerificationMeta(
    'qtyPrecision',
  );
  @override
  late final GeneratedColumn<int> qtyPrecision = GeneratedColumn<int>(
    'qty_precision',
    aliasedName,
    false,
    check: () => ComparableExpr(qtyPrecision).isBetweenValues(0, 3),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _shortNameMeta = const VerificationMeta(
    'shortName',
  );
  @override
  late final GeneratedColumn<String> shortName = GeneratedColumn<String>(
    'short_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    code,
    name,
    qtyPrecision,
    id,
    shortName,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'units';
  @override
  VerificationContext validateIntegrity(
    Insertable<UnitRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('code')) {
      context.handle(
        _codeMeta,
        code.isAcceptableOrUnknown(data['code']!, _codeMeta),
      );
    } else if (isInserting) {
      context.missing(_codeMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('qty_precision')) {
      context.handle(
        _qtyPrecisionMeta,
        qtyPrecision.isAcceptableOrUnknown(
          data['qty_precision']!,
          _qtyPrecisionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_qtyPrecisionMeta);
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('short_name')) {
      context.handle(
        _shortNameMeta,
        shortName.isAcceptableOrUnknown(data['short_name']!, _shortNameMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {code};
  @override
  UnitRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UnitRow(
      code: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}code'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      qtyPrecision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}qty_precision'],
      )!,
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      ),
      shortName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}short_name'],
      ),
    );
  }

  @override
  $LocalUnitsTable createAlias(String alias) {
    return $LocalUnitsTable(attachedDatabase, alias);
  }
}

class UnitRow extends DataClass implements Insertable<UnitRow> {
  /// Код единицы (`Unit.code`; если сервер код не прислал — `Unit.id`).
  final String code;
  final String name;
  final int qtyPrecision;

  /// `Unit.id` — серверный UUID: на него ссылаются `unitId` варианта, упаковки, остатка. Схема v3.
  final String? id;

  /// `Unit.shortName` («шт»). Схема v3.
  final String? shortName;
  const UnitRow({
    required this.code,
    required this.name,
    required this.qtyPrecision,
    this.id,
    this.shortName,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['code'] = Variable<String>(code);
    map['name'] = Variable<String>(name);
    map['qty_precision'] = Variable<int>(qtyPrecision);
    if (!nullToAbsent || id != null) {
      map['id'] = Variable<String>(id);
    }
    if (!nullToAbsent || shortName != null) {
      map['short_name'] = Variable<String>(shortName);
    }
    return map;
  }

  LocalUnitsCompanion toCompanion(bool nullToAbsent) {
    return LocalUnitsCompanion(
      code: Value(code),
      name: Value(name),
      qtyPrecision: Value(qtyPrecision),
      id: id == null && nullToAbsent ? const Value.absent() : Value(id),
      shortName: shortName == null && nullToAbsent
          ? const Value.absent()
          : Value(shortName),
    );
  }

  factory UnitRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UnitRow(
      code: serializer.fromJson<String>(json['code']),
      name: serializer.fromJson<String>(json['name']),
      qtyPrecision: serializer.fromJson<int>(json['qtyPrecision']),
      id: serializer.fromJson<String?>(json['id']),
      shortName: serializer.fromJson<String?>(json['shortName']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'code': serializer.toJson<String>(code),
      'name': serializer.toJson<String>(name),
      'qtyPrecision': serializer.toJson<int>(qtyPrecision),
      'id': serializer.toJson<String?>(id),
      'shortName': serializer.toJson<String?>(shortName),
    };
  }

  UnitRow copyWith({
    String? code,
    String? name,
    int? qtyPrecision,
    Value<String?> id = const Value.absent(),
    Value<String?> shortName = const Value.absent(),
  }) => UnitRow(
    code: code ?? this.code,
    name: name ?? this.name,
    qtyPrecision: qtyPrecision ?? this.qtyPrecision,
    id: id.present ? id.value : this.id,
    shortName: shortName.present ? shortName.value : this.shortName,
  );
  UnitRow copyWithCompanion(LocalUnitsCompanion data) {
    return UnitRow(
      code: data.code.present ? data.code.value : this.code,
      name: data.name.present ? data.name.value : this.name,
      qtyPrecision: data.qtyPrecision.present
          ? data.qtyPrecision.value
          : this.qtyPrecision,
      id: data.id.present ? data.id.value : this.id,
      shortName: data.shortName.present ? data.shortName.value : this.shortName,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UnitRow(')
          ..write('code: $code, ')
          ..write('name: $name, ')
          ..write('qtyPrecision: $qtyPrecision, ')
          ..write('id: $id, ')
          ..write('shortName: $shortName')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(code, name, qtyPrecision, id, shortName);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UnitRow &&
          other.code == this.code &&
          other.name == this.name &&
          other.qtyPrecision == this.qtyPrecision &&
          other.id == this.id &&
          other.shortName == this.shortName);
}

class LocalUnitsCompanion extends UpdateCompanion<UnitRow> {
  final Value<String> code;
  final Value<String> name;
  final Value<int> qtyPrecision;
  final Value<String?> id;
  final Value<String?> shortName;
  final Value<int> rowid;
  const LocalUnitsCompanion({
    this.code = const Value.absent(),
    this.name = const Value.absent(),
    this.qtyPrecision = const Value.absent(),
    this.id = const Value.absent(),
    this.shortName = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalUnitsCompanion.insert({
    required String code,
    required String name,
    required int qtyPrecision,
    this.id = const Value.absent(),
    this.shortName = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : code = Value(code),
       name = Value(name),
       qtyPrecision = Value(qtyPrecision);
  static Insertable<UnitRow> custom({
    Expression<String>? code,
    Expression<String>? name,
    Expression<int>? qtyPrecision,
    Expression<String>? id,
    Expression<String>? shortName,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (code != null) 'code': code,
      if (name != null) 'name': name,
      if (qtyPrecision != null) 'qty_precision': qtyPrecision,
      if (id != null) 'id': id,
      if (shortName != null) 'short_name': shortName,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalUnitsCompanion copyWith({
    Value<String>? code,
    Value<String>? name,
    Value<int>? qtyPrecision,
    Value<String?>? id,
    Value<String?>? shortName,
    Value<int>? rowid,
  }) {
    return LocalUnitsCompanion(
      code: code ?? this.code,
      name: name ?? this.name,
      qtyPrecision: qtyPrecision ?? this.qtyPrecision,
      id: id ?? this.id,
      shortName: shortName ?? this.shortName,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (code.present) {
      map['code'] = Variable<String>(code.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (qtyPrecision.present) {
      map['qty_precision'] = Variable<int>(qtyPrecision.value);
    }
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (shortName.present) {
      map['short_name'] = Variable<String>(shortName.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalUnitsCompanion(')
          ..write('code: $code, ')
          ..write('name: $name, ')
          ..write('qtyPrecision: $qtyPrecision, ')
          ..write('id: $id, ')
          ..write('shortName: $shortName, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalPackagingsTable extends LocalPackagings
    with TableInfo<$LocalPackagingsTable, PackagingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalPackagingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _unitCodeMeta = const VerificationMeta(
    'unitCode',
  );
  @override
  late final GeneratedColumn<String> unitCode = GeneratedColumn<String>(
    'unit_code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _factorMilliMeta = const VerificationMeta(
    'factorMilli',
  );
  @override
  late final GeneratedColumn<int> factorMilli = GeneratedColumn<int>(
    'factor_milli',
    aliasedName,
    false,
    check: () => ComparableExpr(factorMilli).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _allowFractionMeta = const VerificationMeta(
    'allowFraction',
  );
  @override
  late final GeneratedColumn<bool> allowFraction = GeneratedColumn<bool>(
    'allow_fraction',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("allow_fraction" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isDefaultMeta = const VerificationMeta(
    'isDefault',
  );
  @override
  late final GeneratedColumn<bool> isDefault = GeneratedColumn<bool>(
    'is_default',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_default" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _variantIdMeta = const VerificationMeta(
    'variantId',
  );
  @override
  late final GeneratedColumn<String> variantId = GeneratedColumn<String>(
    'variant_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _unitIdMeta = const VerificationMeta('unitId');
  @override
  late final GeneratedColumn<String> unitId = GeneratedColumn<String>(
    'unit_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    productId,
    unitCode,
    name,
    factorMilli,
    allowFraction,
    isDefault,
    variantId,
    unitId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'packagings';
  @override
  VerificationContext validateIntegrity(
    Insertable<PackagingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('unit_code')) {
      context.handle(
        _unitCodeMeta,
        unitCode.isAcceptableOrUnknown(data['unit_code']!, _unitCodeMeta),
      );
    } else if (isInserting) {
      context.missing(_unitCodeMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('factor_milli')) {
      context.handle(
        _factorMilliMeta,
        factorMilli.isAcceptableOrUnknown(
          data['factor_milli']!,
          _factorMilliMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_factorMilliMeta);
    }
    if (data.containsKey('allow_fraction')) {
      context.handle(
        _allowFractionMeta,
        allowFraction.isAcceptableOrUnknown(
          data['allow_fraction']!,
          _allowFractionMeta,
        ),
      );
    }
    if (data.containsKey('is_default')) {
      context.handle(
        _isDefaultMeta,
        isDefault.isAcceptableOrUnknown(data['is_default']!, _isDefaultMeta),
      );
    }
    if (data.containsKey('variant_id')) {
      context.handle(
        _variantIdMeta,
        variantId.isAcceptableOrUnknown(data['variant_id']!, _variantIdMeta),
      );
    }
    if (data.containsKey('unit_id')) {
      context.handle(
        _unitIdMeta,
        unitId.isAcceptableOrUnknown(data['unit_id']!, _unitIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PackagingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PackagingRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      unitCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}unit_code'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      factorMilli: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}factor_milli'],
      )!,
      allowFraction: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}allow_fraction'],
      )!,
      isDefault: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_default'],
      )!,
      variantId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variant_id'],
      ),
      unitId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}unit_id'],
      ),
    );
  }

  @override
  $LocalPackagingsTable createAlias(String alias) {
    return $LocalPackagingsTable(attachedDatabase, alias);
  }
}

class PackagingRow extends DataClass implements Insertable<PackagingRow> {
  final String id;
  final String productId;
  final String unitCode;
  final String name;
  final int factorMilli;
  final bool allowFraction;
  final bool isDefault;

  /// `Packaging.variantId` (08 §4.24). Схема v3.
  final String? variantId;

  /// `Packaging.unitId` — серверный UUID единицы. Схема v3.
  final String? unitId;
  const PackagingRow({
    required this.id,
    required this.productId,
    required this.unitCode,
    required this.name,
    required this.factorMilli,
    required this.allowFraction,
    required this.isDefault,
    this.variantId,
    this.unitId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['product_id'] = Variable<String>(productId);
    map['unit_code'] = Variable<String>(unitCode);
    map['name'] = Variable<String>(name);
    map['factor_milli'] = Variable<int>(factorMilli);
    map['allow_fraction'] = Variable<bool>(allowFraction);
    map['is_default'] = Variable<bool>(isDefault);
    if (!nullToAbsent || variantId != null) {
      map['variant_id'] = Variable<String>(variantId);
    }
    if (!nullToAbsent || unitId != null) {
      map['unit_id'] = Variable<String>(unitId);
    }
    return map;
  }

  LocalPackagingsCompanion toCompanion(bool nullToAbsent) {
    return LocalPackagingsCompanion(
      id: Value(id),
      productId: Value(productId),
      unitCode: Value(unitCode),
      name: Value(name),
      factorMilli: Value(factorMilli),
      allowFraction: Value(allowFraction),
      isDefault: Value(isDefault),
      variantId: variantId == null && nullToAbsent
          ? const Value.absent()
          : Value(variantId),
      unitId: unitId == null && nullToAbsent
          ? const Value.absent()
          : Value(unitId),
    );
  }

  factory PackagingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PackagingRow(
      id: serializer.fromJson<String>(json['id']),
      productId: serializer.fromJson<String>(json['productId']),
      unitCode: serializer.fromJson<String>(json['unitCode']),
      name: serializer.fromJson<String>(json['name']),
      factorMilli: serializer.fromJson<int>(json['factorMilli']),
      allowFraction: serializer.fromJson<bool>(json['allowFraction']),
      isDefault: serializer.fromJson<bool>(json['isDefault']),
      variantId: serializer.fromJson<String?>(json['variantId']),
      unitId: serializer.fromJson<String?>(json['unitId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'productId': serializer.toJson<String>(productId),
      'unitCode': serializer.toJson<String>(unitCode),
      'name': serializer.toJson<String>(name),
      'factorMilli': serializer.toJson<int>(factorMilli),
      'allowFraction': serializer.toJson<bool>(allowFraction),
      'isDefault': serializer.toJson<bool>(isDefault),
      'variantId': serializer.toJson<String?>(variantId),
      'unitId': serializer.toJson<String?>(unitId),
    };
  }

  PackagingRow copyWith({
    String? id,
    String? productId,
    String? unitCode,
    String? name,
    int? factorMilli,
    bool? allowFraction,
    bool? isDefault,
    Value<String?> variantId = const Value.absent(),
    Value<String?> unitId = const Value.absent(),
  }) => PackagingRow(
    id: id ?? this.id,
    productId: productId ?? this.productId,
    unitCode: unitCode ?? this.unitCode,
    name: name ?? this.name,
    factorMilli: factorMilli ?? this.factorMilli,
    allowFraction: allowFraction ?? this.allowFraction,
    isDefault: isDefault ?? this.isDefault,
    variantId: variantId.present ? variantId.value : this.variantId,
    unitId: unitId.present ? unitId.value : this.unitId,
  );
  PackagingRow copyWithCompanion(LocalPackagingsCompanion data) {
    return PackagingRow(
      id: data.id.present ? data.id.value : this.id,
      productId: data.productId.present ? data.productId.value : this.productId,
      unitCode: data.unitCode.present ? data.unitCode.value : this.unitCode,
      name: data.name.present ? data.name.value : this.name,
      factorMilli: data.factorMilli.present
          ? data.factorMilli.value
          : this.factorMilli,
      allowFraction: data.allowFraction.present
          ? data.allowFraction.value
          : this.allowFraction,
      isDefault: data.isDefault.present ? data.isDefault.value : this.isDefault,
      variantId: data.variantId.present ? data.variantId.value : this.variantId,
      unitId: data.unitId.present ? data.unitId.value : this.unitId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PackagingRow(')
          ..write('id: $id, ')
          ..write('productId: $productId, ')
          ..write('unitCode: $unitCode, ')
          ..write('name: $name, ')
          ..write('factorMilli: $factorMilli, ')
          ..write('allowFraction: $allowFraction, ')
          ..write('isDefault: $isDefault, ')
          ..write('variantId: $variantId, ')
          ..write('unitId: $unitId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    productId,
    unitCode,
    name,
    factorMilli,
    allowFraction,
    isDefault,
    variantId,
    unitId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PackagingRow &&
          other.id == this.id &&
          other.productId == this.productId &&
          other.unitCode == this.unitCode &&
          other.name == this.name &&
          other.factorMilli == this.factorMilli &&
          other.allowFraction == this.allowFraction &&
          other.isDefault == this.isDefault &&
          other.variantId == this.variantId &&
          other.unitId == this.unitId);
}

class LocalPackagingsCompanion extends UpdateCompanion<PackagingRow> {
  final Value<String> id;
  final Value<String> productId;
  final Value<String> unitCode;
  final Value<String> name;
  final Value<int> factorMilli;
  final Value<bool> allowFraction;
  final Value<bool> isDefault;
  final Value<String?> variantId;
  final Value<String?> unitId;
  final Value<int> rowid;
  const LocalPackagingsCompanion({
    this.id = const Value.absent(),
    this.productId = const Value.absent(),
    this.unitCode = const Value.absent(),
    this.name = const Value.absent(),
    this.factorMilli = const Value.absent(),
    this.allowFraction = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.variantId = const Value.absent(),
    this.unitId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalPackagingsCompanion.insert({
    required String id,
    required String productId,
    required String unitCode,
    required String name,
    required int factorMilli,
    this.allowFraction = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.variantId = const Value.absent(),
    this.unitId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       productId = Value(productId),
       unitCode = Value(unitCode),
       name = Value(name),
       factorMilli = Value(factorMilli);
  static Insertable<PackagingRow> custom({
    Expression<String>? id,
    Expression<String>? productId,
    Expression<String>? unitCode,
    Expression<String>? name,
    Expression<int>? factorMilli,
    Expression<bool>? allowFraction,
    Expression<bool>? isDefault,
    Expression<String>? variantId,
    Expression<String>? unitId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (productId != null) 'product_id': productId,
      if (unitCode != null) 'unit_code': unitCode,
      if (name != null) 'name': name,
      if (factorMilli != null) 'factor_milli': factorMilli,
      if (allowFraction != null) 'allow_fraction': allowFraction,
      if (isDefault != null) 'is_default': isDefault,
      if (variantId != null) 'variant_id': variantId,
      if (unitId != null) 'unit_id': unitId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalPackagingsCompanion copyWith({
    Value<String>? id,
    Value<String>? productId,
    Value<String>? unitCode,
    Value<String>? name,
    Value<int>? factorMilli,
    Value<bool>? allowFraction,
    Value<bool>? isDefault,
    Value<String?>? variantId,
    Value<String?>? unitId,
    Value<int>? rowid,
  }) {
    return LocalPackagingsCompanion(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      unitCode: unitCode ?? this.unitCode,
      name: name ?? this.name,
      factorMilli: factorMilli ?? this.factorMilli,
      allowFraction: allowFraction ?? this.allowFraction,
      isDefault: isDefault ?? this.isDefault,
      variantId: variantId ?? this.variantId,
      unitId: unitId ?? this.unitId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (unitCode.present) {
      map['unit_code'] = Variable<String>(unitCode.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (factorMilli.present) {
      map['factor_milli'] = Variable<int>(factorMilli.value);
    }
    if (allowFraction.present) {
      map['allow_fraction'] = Variable<bool>(allowFraction.value);
    }
    if (isDefault.present) {
      map['is_default'] = Variable<bool>(isDefault.value);
    }
    if (variantId.present) {
      map['variant_id'] = Variable<String>(variantId.value);
    }
    if (unitId.present) {
      map['unit_id'] = Variable<String>(unitId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalPackagingsCompanion(')
          ..write('id: $id, ')
          ..write('productId: $productId, ')
          ..write('unitCode: $unitCode, ')
          ..write('name: $name, ')
          ..write('factorMilli: $factorMilli, ')
          ..write('allowFraction: $allowFraction, ')
          ..write('isDefault: $isDefault, ')
          ..write('variantId: $variantId, ')
          ..write('unitId: $unitId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalBarcodesTable extends LocalBarcodes
    with TableInfo<$LocalBarcodesTable, BarcodeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalBarcodesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _variantIdMeta = const VerificationMeta(
    'variantId',
  );
  @override
  late final GeneratedColumn<String> variantId = GeneratedColumn<String>(
    'variant_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _packagingIdMeta = const VerificationMeta(
    'packagingId',
  );
  @override
  late final GeneratedColumn<String> packagingId = GeneratedColumn<String>(
    'packaging_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _barcodeTypeMeta = const VerificationMeta(
    'barcodeType',
  );
  @override
  late final GeneratedColumn<String> barcodeType = GeneratedColumn<String>(
    'barcode_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    value,
    productId,
    variantId,
    packagingId,
    barcodeType,
    serverId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'barcodes';
  @override
  VerificationContext validateIntegrity(
    Insertable<BarcodeRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('variant_id')) {
      context.handle(
        _variantIdMeta,
        variantId.isAcceptableOrUnknown(data['variant_id']!, _variantIdMeta),
      );
    }
    if (data.containsKey('packaging_id')) {
      context.handle(
        _packagingIdMeta,
        packagingId.isAcceptableOrUnknown(
          data['packaging_id']!,
          _packagingIdMeta,
        ),
      );
    }
    if (data.containsKey('barcode_type')) {
      context.handle(
        _barcodeTypeMeta,
        barcodeType.isAcceptableOrUnknown(
          data['barcode_type']!,
          _barcodeTypeMeta,
        ),
      );
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {value};
  @override
  BarcodeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BarcodeRow(
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      variantId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variant_id'],
      ),
      packagingId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}packaging_id'],
      ),
      barcodeType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}barcode_type'],
      ),
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      ),
    );
  }

  @override
  $LocalBarcodesTable createAlias(String alias) {
    return $LocalBarcodesTable(attachedDatabase, alias);
  }
}

class BarcodeRow extends DataClass implements Insertable<BarcodeRow> {
  final String value;
  final String productId;
  final String? variantId;
  final String? packagingId;

  /// `BarcodeType` (`EAN13|EAN8|UPC|CODE128|CODE39|QR|other`). Схема v3.
  final String? barcodeType;

  /// Серверный uuid строки (`barcodes.id`): по нему применяется `deleted[]` (08 §4.24, EQ-CSYNC-02). Схема v4.
  final String? serverId;
  const BarcodeRow({
    required this.value,
    required this.productId,
    this.variantId,
    this.packagingId,
    this.barcodeType,
    this.serverId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['value'] = Variable<String>(value);
    map['product_id'] = Variable<String>(productId);
    if (!nullToAbsent || variantId != null) {
      map['variant_id'] = Variable<String>(variantId);
    }
    if (!nullToAbsent || packagingId != null) {
      map['packaging_id'] = Variable<String>(packagingId);
    }
    if (!nullToAbsent || barcodeType != null) {
      map['barcode_type'] = Variable<String>(barcodeType);
    }
    if (!nullToAbsent || serverId != null) {
      map['server_id'] = Variable<String>(serverId);
    }
    return map;
  }

  LocalBarcodesCompanion toCompanion(bool nullToAbsent) {
    return LocalBarcodesCompanion(
      value: Value(value),
      productId: Value(productId),
      variantId: variantId == null && nullToAbsent
          ? const Value.absent()
          : Value(variantId),
      packagingId: packagingId == null && nullToAbsent
          ? const Value.absent()
          : Value(packagingId),
      barcodeType: barcodeType == null && nullToAbsent
          ? const Value.absent()
          : Value(barcodeType),
      serverId: serverId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverId),
    );
  }

  factory BarcodeRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BarcodeRow(
      value: serializer.fromJson<String>(json['value']),
      productId: serializer.fromJson<String>(json['productId']),
      variantId: serializer.fromJson<String?>(json['variantId']),
      packagingId: serializer.fromJson<String?>(json['packagingId']),
      barcodeType: serializer.fromJson<String?>(json['barcodeType']),
      serverId: serializer.fromJson<String?>(json['serverId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'value': serializer.toJson<String>(value),
      'productId': serializer.toJson<String>(productId),
      'variantId': serializer.toJson<String?>(variantId),
      'packagingId': serializer.toJson<String?>(packagingId),
      'barcodeType': serializer.toJson<String?>(barcodeType),
      'serverId': serializer.toJson<String?>(serverId),
    };
  }

  BarcodeRow copyWith({
    String? value,
    String? productId,
    Value<String?> variantId = const Value.absent(),
    Value<String?> packagingId = const Value.absent(),
    Value<String?> barcodeType = const Value.absent(),
    Value<String?> serverId = const Value.absent(),
  }) => BarcodeRow(
    value: value ?? this.value,
    productId: productId ?? this.productId,
    variantId: variantId.present ? variantId.value : this.variantId,
    packagingId: packagingId.present ? packagingId.value : this.packagingId,
    barcodeType: barcodeType.present ? barcodeType.value : this.barcodeType,
    serverId: serverId.present ? serverId.value : this.serverId,
  );
  BarcodeRow copyWithCompanion(LocalBarcodesCompanion data) {
    return BarcodeRow(
      value: data.value.present ? data.value.value : this.value,
      productId: data.productId.present ? data.productId.value : this.productId,
      variantId: data.variantId.present ? data.variantId.value : this.variantId,
      packagingId: data.packagingId.present
          ? data.packagingId.value
          : this.packagingId,
      barcodeType: data.barcodeType.present
          ? data.barcodeType.value
          : this.barcodeType,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BarcodeRow(')
          ..write('value: $value, ')
          ..write('productId: $productId, ')
          ..write('variantId: $variantId, ')
          ..write('packagingId: $packagingId, ')
          ..write('barcodeType: $barcodeType, ')
          ..write('serverId: $serverId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    value,
    productId,
    variantId,
    packagingId,
    barcodeType,
    serverId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BarcodeRow &&
          other.value == this.value &&
          other.productId == this.productId &&
          other.variantId == this.variantId &&
          other.packagingId == this.packagingId &&
          other.barcodeType == this.barcodeType &&
          other.serverId == this.serverId);
}

class LocalBarcodesCompanion extends UpdateCompanion<BarcodeRow> {
  final Value<String> value;
  final Value<String> productId;
  final Value<String?> variantId;
  final Value<String?> packagingId;
  final Value<String?> barcodeType;
  final Value<String?> serverId;
  final Value<int> rowid;
  const LocalBarcodesCompanion({
    this.value = const Value.absent(),
    this.productId = const Value.absent(),
    this.variantId = const Value.absent(),
    this.packagingId = const Value.absent(),
    this.barcodeType = const Value.absent(),
    this.serverId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalBarcodesCompanion.insert({
    required String value,
    required String productId,
    this.variantId = const Value.absent(),
    this.packagingId = const Value.absent(),
    this.barcodeType = const Value.absent(),
    this.serverId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : value = Value(value),
       productId = Value(productId);
  static Insertable<BarcodeRow> custom({
    Expression<String>? value,
    Expression<String>? productId,
    Expression<String>? variantId,
    Expression<String>? packagingId,
    Expression<String>? barcodeType,
    Expression<String>? serverId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (value != null) 'value': value,
      if (productId != null) 'product_id': productId,
      if (variantId != null) 'variant_id': variantId,
      if (packagingId != null) 'packaging_id': packagingId,
      if (barcodeType != null) 'barcode_type': barcodeType,
      if (serverId != null) 'server_id': serverId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalBarcodesCompanion copyWith({
    Value<String>? value,
    Value<String>? productId,
    Value<String?>? variantId,
    Value<String?>? packagingId,
    Value<String?>? barcodeType,
    Value<String?>? serverId,
    Value<int>? rowid,
  }) {
    return LocalBarcodesCompanion(
      value: value ?? this.value,
      productId: productId ?? this.productId,
      variantId: variantId ?? this.variantId,
      packagingId: packagingId ?? this.packagingId,
      barcodeType: barcodeType ?? this.barcodeType,
      serverId: serverId ?? this.serverId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (variantId.present) {
      map['variant_id'] = Variable<String>(variantId.value);
    }
    if (packagingId.present) {
      map['packaging_id'] = Variable<String>(packagingId.value);
    }
    if (barcodeType.present) {
      map['barcode_type'] = Variable<String>(barcodeType.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalBarcodesCompanion(')
          ..write('value: $value, ')
          ..write('productId: $productId, ')
          ..write('variantId: $variantId, ')
          ..write('packagingId: $packagingId, ')
          ..write('barcodeType: $barcodeType, ')
          ..write('serverId: $serverId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalWarehousesTable extends LocalWarehouses
    with TableInfo<$LocalWarehousesTable, WarehouseRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalWarehousesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _shortNameMeta = const VerificationMeta(
    'shortName',
  );
  @override
  late final GeneratedColumn<String> shortName = GeneratedColumn<String>(
    'short_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isDefaultMeta = const VerificationMeta(
    'isDefault',
  );
  @override
  late final GeneratedColumn<bool> isDefault = GeneratedColumn<bool>(
    'is_default',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_default" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isActiveMeta = const VerificationMeta(
    'isActive',
  );
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
    'is_active',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_active" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    shortName,
    isDefault,
    isActive,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'warehouses';
  @override
  VerificationContext validateIntegrity(
    Insertable<WarehouseRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('short_name')) {
      context.handle(
        _shortNameMeta,
        shortName.isAcceptableOrUnknown(data['short_name']!, _shortNameMeta),
      );
    }
    if (data.containsKey('is_default')) {
      context.handle(
        _isDefaultMeta,
        isDefault.isAcceptableOrUnknown(data['is_default']!, _isDefaultMeta),
      );
    }
    if (data.containsKey('is_active')) {
      context.handle(
        _isActiveMeta,
        isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  WarehouseRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WarehouseRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      shortName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}short_name'],
      ),
      isDefault: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_default'],
      )!,
      isActive: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_active'],
      )!,
    );
  }

  @override
  $LocalWarehousesTable createAlias(String alias) {
    return $LocalWarehousesTable(attachedDatabase, alias);
  }
}

class WarehouseRow extends DataClass implements Insertable<WarehouseRow> {
  final String id;
  final String name;
  final String? shortName;
  final bool isDefault;
  final bool isActive;
  const WarehouseRow({
    required this.id,
    required this.name,
    this.shortName,
    required this.isDefault,
    required this.isActive,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || shortName != null) {
      map['short_name'] = Variable<String>(shortName);
    }
    map['is_default'] = Variable<bool>(isDefault);
    map['is_active'] = Variable<bool>(isActive);
    return map;
  }

  LocalWarehousesCompanion toCompanion(bool nullToAbsent) {
    return LocalWarehousesCompanion(
      id: Value(id),
      name: Value(name),
      shortName: shortName == null && nullToAbsent
          ? const Value.absent()
          : Value(shortName),
      isDefault: Value(isDefault),
      isActive: Value(isActive),
    );
  }

  factory WarehouseRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WarehouseRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      shortName: serializer.fromJson<String?>(json['shortName']),
      isDefault: serializer.fromJson<bool>(json['isDefault']),
      isActive: serializer.fromJson<bool>(json['isActive']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'shortName': serializer.toJson<String?>(shortName),
      'isDefault': serializer.toJson<bool>(isDefault),
      'isActive': serializer.toJson<bool>(isActive),
    };
  }

  WarehouseRow copyWith({
    String? id,
    String? name,
    Value<String?> shortName = const Value.absent(),
    bool? isDefault,
    bool? isActive,
  }) => WarehouseRow(
    id: id ?? this.id,
    name: name ?? this.name,
    shortName: shortName.present ? shortName.value : this.shortName,
    isDefault: isDefault ?? this.isDefault,
    isActive: isActive ?? this.isActive,
  );
  WarehouseRow copyWithCompanion(LocalWarehousesCompanion data) {
    return WarehouseRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      shortName: data.shortName.present ? data.shortName.value : this.shortName,
      isDefault: data.isDefault.present ? data.isDefault.value : this.isDefault,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WarehouseRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('shortName: $shortName, ')
          ..write('isDefault: $isDefault, ')
          ..write('isActive: $isActive')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, shortName, isDefault, isActive);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WarehouseRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.shortName == this.shortName &&
          other.isDefault == this.isDefault &&
          other.isActive == this.isActive);
}

class LocalWarehousesCompanion extends UpdateCompanion<WarehouseRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String?> shortName;
  final Value<bool> isDefault;
  final Value<bool> isActive;
  final Value<int> rowid;
  const LocalWarehousesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.shortName = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.isActive = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalWarehousesCompanion.insert({
    required String id,
    required String name,
    this.shortName = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.isActive = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<WarehouseRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? shortName,
    Expression<bool>? isDefault,
    Expression<bool>? isActive,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (shortName != null) 'short_name': shortName,
      if (isDefault != null) 'is_default': isDefault,
      if (isActive != null) 'is_active': isActive,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalWarehousesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String?>? shortName,
    Value<bool>? isDefault,
    Value<bool>? isActive,
    Value<int>? rowid,
  }) {
    return LocalWarehousesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      shortName: shortName ?? this.shortName,
      isDefault: isDefault ?? this.isDefault,
      isActive: isActive ?? this.isActive,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (shortName.present) {
      map['short_name'] = Variable<String>(shortName.value);
    }
    if (isDefault.present) {
      map['is_default'] = Variable<bool>(isDefault.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalWarehousesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('shortName: $shortName, ')
          ..write('isDefault: $isDefault, ')
          ..write('isActive: $isActive, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalPriceListsTable extends LocalPriceLists
    with TableInfo<$LocalPriceListsTable, PriceListRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalPriceListsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isDefaultMeta = const VerificationMeta(
    'isDefault',
  );
  @override
  late final GeneratedColumn<bool> isDefault = GeneratedColumn<bool>(
    'is_default',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_default" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _visibleMeta = const VerificationMeta(
    'visible',
  );
  @override
  late final GeneratedColumn<bool> visible = GeneratedColumn<bool>(
    'visible',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("visible" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, isDefault, visible];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'price_lists';
  @override
  VerificationContext validateIntegrity(
    Insertable<PriceListRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('is_default')) {
      context.handle(
        _isDefaultMeta,
        isDefault.isAcceptableOrUnknown(data['is_default']!, _isDefaultMeta),
      );
    }
    if (data.containsKey('visible')) {
      context.handle(
        _visibleMeta,
        visible.isAcceptableOrUnknown(data['visible']!, _visibleMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PriceListRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PriceListRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      isDefault: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_default'],
      )!,
      visible: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}visible'],
      )!,
    );
  }

  @override
  $LocalPriceListsTable createAlias(String alias) {
    return $LocalPriceListsTable(attachedDatabase, alias);
  }
}

class PriceListRow extends DataClass implements Insertable<PriceListRow> {
  final String id;
  final String name;
  final bool isDefault;
  final bool visible;
  const PriceListRow({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.visible,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['is_default'] = Variable<bool>(isDefault);
    map['visible'] = Variable<bool>(visible);
    return map;
  }

  LocalPriceListsCompanion toCompanion(bool nullToAbsent) {
    return LocalPriceListsCompanion(
      id: Value(id),
      name: Value(name),
      isDefault: Value(isDefault),
      visible: Value(visible),
    );
  }

  factory PriceListRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PriceListRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      isDefault: serializer.fromJson<bool>(json['isDefault']),
      visible: serializer.fromJson<bool>(json['visible']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'isDefault': serializer.toJson<bool>(isDefault),
      'visible': serializer.toJson<bool>(visible),
    };
  }

  PriceListRow copyWith({
    String? id,
    String? name,
    bool? isDefault,
    bool? visible,
  }) => PriceListRow(
    id: id ?? this.id,
    name: name ?? this.name,
    isDefault: isDefault ?? this.isDefault,
    visible: visible ?? this.visible,
  );
  PriceListRow copyWithCompanion(LocalPriceListsCompanion data) {
    return PriceListRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      isDefault: data.isDefault.present ? data.isDefault.value : this.isDefault,
      visible: data.visible.present ? data.visible.value : this.visible,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PriceListRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('isDefault: $isDefault, ')
          ..write('visible: $visible')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, isDefault, visible);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PriceListRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.isDefault == this.isDefault &&
          other.visible == this.visible);
}

class LocalPriceListsCompanion extends UpdateCompanion<PriceListRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<bool> isDefault;
  final Value<bool> visible;
  final Value<int> rowid;
  const LocalPriceListsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.visible = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalPriceListsCompanion.insert({
    required String id,
    required String name,
    this.isDefault = const Value.absent(),
    this.visible = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<PriceListRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<bool>? isDefault,
    Expression<bool>? visible,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (isDefault != null) 'is_default': isDefault,
      if (visible != null) 'visible': visible,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalPriceListsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<bool>? isDefault,
    Value<bool>? visible,
    Value<int>? rowid,
  }) {
    return LocalPriceListsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      isDefault: isDefault ?? this.isDefault,
      visible: visible ?? this.visible,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (isDefault.present) {
      map['is_default'] = Variable<bool>(isDefault.value);
    }
    if (visible.present) {
      map['visible'] = Variable<bool>(visible.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalPriceListsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('isDefault: $isDefault, ')
          ..write('visible: $visible, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalPricesTable extends LocalPrices
    with TableInfo<$LocalPricesTable, PriceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalPricesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _variantIdMeta = const VerificationMeta(
    'variantId',
  );
  @override
  late final GeneratedColumn<String> variantId = GeneratedColumn<String>(
    'variant_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _priceListIdMeta = const VerificationMeta(
    'priceListId',
  );
  @override
  late final GeneratedColumn<String> priceListId = GeneratedColumn<String>(
    'price_list_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _packagingIdMeta = const VerificationMeta(
    'packagingId',
  );
  @override
  late final GeneratedColumn<String> packagingId = GeneratedColumn<String>(
    'packaging_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _priceTyiynMeta = const VerificationMeta(
    'priceTyiyn',
  );
  @override
  late final GeneratedColumn<int> priceTyiyn = GeneratedColumn<int>(
    'price_tyiyn',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverSyncedAtMeta = const VerificationMeta(
    'serverSyncedAt',
  );
  @override
  late final GeneratedColumn<int> serverSyncedAt = GeneratedColumn<int>(
    'server_synced_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    variantId,
    priceListId,
    packagingId,
    priceTyiyn,
    serverSyncedAt,
    serverId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'prices';
  @override
  VerificationContext validateIntegrity(
    Insertable<PriceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('variant_id')) {
      context.handle(
        _variantIdMeta,
        variantId.isAcceptableOrUnknown(data['variant_id']!, _variantIdMeta),
      );
    } else if (isInserting) {
      context.missing(_variantIdMeta);
    }
    if (data.containsKey('price_list_id')) {
      context.handle(
        _priceListIdMeta,
        priceListId.isAcceptableOrUnknown(
          data['price_list_id']!,
          _priceListIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_priceListIdMeta);
    }
    if (data.containsKey('packaging_id')) {
      context.handle(
        _packagingIdMeta,
        packagingId.isAcceptableOrUnknown(
          data['packaging_id']!,
          _packagingIdMeta,
        ),
      );
    }
    if (data.containsKey('price_tyiyn')) {
      context.handle(
        _priceTyiynMeta,
        priceTyiyn.isAcceptableOrUnknown(data['price_tyiyn']!, _priceTyiynMeta),
      );
    } else if (isInserting) {
      context.missing(_priceTyiynMeta);
    }
    if (data.containsKey('server_synced_at')) {
      context.handle(
        _serverSyncedAtMeta,
        serverSyncedAt.isAcceptableOrUnknown(
          data['server_synced_at']!,
          _serverSyncedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverSyncedAtMeta);
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {variantId, priceListId, packagingId};
  @override
  PriceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PriceRow(
      variantId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variant_id'],
      )!,
      priceListId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}price_list_id'],
      )!,
      packagingId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}packaging_id'],
      ),
      priceTyiyn: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}price_tyiyn'],
      )!,
      serverSyncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_synced_at'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      ),
    );
  }

  @override
  $LocalPricesTable createAlias(String alias) {
    return $LocalPricesTable(attachedDatabase, alias);
  }
}

class PriceRow extends DataClass implements Insertable<PriceRow> {
  final String variantId;
  final String priceListId;
  final String? packagingId;
  final int priceTyiyn;
  final int serverSyncedAt;

  /// Серверный uuid строки (`prices.id`): по нему применяется `deleted[]` (08 §4.24, EQ-CSYNC-02). Схема v4.
  final String? serverId;
  const PriceRow({
    required this.variantId,
    required this.priceListId,
    this.packagingId,
    required this.priceTyiyn,
    required this.serverSyncedAt,
    this.serverId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['variant_id'] = Variable<String>(variantId);
    map['price_list_id'] = Variable<String>(priceListId);
    if (!nullToAbsent || packagingId != null) {
      map['packaging_id'] = Variable<String>(packagingId);
    }
    map['price_tyiyn'] = Variable<int>(priceTyiyn);
    map['server_synced_at'] = Variable<int>(serverSyncedAt);
    if (!nullToAbsent || serverId != null) {
      map['server_id'] = Variable<String>(serverId);
    }
    return map;
  }

  LocalPricesCompanion toCompanion(bool nullToAbsent) {
    return LocalPricesCompanion(
      variantId: Value(variantId),
      priceListId: Value(priceListId),
      packagingId: packagingId == null && nullToAbsent
          ? const Value.absent()
          : Value(packagingId),
      priceTyiyn: Value(priceTyiyn),
      serverSyncedAt: Value(serverSyncedAt),
      serverId: serverId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverId),
    );
  }

  factory PriceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PriceRow(
      variantId: serializer.fromJson<String>(json['variantId']),
      priceListId: serializer.fromJson<String>(json['priceListId']),
      packagingId: serializer.fromJson<String?>(json['packagingId']),
      priceTyiyn: serializer.fromJson<int>(json['priceTyiyn']),
      serverSyncedAt: serializer.fromJson<int>(json['serverSyncedAt']),
      serverId: serializer.fromJson<String?>(json['serverId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'variantId': serializer.toJson<String>(variantId),
      'priceListId': serializer.toJson<String>(priceListId),
      'packagingId': serializer.toJson<String?>(packagingId),
      'priceTyiyn': serializer.toJson<int>(priceTyiyn),
      'serverSyncedAt': serializer.toJson<int>(serverSyncedAt),
      'serverId': serializer.toJson<String?>(serverId),
    };
  }

  PriceRow copyWith({
    String? variantId,
    String? priceListId,
    Value<String?> packagingId = const Value.absent(),
    int? priceTyiyn,
    int? serverSyncedAt,
    Value<String?> serverId = const Value.absent(),
  }) => PriceRow(
    variantId: variantId ?? this.variantId,
    priceListId: priceListId ?? this.priceListId,
    packagingId: packagingId.present ? packagingId.value : this.packagingId,
    priceTyiyn: priceTyiyn ?? this.priceTyiyn,
    serverSyncedAt: serverSyncedAt ?? this.serverSyncedAt,
    serverId: serverId.present ? serverId.value : this.serverId,
  );
  PriceRow copyWithCompanion(LocalPricesCompanion data) {
    return PriceRow(
      variantId: data.variantId.present ? data.variantId.value : this.variantId,
      priceListId: data.priceListId.present
          ? data.priceListId.value
          : this.priceListId,
      packagingId: data.packagingId.present
          ? data.packagingId.value
          : this.packagingId,
      priceTyiyn: data.priceTyiyn.present
          ? data.priceTyiyn.value
          : this.priceTyiyn,
      serverSyncedAt: data.serverSyncedAt.present
          ? data.serverSyncedAt.value
          : this.serverSyncedAt,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PriceRow(')
          ..write('variantId: $variantId, ')
          ..write('priceListId: $priceListId, ')
          ..write('packagingId: $packagingId, ')
          ..write('priceTyiyn: $priceTyiyn, ')
          ..write('serverSyncedAt: $serverSyncedAt, ')
          ..write('serverId: $serverId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    variantId,
    priceListId,
    packagingId,
    priceTyiyn,
    serverSyncedAt,
    serverId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PriceRow &&
          other.variantId == this.variantId &&
          other.priceListId == this.priceListId &&
          other.packagingId == this.packagingId &&
          other.priceTyiyn == this.priceTyiyn &&
          other.serverSyncedAt == this.serverSyncedAt &&
          other.serverId == this.serverId);
}

class LocalPricesCompanion extends UpdateCompanion<PriceRow> {
  final Value<String> variantId;
  final Value<String> priceListId;
  final Value<String?> packagingId;
  final Value<int> priceTyiyn;
  final Value<int> serverSyncedAt;
  final Value<String?> serverId;
  final Value<int> rowid;
  const LocalPricesCompanion({
    this.variantId = const Value.absent(),
    this.priceListId = const Value.absent(),
    this.packagingId = const Value.absent(),
    this.priceTyiyn = const Value.absent(),
    this.serverSyncedAt = const Value.absent(),
    this.serverId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalPricesCompanion.insert({
    required String variantId,
    required String priceListId,
    this.packagingId = const Value.absent(),
    required int priceTyiyn,
    required int serverSyncedAt,
    this.serverId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : variantId = Value(variantId),
       priceListId = Value(priceListId),
       priceTyiyn = Value(priceTyiyn),
       serverSyncedAt = Value(serverSyncedAt);
  static Insertable<PriceRow> custom({
    Expression<String>? variantId,
    Expression<String>? priceListId,
    Expression<String>? packagingId,
    Expression<int>? priceTyiyn,
    Expression<int>? serverSyncedAt,
    Expression<String>? serverId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (variantId != null) 'variant_id': variantId,
      if (priceListId != null) 'price_list_id': priceListId,
      if (packagingId != null) 'packaging_id': packagingId,
      if (priceTyiyn != null) 'price_tyiyn': priceTyiyn,
      if (serverSyncedAt != null) 'server_synced_at': serverSyncedAt,
      if (serverId != null) 'server_id': serverId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalPricesCompanion copyWith({
    Value<String>? variantId,
    Value<String>? priceListId,
    Value<String?>? packagingId,
    Value<int>? priceTyiyn,
    Value<int>? serverSyncedAt,
    Value<String?>? serverId,
    Value<int>? rowid,
  }) {
    return LocalPricesCompanion(
      variantId: variantId ?? this.variantId,
      priceListId: priceListId ?? this.priceListId,
      packagingId: packagingId ?? this.packagingId,
      priceTyiyn: priceTyiyn ?? this.priceTyiyn,
      serverSyncedAt: serverSyncedAt ?? this.serverSyncedAt,
      serverId: serverId ?? this.serverId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (variantId.present) {
      map['variant_id'] = Variable<String>(variantId.value);
    }
    if (priceListId.present) {
      map['price_list_id'] = Variable<String>(priceListId.value);
    }
    if (packagingId.present) {
      map['packaging_id'] = Variable<String>(packagingId.value);
    }
    if (priceTyiyn.present) {
      map['price_tyiyn'] = Variable<int>(priceTyiyn.value);
    }
    if (serverSyncedAt.present) {
      map['server_synced_at'] = Variable<int>(serverSyncedAt.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalPricesCompanion(')
          ..write('variantId: $variantId, ')
          ..write('priceListId: $priceListId, ')
          ..write('packagingId: $packagingId, ')
          ..write('priceTyiyn: $priceTyiyn, ')
          ..write('serverSyncedAt: $serverSyncedAt, ')
          ..write('serverId: $serverId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalStockBalancesTable extends LocalStockBalances
    with TableInfo<$LocalStockBalancesTable, StockBalanceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalStockBalancesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _variantIdMeta = const VerificationMeta(
    'variantId',
  );
  @override
  late final GeneratedColumn<String> variantId = GeneratedColumn<String>(
    'variant_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _warehouseIdMeta = const VerificationMeta(
    'warehouseId',
  );
  @override
  late final GeneratedColumn<String> warehouseId = GeneratedColumn<String>(
    'warehouse_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _quantityMilliMeta = const VerificationMeta(
    'quantityMilli',
  );
  @override
  late final GeneratedColumn<int> quantityMilli = GeneratedColumn<int>(
    'quantity_milli',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _reservedMilliMeta = const VerificationMeta(
    'reservedMilli',
  );
  @override
  late final GeneratedColumn<int> reservedMilli = GeneratedColumn<int>(
    'reserved_milli',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _availableMilliMeta = const VerificationMeta(
    'availableMilli',
  );
  @override
  late final GeneratedColumn<int> availableMilli = GeneratedColumn<int>(
    'available_milli',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stockLevelMeta = const VerificationMeta(
    'stockLevel',
  );
  @override
  late final GeneratedColumn<String> stockLevel = GeneratedColumn<String>(
    'stock_level',
    aliasedName,
    false,
    check: () => stockLevel.isIn(const ['in_stock', 'low', 'out', 'unknown']),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('unknown'),
  );
  static const VerificationMeta _snapshotAtMeta = const VerificationMeta(
    'snapshotAt',
  );
  @override
  late final GeneratedColumn<int> snapshotAt = GeneratedColumn<int>(
    'snapshot_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    variantId,
    warehouseId,
    quantityMilli,
    reservedMilli,
    availableMilli,
    stockLevel,
    snapshotAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stock_balances';
  @override
  VerificationContext validateIntegrity(
    Insertable<StockBalanceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('variant_id')) {
      context.handle(
        _variantIdMeta,
        variantId.isAcceptableOrUnknown(data['variant_id']!, _variantIdMeta),
      );
    } else if (isInserting) {
      context.missing(_variantIdMeta);
    }
    if (data.containsKey('warehouse_id')) {
      context.handle(
        _warehouseIdMeta,
        warehouseId.isAcceptableOrUnknown(
          data['warehouse_id']!,
          _warehouseIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_warehouseIdMeta);
    }
    if (data.containsKey('quantity_milli')) {
      context.handle(
        _quantityMilliMeta,
        quantityMilli.isAcceptableOrUnknown(
          data['quantity_milli']!,
          _quantityMilliMeta,
        ),
      );
    }
    if (data.containsKey('reserved_milli')) {
      context.handle(
        _reservedMilliMeta,
        reservedMilli.isAcceptableOrUnknown(
          data['reserved_milli']!,
          _reservedMilliMeta,
        ),
      );
    }
    if (data.containsKey('available_milli')) {
      context.handle(
        _availableMilliMeta,
        availableMilli.isAcceptableOrUnknown(
          data['available_milli']!,
          _availableMilliMeta,
        ),
      );
    }
    if (data.containsKey('stock_level')) {
      context.handle(
        _stockLevelMeta,
        stockLevel.isAcceptableOrUnknown(data['stock_level']!, _stockLevelMeta),
      );
    }
    if (data.containsKey('snapshot_at')) {
      context.handle(
        _snapshotAtMeta,
        snapshotAt.isAcceptableOrUnknown(data['snapshot_at']!, _snapshotAtMeta),
      );
    } else if (isInserting) {
      context.missing(_snapshotAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {variantId, warehouseId};
  @override
  StockBalanceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StockBalanceRow(
      variantId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variant_id'],
      )!,
      warehouseId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}warehouse_id'],
      )!,
      quantityMilli: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}quantity_milli'],
      ),
      reservedMilli: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reserved_milli'],
      ),
      availableMilli: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}available_milli'],
      ),
      stockLevel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stock_level'],
      )!,
      snapshotAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}snapshot_at'],
      )!,
    );
  }

  @override
  $LocalStockBalancesTable createAlias(String alias) {
    return $LocalStockBalancesTable(attachedDatabase, alias);
  }
}

class StockBalanceRow extends DataClass implements Insertable<StockBalanceRow> {
  final String variantId;
  final String warehouseId;
  final int? quantityMilli;
  final int? reservedMilli;
  final int? availableMilli;

  /// `in_stock | low | out | unknown` (08 `StockBalance.stockLevel`). Схема v2.
  final String stockLevel;
  final int snapshotAt;
  const StockBalanceRow({
    required this.variantId,
    required this.warehouseId,
    this.quantityMilli,
    this.reservedMilli,
    this.availableMilli,
    required this.stockLevel,
    required this.snapshotAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['variant_id'] = Variable<String>(variantId);
    map['warehouse_id'] = Variable<String>(warehouseId);
    if (!nullToAbsent || quantityMilli != null) {
      map['quantity_milli'] = Variable<int>(quantityMilli);
    }
    if (!nullToAbsent || reservedMilli != null) {
      map['reserved_milli'] = Variable<int>(reservedMilli);
    }
    if (!nullToAbsent || availableMilli != null) {
      map['available_milli'] = Variable<int>(availableMilli);
    }
    map['stock_level'] = Variable<String>(stockLevel);
    map['snapshot_at'] = Variable<int>(snapshotAt);
    return map;
  }

  LocalStockBalancesCompanion toCompanion(bool nullToAbsent) {
    return LocalStockBalancesCompanion(
      variantId: Value(variantId),
      warehouseId: Value(warehouseId),
      quantityMilli: quantityMilli == null && nullToAbsent
          ? const Value.absent()
          : Value(quantityMilli),
      reservedMilli: reservedMilli == null && nullToAbsent
          ? const Value.absent()
          : Value(reservedMilli),
      availableMilli: availableMilli == null && nullToAbsent
          ? const Value.absent()
          : Value(availableMilli),
      stockLevel: Value(stockLevel),
      snapshotAt: Value(snapshotAt),
    );
  }

  factory StockBalanceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StockBalanceRow(
      variantId: serializer.fromJson<String>(json['variantId']),
      warehouseId: serializer.fromJson<String>(json['warehouseId']),
      quantityMilli: serializer.fromJson<int?>(json['quantityMilli']),
      reservedMilli: serializer.fromJson<int?>(json['reservedMilli']),
      availableMilli: serializer.fromJson<int?>(json['availableMilli']),
      stockLevel: serializer.fromJson<String>(json['stockLevel']),
      snapshotAt: serializer.fromJson<int>(json['snapshotAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'variantId': serializer.toJson<String>(variantId),
      'warehouseId': serializer.toJson<String>(warehouseId),
      'quantityMilli': serializer.toJson<int?>(quantityMilli),
      'reservedMilli': serializer.toJson<int?>(reservedMilli),
      'availableMilli': serializer.toJson<int?>(availableMilli),
      'stockLevel': serializer.toJson<String>(stockLevel),
      'snapshotAt': serializer.toJson<int>(snapshotAt),
    };
  }

  StockBalanceRow copyWith({
    String? variantId,
    String? warehouseId,
    Value<int?> quantityMilli = const Value.absent(),
    Value<int?> reservedMilli = const Value.absent(),
    Value<int?> availableMilli = const Value.absent(),
    String? stockLevel,
    int? snapshotAt,
  }) => StockBalanceRow(
    variantId: variantId ?? this.variantId,
    warehouseId: warehouseId ?? this.warehouseId,
    quantityMilli: quantityMilli.present
        ? quantityMilli.value
        : this.quantityMilli,
    reservedMilli: reservedMilli.present
        ? reservedMilli.value
        : this.reservedMilli,
    availableMilli: availableMilli.present
        ? availableMilli.value
        : this.availableMilli,
    stockLevel: stockLevel ?? this.stockLevel,
    snapshotAt: snapshotAt ?? this.snapshotAt,
  );
  StockBalanceRow copyWithCompanion(LocalStockBalancesCompanion data) {
    return StockBalanceRow(
      variantId: data.variantId.present ? data.variantId.value : this.variantId,
      warehouseId: data.warehouseId.present
          ? data.warehouseId.value
          : this.warehouseId,
      quantityMilli: data.quantityMilli.present
          ? data.quantityMilli.value
          : this.quantityMilli,
      reservedMilli: data.reservedMilli.present
          ? data.reservedMilli.value
          : this.reservedMilli,
      availableMilli: data.availableMilli.present
          ? data.availableMilli.value
          : this.availableMilli,
      stockLevel: data.stockLevel.present
          ? data.stockLevel.value
          : this.stockLevel,
      snapshotAt: data.snapshotAt.present
          ? data.snapshotAt.value
          : this.snapshotAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StockBalanceRow(')
          ..write('variantId: $variantId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('quantityMilli: $quantityMilli, ')
          ..write('reservedMilli: $reservedMilli, ')
          ..write('availableMilli: $availableMilli, ')
          ..write('stockLevel: $stockLevel, ')
          ..write('snapshotAt: $snapshotAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    variantId,
    warehouseId,
    quantityMilli,
    reservedMilli,
    availableMilli,
    stockLevel,
    snapshotAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StockBalanceRow &&
          other.variantId == this.variantId &&
          other.warehouseId == this.warehouseId &&
          other.quantityMilli == this.quantityMilli &&
          other.reservedMilli == this.reservedMilli &&
          other.availableMilli == this.availableMilli &&
          other.stockLevel == this.stockLevel &&
          other.snapshotAt == this.snapshotAt);
}

class LocalStockBalancesCompanion extends UpdateCompanion<StockBalanceRow> {
  final Value<String> variantId;
  final Value<String> warehouseId;
  final Value<int?> quantityMilli;
  final Value<int?> reservedMilli;
  final Value<int?> availableMilli;
  final Value<String> stockLevel;
  final Value<int> snapshotAt;
  final Value<int> rowid;
  const LocalStockBalancesCompanion({
    this.variantId = const Value.absent(),
    this.warehouseId = const Value.absent(),
    this.quantityMilli = const Value.absent(),
    this.reservedMilli = const Value.absent(),
    this.availableMilli = const Value.absent(),
    this.stockLevel = const Value.absent(),
    this.snapshotAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalStockBalancesCompanion.insert({
    required String variantId,
    required String warehouseId,
    this.quantityMilli = const Value.absent(),
    this.reservedMilli = const Value.absent(),
    this.availableMilli = const Value.absent(),
    this.stockLevel = const Value.absent(),
    required int snapshotAt,
    this.rowid = const Value.absent(),
  }) : variantId = Value(variantId),
       warehouseId = Value(warehouseId),
       snapshotAt = Value(snapshotAt);
  static Insertable<StockBalanceRow> custom({
    Expression<String>? variantId,
    Expression<String>? warehouseId,
    Expression<int>? quantityMilli,
    Expression<int>? reservedMilli,
    Expression<int>? availableMilli,
    Expression<String>? stockLevel,
    Expression<int>? snapshotAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (variantId != null) 'variant_id': variantId,
      if (warehouseId != null) 'warehouse_id': warehouseId,
      if (quantityMilli != null) 'quantity_milli': quantityMilli,
      if (reservedMilli != null) 'reserved_milli': reservedMilli,
      if (availableMilli != null) 'available_milli': availableMilli,
      if (stockLevel != null) 'stock_level': stockLevel,
      if (snapshotAt != null) 'snapshot_at': snapshotAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalStockBalancesCompanion copyWith({
    Value<String>? variantId,
    Value<String>? warehouseId,
    Value<int?>? quantityMilli,
    Value<int?>? reservedMilli,
    Value<int?>? availableMilli,
    Value<String>? stockLevel,
    Value<int>? snapshotAt,
    Value<int>? rowid,
  }) {
    return LocalStockBalancesCompanion(
      variantId: variantId ?? this.variantId,
      warehouseId: warehouseId ?? this.warehouseId,
      quantityMilli: quantityMilli ?? this.quantityMilli,
      reservedMilli: reservedMilli ?? this.reservedMilli,
      availableMilli: availableMilli ?? this.availableMilli,
      stockLevel: stockLevel ?? this.stockLevel,
      snapshotAt: snapshotAt ?? this.snapshotAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (variantId.present) {
      map['variant_id'] = Variable<String>(variantId.value);
    }
    if (warehouseId.present) {
      map['warehouse_id'] = Variable<String>(warehouseId.value);
    }
    if (quantityMilli.present) {
      map['quantity_milli'] = Variable<int>(quantityMilli.value);
    }
    if (reservedMilli.present) {
      map['reserved_milli'] = Variable<int>(reservedMilli.value);
    }
    if (availableMilli.present) {
      map['available_milli'] = Variable<int>(availableMilli.value);
    }
    if (stockLevel.present) {
      map['stock_level'] = Variable<String>(stockLevel.value);
    }
    if (snapshotAt.present) {
      map['snapshot_at'] = Variable<int>(snapshotAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalStockBalancesCompanion(')
          ..write('variantId: $variantId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('quantityMilli: $quantityMilli, ')
          ..write('reservedMilli: $reservedMilli, ')
          ..write('availableMilli: $availableMilli, ')
          ..write('stockLevel: $stockLevel, ')
          ..write('snapshotAt: $snapshotAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalProductImagesMetaTable extends LocalProductImagesMeta
    with TableInfo<$LocalProductImagesMetaTable, ProductImageMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalProductImagesMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _variantIdMeta = const VerificationMeta(
    'variantId',
  );
  @override
  late final GeneratedColumn<String> variantId = GeneratedColumn<String>(
    'variant_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _shaMeta = const VerificationMeta('sha');
  @override
  late final GeneratedColumn<String> sha = GeneratedColumn<String>(
    'sha',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isPrimaryMeta = const VerificationMeta(
    'isPrimary',
  );
  @override
  late final GeneratedColumn<bool> isPrimary = GeneratedColumn<bool>(
    'is_primary',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_primary" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _sizesJsonMeta = const VerificationMeta(
    'sizesJson',
  );
  @override
  late final GeneratedColumn<String> sizesJson = GeneratedColumn<String>(
    'sizes_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    productId,
    variantId,
    sha,
    sortOrder,
    isPrimary,
    sizesJson,
    serverId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'product_images_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProductImageMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('variant_id')) {
      context.handle(
        _variantIdMeta,
        variantId.isAcceptableOrUnknown(data['variant_id']!, _variantIdMeta),
      );
    }
    if (data.containsKey('sha')) {
      context.handle(
        _shaMeta,
        sha.isAcceptableOrUnknown(data['sha']!, _shaMeta),
      );
    } else if (isInserting) {
      context.missing(_shaMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('is_primary')) {
      context.handle(
        _isPrimaryMeta,
        isPrimary.isAcceptableOrUnknown(data['is_primary']!, _isPrimaryMeta),
      );
    }
    if (data.containsKey('sizes_json')) {
      context.handle(
        _sizesJsonMeta,
        sizesJson.isAcceptableOrUnknown(data['sizes_json']!, _sizesJsonMeta),
      );
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sha, productId, variantId};
  @override
  ProductImageMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProductImageMetaRow(
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      variantId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variant_id'],
      ),
      sha: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      isPrimary: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_primary'],
      )!,
      sizesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sizes_json'],
      ),
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      ),
    );
  }

  @override
  $LocalProductImagesMetaTable createAlias(String alias) {
    return $LocalProductImagesMetaTable(attachedDatabase, alias);
  }
}

class ProductImageMetaRow extends DataClass
    implements Insertable<ProductImageMetaRow> {
  final String productId;
  final String? variantId;
  final String sha;
  final int sortOrder;
  final bool isPrimary;
  final String? sizesJson;

  /// Серверный uuid строки (`product_images.id`): по нему применяется `deleted[]` (08 §4.24, EQ-CSYNC-02). Схема v4.
  final String? serverId;
  const ProductImageMetaRow({
    required this.productId,
    this.variantId,
    required this.sha,
    required this.sortOrder,
    required this.isPrimary,
    this.sizesJson,
    this.serverId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['product_id'] = Variable<String>(productId);
    if (!nullToAbsent || variantId != null) {
      map['variant_id'] = Variable<String>(variantId);
    }
    map['sha'] = Variable<String>(sha);
    map['sort_order'] = Variable<int>(sortOrder);
    map['is_primary'] = Variable<bool>(isPrimary);
    if (!nullToAbsent || sizesJson != null) {
      map['sizes_json'] = Variable<String>(sizesJson);
    }
    if (!nullToAbsent || serverId != null) {
      map['server_id'] = Variable<String>(serverId);
    }
    return map;
  }

  LocalProductImagesMetaCompanion toCompanion(bool nullToAbsent) {
    return LocalProductImagesMetaCompanion(
      productId: Value(productId),
      variantId: variantId == null && nullToAbsent
          ? const Value.absent()
          : Value(variantId),
      sha: Value(sha),
      sortOrder: Value(sortOrder),
      isPrimary: Value(isPrimary),
      sizesJson: sizesJson == null && nullToAbsent
          ? const Value.absent()
          : Value(sizesJson),
      serverId: serverId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverId),
    );
  }

  factory ProductImageMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProductImageMetaRow(
      productId: serializer.fromJson<String>(json['productId']),
      variantId: serializer.fromJson<String?>(json['variantId']),
      sha: serializer.fromJson<String>(json['sha']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      isPrimary: serializer.fromJson<bool>(json['isPrimary']),
      sizesJson: serializer.fromJson<String?>(json['sizesJson']),
      serverId: serializer.fromJson<String?>(json['serverId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'productId': serializer.toJson<String>(productId),
      'variantId': serializer.toJson<String?>(variantId),
      'sha': serializer.toJson<String>(sha),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'isPrimary': serializer.toJson<bool>(isPrimary),
      'sizesJson': serializer.toJson<String?>(sizesJson),
      'serverId': serializer.toJson<String?>(serverId),
    };
  }

  ProductImageMetaRow copyWith({
    String? productId,
    Value<String?> variantId = const Value.absent(),
    String? sha,
    int? sortOrder,
    bool? isPrimary,
    Value<String?> sizesJson = const Value.absent(),
    Value<String?> serverId = const Value.absent(),
  }) => ProductImageMetaRow(
    productId: productId ?? this.productId,
    variantId: variantId.present ? variantId.value : this.variantId,
    sha: sha ?? this.sha,
    sortOrder: sortOrder ?? this.sortOrder,
    isPrimary: isPrimary ?? this.isPrimary,
    sizesJson: sizesJson.present ? sizesJson.value : this.sizesJson,
    serverId: serverId.present ? serverId.value : this.serverId,
  );
  ProductImageMetaRow copyWithCompanion(LocalProductImagesMetaCompanion data) {
    return ProductImageMetaRow(
      productId: data.productId.present ? data.productId.value : this.productId,
      variantId: data.variantId.present ? data.variantId.value : this.variantId,
      sha: data.sha.present ? data.sha.value : this.sha,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      isPrimary: data.isPrimary.present ? data.isPrimary.value : this.isPrimary,
      sizesJson: data.sizesJson.present ? data.sizesJson.value : this.sizesJson,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProductImageMetaRow(')
          ..write('productId: $productId, ')
          ..write('variantId: $variantId, ')
          ..write('sha: $sha, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('isPrimary: $isPrimary, ')
          ..write('sizesJson: $sizesJson, ')
          ..write('serverId: $serverId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    productId,
    variantId,
    sha,
    sortOrder,
    isPrimary,
    sizesJson,
    serverId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProductImageMetaRow &&
          other.productId == this.productId &&
          other.variantId == this.variantId &&
          other.sha == this.sha &&
          other.sortOrder == this.sortOrder &&
          other.isPrimary == this.isPrimary &&
          other.sizesJson == this.sizesJson &&
          other.serverId == this.serverId);
}

class LocalProductImagesMetaCompanion
    extends UpdateCompanion<ProductImageMetaRow> {
  final Value<String> productId;
  final Value<String?> variantId;
  final Value<String> sha;
  final Value<int> sortOrder;
  final Value<bool> isPrimary;
  final Value<String?> sizesJson;
  final Value<String?> serverId;
  final Value<int> rowid;
  const LocalProductImagesMetaCompanion({
    this.productId = const Value.absent(),
    this.variantId = const Value.absent(),
    this.sha = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.isPrimary = const Value.absent(),
    this.sizesJson = const Value.absent(),
    this.serverId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalProductImagesMetaCompanion.insert({
    required String productId,
    this.variantId = const Value.absent(),
    required String sha,
    this.sortOrder = const Value.absent(),
    this.isPrimary = const Value.absent(),
    this.sizesJson = const Value.absent(),
    this.serverId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : productId = Value(productId),
       sha = Value(sha);
  static Insertable<ProductImageMetaRow> custom({
    Expression<String>? productId,
    Expression<String>? variantId,
    Expression<String>? sha,
    Expression<int>? sortOrder,
    Expression<bool>? isPrimary,
    Expression<String>? sizesJson,
    Expression<String>? serverId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (productId != null) 'product_id': productId,
      if (variantId != null) 'variant_id': variantId,
      if (sha != null) 'sha': sha,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (isPrimary != null) 'is_primary': isPrimary,
      if (sizesJson != null) 'sizes_json': sizesJson,
      if (serverId != null) 'server_id': serverId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalProductImagesMetaCompanion copyWith({
    Value<String>? productId,
    Value<String?>? variantId,
    Value<String>? sha,
    Value<int>? sortOrder,
    Value<bool>? isPrimary,
    Value<String?>? sizesJson,
    Value<String?>? serverId,
    Value<int>? rowid,
  }) {
    return LocalProductImagesMetaCompanion(
      productId: productId ?? this.productId,
      variantId: variantId ?? this.variantId,
      sha: sha ?? this.sha,
      sortOrder: sortOrder ?? this.sortOrder,
      isPrimary: isPrimary ?? this.isPrimary,
      sizesJson: sizesJson ?? this.sizesJson,
      serverId: serverId ?? this.serverId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (variantId.present) {
      map['variant_id'] = Variable<String>(variantId.value);
    }
    if (sha.present) {
      map['sha'] = Variable<String>(sha.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (isPrimary.present) {
      map['is_primary'] = Variable<bool>(isPrimary.value);
    }
    if (sizesJson.present) {
      map['sizes_json'] = Variable<String>(sizesJson.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalProductImagesMetaCompanion(')
          ..write('productId: $productId, ')
          ..write('variantId: $variantId, ')
          ..write('sha: $sha, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('isPrimary: $isPrimary, ')
          ..write('sizesJson: $sizesJson, ')
          ..write('serverId: $serverId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalFavoritesProductsTable extends LocalFavoritesProducts
    with TableInfo<$LocalFavoritesProductsTable, FavoriteProductRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalFavoritesProductsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pendingOpMeta = const VerificationMeta(
    'pendingOp',
  );
  @override
  late final GeneratedColumn<String> pendingOp = GeneratedColumn<String>(
    'pending_op',
    aliasedName,
    true,
    check: () => pendingOp.isIn(pendingOpValues),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [productId, createdAt, pendingOp];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'favorites_products';
  @override
  VerificationContext validateIntegrity(
    Insertable<FavoriteProductRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('pending_op')) {
      context.handle(
        _pendingOpMeta,
        pendingOp.isAcceptableOrUnknown(data['pending_op']!, _pendingOpMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {productId};
  @override
  FavoriteProductRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FavoriteProductRow(
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      pendingOp: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pending_op'],
      ),
    );
  }

  @override
  $LocalFavoritesProductsTable createAlias(String alias) {
    return $LocalFavoritesProductsTable(attachedDatabase, alias);
  }
}

class FavoriteProductRow extends DataClass
    implements Insertable<FavoriteProductRow> {
  final String productId;
  final int createdAt;
  final String? pendingOp;
  const FavoriteProductRow({
    required this.productId,
    required this.createdAt,
    this.pendingOp,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['product_id'] = Variable<String>(productId);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || pendingOp != null) {
      map['pending_op'] = Variable<String>(pendingOp);
    }
    return map;
  }

  LocalFavoritesProductsCompanion toCompanion(bool nullToAbsent) {
    return LocalFavoritesProductsCompanion(
      productId: Value(productId),
      createdAt: Value(createdAt),
      pendingOp: pendingOp == null && nullToAbsent
          ? const Value.absent()
          : Value(pendingOp),
    );
  }

  factory FavoriteProductRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FavoriteProductRow(
      productId: serializer.fromJson<String>(json['productId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      pendingOp: serializer.fromJson<String?>(json['pendingOp']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'productId': serializer.toJson<String>(productId),
      'createdAt': serializer.toJson<int>(createdAt),
      'pendingOp': serializer.toJson<String?>(pendingOp),
    };
  }

  FavoriteProductRow copyWith({
    String? productId,
    int? createdAt,
    Value<String?> pendingOp = const Value.absent(),
  }) => FavoriteProductRow(
    productId: productId ?? this.productId,
    createdAt: createdAt ?? this.createdAt,
    pendingOp: pendingOp.present ? pendingOp.value : this.pendingOp,
  );
  FavoriteProductRow copyWithCompanion(LocalFavoritesProductsCompanion data) {
    return FavoriteProductRow(
      productId: data.productId.present ? data.productId.value : this.productId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      pendingOp: data.pendingOp.present ? data.pendingOp.value : this.pendingOp,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FavoriteProductRow(')
          ..write('productId: $productId, ')
          ..write('createdAt: $createdAt, ')
          ..write('pendingOp: $pendingOp')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(productId, createdAt, pendingOp);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FavoriteProductRow &&
          other.productId == this.productId &&
          other.createdAt == this.createdAt &&
          other.pendingOp == this.pendingOp);
}

class LocalFavoritesProductsCompanion
    extends UpdateCompanion<FavoriteProductRow> {
  final Value<String> productId;
  final Value<int> createdAt;
  final Value<String?> pendingOp;
  final Value<int> rowid;
  const LocalFavoritesProductsCompanion({
    this.productId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.pendingOp = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalFavoritesProductsCompanion.insert({
    required String productId,
    required int createdAt,
    this.pendingOp = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : productId = Value(productId),
       createdAt = Value(createdAt);
  static Insertable<FavoriteProductRow> custom({
    Expression<String>? productId,
    Expression<int>? createdAt,
    Expression<String>? pendingOp,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (productId != null) 'product_id': productId,
      if (createdAt != null) 'created_at': createdAt,
      if (pendingOp != null) 'pending_op': pendingOp,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalFavoritesProductsCompanion copyWith({
    Value<String>? productId,
    Value<int>? createdAt,
    Value<String?>? pendingOp,
    Value<int>? rowid,
  }) {
    return LocalFavoritesProductsCompanion(
      productId: productId ?? this.productId,
      createdAt: createdAt ?? this.createdAt,
      pendingOp: pendingOp ?? this.pendingOp,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (pendingOp.present) {
      map['pending_op'] = Variable<String>(pendingOp.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalFavoritesProductsCompanion(')
          ..write('productId: $productId, ')
          ..write('createdAt: $createdAt, ')
          ..write('pendingOp: $pendingOp, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalFavoritesCustomersTable extends LocalFavoritesCustomers
    with TableInfo<$LocalFavoritesCustomersTable, FavoriteCustomerRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalFavoritesCustomersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _customerIdMeta = const VerificationMeta(
    'customerId',
  );
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
    'customer_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pendingOpMeta = const VerificationMeta(
    'pendingOp',
  );
  @override
  late final GeneratedColumn<String> pendingOp = GeneratedColumn<String>(
    'pending_op',
    aliasedName,
    true,
    check: () => pendingOp.isIn(pendingOpValues),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [customerId, createdAt, pendingOp];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'favorites_customers';
  @override
  VerificationContext validateIntegrity(
    Insertable<FavoriteCustomerRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('customer_id')) {
      context.handle(
        _customerIdMeta,
        customerId.isAcceptableOrUnknown(data['customer_id']!, _customerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_customerIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('pending_op')) {
      context.handle(
        _pendingOpMeta,
        pendingOp.isAcceptableOrUnknown(data['pending_op']!, _pendingOpMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {customerId};
  @override
  FavoriteCustomerRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FavoriteCustomerRow(
      customerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}customer_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      pendingOp: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pending_op'],
      ),
    );
  }

  @override
  $LocalFavoritesCustomersTable createAlias(String alias) {
    return $LocalFavoritesCustomersTable(attachedDatabase, alias);
  }
}

class FavoriteCustomerRow extends DataClass
    implements Insertable<FavoriteCustomerRow> {
  final String customerId;
  final int createdAt;
  final String? pendingOp;
  const FavoriteCustomerRow({
    required this.customerId,
    required this.createdAt,
    this.pendingOp,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['customer_id'] = Variable<String>(customerId);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || pendingOp != null) {
      map['pending_op'] = Variable<String>(pendingOp);
    }
    return map;
  }

  LocalFavoritesCustomersCompanion toCompanion(bool nullToAbsent) {
    return LocalFavoritesCustomersCompanion(
      customerId: Value(customerId),
      createdAt: Value(createdAt),
      pendingOp: pendingOp == null && nullToAbsent
          ? const Value.absent()
          : Value(pendingOp),
    );
  }

  factory FavoriteCustomerRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FavoriteCustomerRow(
      customerId: serializer.fromJson<String>(json['customerId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      pendingOp: serializer.fromJson<String?>(json['pendingOp']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'customerId': serializer.toJson<String>(customerId),
      'createdAt': serializer.toJson<int>(createdAt),
      'pendingOp': serializer.toJson<String?>(pendingOp),
    };
  }

  FavoriteCustomerRow copyWith({
    String? customerId,
    int? createdAt,
    Value<String?> pendingOp = const Value.absent(),
  }) => FavoriteCustomerRow(
    customerId: customerId ?? this.customerId,
    createdAt: createdAt ?? this.createdAt,
    pendingOp: pendingOp.present ? pendingOp.value : this.pendingOp,
  );
  FavoriteCustomerRow copyWithCompanion(LocalFavoritesCustomersCompanion data) {
    return FavoriteCustomerRow(
      customerId: data.customerId.present
          ? data.customerId.value
          : this.customerId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      pendingOp: data.pendingOp.present ? data.pendingOp.value : this.pendingOp,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FavoriteCustomerRow(')
          ..write('customerId: $customerId, ')
          ..write('createdAt: $createdAt, ')
          ..write('pendingOp: $pendingOp')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(customerId, createdAt, pendingOp);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FavoriteCustomerRow &&
          other.customerId == this.customerId &&
          other.createdAt == this.createdAt &&
          other.pendingOp == this.pendingOp);
}

class LocalFavoritesCustomersCompanion
    extends UpdateCompanion<FavoriteCustomerRow> {
  final Value<String> customerId;
  final Value<int> createdAt;
  final Value<String?> pendingOp;
  final Value<int> rowid;
  const LocalFavoritesCustomersCompanion({
    this.customerId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.pendingOp = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalFavoritesCustomersCompanion.insert({
    required String customerId,
    required int createdAt,
    this.pendingOp = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : customerId = Value(customerId),
       createdAt = Value(createdAt);
  static Insertable<FavoriteCustomerRow> custom({
    Expression<String>? customerId,
    Expression<int>? createdAt,
    Expression<String>? pendingOp,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (customerId != null) 'customer_id': customerId,
      if (createdAt != null) 'created_at': createdAt,
      if (pendingOp != null) 'pending_op': pendingOp,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalFavoritesCustomersCompanion copyWith({
    Value<String>? customerId,
    Value<int>? createdAt,
    Value<String?>? pendingOp,
    Value<int>? rowid,
  }) {
    return LocalFavoritesCustomersCompanion(
      customerId: customerId ?? this.customerId,
      createdAt: createdAt ?? this.createdAt,
      pendingOp: pendingOp ?? this.pendingOp,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (pendingOp.present) {
      map['pending_op'] = Variable<String>(pendingOp.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalFavoritesCustomersCompanion(')
          ..write('customerId: $customerId, ')
          ..write('createdAt: $createdAt, ')
          ..write('pendingOp: $pendingOp, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CartDraftTable extends CartDraft
    with TableInfo<$CartDraftTable, CartDraftRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CartDraftTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localIdMeta = const VerificationMeta(
    'localId',
  );
  @override
  late final GeneratedColumn<String> localId = GeneratedColumn<String>(
    'local_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    check: () =>
        status.isIn(const ['active', 'parked', 'converted', 'cleared']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _customerIdMeta = const VerificationMeta(
    'customerId',
  );
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
    'customer_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _warehouseIdMeta = const VerificationMeta(
    'warehouseId',
  );
  @override
  late final GeneratedColumn<String> warehouseId = GeneratedColumn<String>(
    'warehouse_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _priceListIdMeta = const VerificationMeta(
    'priceListId',
  );
  @override
  late final GeneratedColumn<String> priceListId = GeneratedColumn<String>(
    'price_list_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _discountPercentHundredthsMeta =
      const VerificationMeta('discountPercentHundredths');
  @override
  late final GeneratedColumn<int> discountPercentHundredths =
      GeneratedColumn<int>(
        'discount_percent_hundredths',
        aliasedName,
        false,
        check: () =>
            ComparableExpr(discountPercentHundredths).isBetweenValues(0, 10000),
        type: DriftSqlType.int,
        requiredDuringInsert: false,
        defaultValue: const Constant(0),
      );
  static const VerificationMeta _baseRowVersionMeta = const VerificationMeta(
    'baseRowVersion',
  );
  @override
  late final GeneratedColumn<int> baseRowVersion = GeneratedColumn<int>(
    'base_row_version',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _ownerUserIdMeta = const VerificationMeta(
    'ownerUserId',
  );
  @override
  late final GeneratedColumn<String> ownerUserId = GeneratedColumn<String>(
    'owner_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverSyncedAtMeta = const VerificationMeta(
    'serverSyncedAt',
  );
  @override
  late final GeneratedColumn<int> serverSyncedAt = GeneratedColumn<int>(
    'server_synced_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    localId,
    serverId,
    status,
    name,
    customerId,
    warehouseId,
    priceListId,
    discountPercentHundredths,
    baseRowVersion,
    dirty,
    ownerUserId,
    updatedAt,
    serverSyncedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cart_draft';
  @override
  VerificationContext validateIntegrity(
    Insertable<CartDraftRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_id')) {
      context.handle(
        _localIdMeta,
        localId.isAcceptableOrUnknown(data['local_id']!, _localIdMeta),
      );
    } else if (isInserting) {
      context.missing(_localIdMeta);
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('customer_id')) {
      context.handle(
        _customerIdMeta,
        customerId.isAcceptableOrUnknown(data['customer_id']!, _customerIdMeta),
      );
    }
    if (data.containsKey('warehouse_id')) {
      context.handle(
        _warehouseIdMeta,
        warehouseId.isAcceptableOrUnknown(
          data['warehouse_id']!,
          _warehouseIdMeta,
        ),
      );
    }
    if (data.containsKey('price_list_id')) {
      context.handle(
        _priceListIdMeta,
        priceListId.isAcceptableOrUnknown(
          data['price_list_id']!,
          _priceListIdMeta,
        ),
      );
    }
    if (data.containsKey('discount_percent_hundredths')) {
      context.handle(
        _discountPercentHundredthsMeta,
        discountPercentHundredths.isAcceptableOrUnknown(
          data['discount_percent_hundredths']!,
          _discountPercentHundredthsMeta,
        ),
      );
    }
    if (data.containsKey('base_row_version')) {
      context.handle(
        _baseRowVersionMeta,
        baseRowVersion.isAcceptableOrUnknown(
          data['base_row_version']!,
          _baseRowVersionMeta,
        ),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('owner_user_id')) {
      context.handle(
        _ownerUserIdMeta,
        ownerUserId.isAcceptableOrUnknown(
          data['owner_user_id']!,
          _ownerUserIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_ownerUserIdMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('server_synced_at')) {
      context.handle(
        _serverSyncedAtMeta,
        serverSyncedAt.isAcceptableOrUnknown(
          data['server_synced_at']!,
          _serverSyncedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localId};
  @override
  CartDraftRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CartDraftRow(
      localId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      ),
      customerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}customer_id'],
      ),
      warehouseId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}warehouse_id'],
      ),
      priceListId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}price_list_id'],
      ),
      discountPercentHundredths: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}discount_percent_hundredths'],
      )!,
      baseRowVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_row_version'],
      ),
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      ownerUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_user_id'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      serverSyncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_synced_at'],
      ),
    );
  }

  @override
  $CartDraftTable createAlias(String alias) {
    return $CartDraftTable(attachedDatabase, alias);
  }
}

class CartDraftRow extends DataClass implements Insertable<CartDraftRow> {
  final String localId;
  final String? serverId;
  final String status;
  final String? name;
  final String? customerId;
  final String? warehouseId;
  final String? priceListId;
  final int discountPercentHundredths;
  final int? baseRowVersion;
  final bool dirty;
  final String ownerUserId;
  final int updatedAt;

  /// Момент последнего успешного ответа сервера по корзине (unix-ms UTC) — «Данные от {time}» (02 SCR-20,
  /// `cart_banner_stale`) после перезапуска без сети. Схема v5 (этап F, FQ-FND).
  final int? serverSyncedAt;
  const CartDraftRow({
    required this.localId,
    this.serverId,
    required this.status,
    this.name,
    this.customerId,
    this.warehouseId,
    this.priceListId,
    required this.discountPercentHundredths,
    this.baseRowVersion,
    required this.dirty,
    required this.ownerUserId,
    required this.updatedAt,
    this.serverSyncedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['local_id'] = Variable<String>(localId);
    if (!nullToAbsent || serverId != null) {
      map['server_id'] = Variable<String>(serverId);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || name != null) {
      map['name'] = Variable<String>(name);
    }
    if (!nullToAbsent || customerId != null) {
      map['customer_id'] = Variable<String>(customerId);
    }
    if (!nullToAbsent || warehouseId != null) {
      map['warehouse_id'] = Variable<String>(warehouseId);
    }
    if (!nullToAbsent || priceListId != null) {
      map['price_list_id'] = Variable<String>(priceListId);
    }
    map['discount_percent_hundredths'] = Variable<int>(
      discountPercentHundredths,
    );
    if (!nullToAbsent || baseRowVersion != null) {
      map['base_row_version'] = Variable<int>(baseRowVersion);
    }
    map['dirty'] = Variable<bool>(dirty);
    map['owner_user_id'] = Variable<String>(ownerUserId);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || serverSyncedAt != null) {
      map['server_synced_at'] = Variable<int>(serverSyncedAt);
    }
    return map;
  }

  CartDraftCompanion toCompanion(bool nullToAbsent) {
    return CartDraftCompanion(
      localId: Value(localId),
      serverId: serverId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverId),
      status: Value(status),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
      customerId: customerId == null && nullToAbsent
          ? const Value.absent()
          : Value(customerId),
      warehouseId: warehouseId == null && nullToAbsent
          ? const Value.absent()
          : Value(warehouseId),
      priceListId: priceListId == null && nullToAbsent
          ? const Value.absent()
          : Value(priceListId),
      discountPercentHundredths: Value(discountPercentHundredths),
      baseRowVersion: baseRowVersion == null && nullToAbsent
          ? const Value.absent()
          : Value(baseRowVersion),
      dirty: Value(dirty),
      ownerUserId: Value(ownerUserId),
      updatedAt: Value(updatedAt),
      serverSyncedAt: serverSyncedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(serverSyncedAt),
    );
  }

  factory CartDraftRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CartDraftRow(
      localId: serializer.fromJson<String>(json['localId']),
      serverId: serializer.fromJson<String?>(json['serverId']),
      status: serializer.fromJson<String>(json['status']),
      name: serializer.fromJson<String?>(json['name']),
      customerId: serializer.fromJson<String?>(json['customerId']),
      warehouseId: serializer.fromJson<String?>(json['warehouseId']),
      priceListId: serializer.fromJson<String?>(json['priceListId']),
      discountPercentHundredths: serializer.fromJson<int>(
        json['discountPercentHundredths'],
      ),
      baseRowVersion: serializer.fromJson<int?>(json['baseRowVersion']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      ownerUserId: serializer.fromJson<String>(json['ownerUserId']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      serverSyncedAt: serializer.fromJson<int?>(json['serverSyncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'localId': serializer.toJson<String>(localId),
      'serverId': serializer.toJson<String?>(serverId),
      'status': serializer.toJson<String>(status),
      'name': serializer.toJson<String?>(name),
      'customerId': serializer.toJson<String?>(customerId),
      'warehouseId': serializer.toJson<String?>(warehouseId),
      'priceListId': serializer.toJson<String?>(priceListId),
      'discountPercentHundredths': serializer.toJson<int>(
        discountPercentHundredths,
      ),
      'baseRowVersion': serializer.toJson<int?>(baseRowVersion),
      'dirty': serializer.toJson<bool>(dirty),
      'ownerUserId': serializer.toJson<String>(ownerUserId),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'serverSyncedAt': serializer.toJson<int?>(serverSyncedAt),
    };
  }

  CartDraftRow copyWith({
    String? localId,
    Value<String?> serverId = const Value.absent(),
    String? status,
    Value<String?> name = const Value.absent(),
    Value<String?> customerId = const Value.absent(),
    Value<String?> warehouseId = const Value.absent(),
    Value<String?> priceListId = const Value.absent(),
    int? discountPercentHundredths,
    Value<int?> baseRowVersion = const Value.absent(),
    bool? dirty,
    String? ownerUserId,
    int? updatedAt,
    Value<int?> serverSyncedAt = const Value.absent(),
  }) => CartDraftRow(
    localId: localId ?? this.localId,
    serverId: serverId.present ? serverId.value : this.serverId,
    status: status ?? this.status,
    name: name.present ? name.value : this.name,
    customerId: customerId.present ? customerId.value : this.customerId,
    warehouseId: warehouseId.present ? warehouseId.value : this.warehouseId,
    priceListId: priceListId.present ? priceListId.value : this.priceListId,
    discountPercentHundredths:
        discountPercentHundredths ?? this.discountPercentHundredths,
    baseRowVersion: baseRowVersion.present
        ? baseRowVersion.value
        : this.baseRowVersion,
    dirty: dirty ?? this.dirty,
    ownerUserId: ownerUserId ?? this.ownerUserId,
    updatedAt: updatedAt ?? this.updatedAt,
    serverSyncedAt: serverSyncedAt.present
        ? serverSyncedAt.value
        : this.serverSyncedAt,
  );
  CartDraftRow copyWithCompanion(CartDraftCompanion data) {
    return CartDraftRow(
      localId: data.localId.present ? data.localId.value : this.localId,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      status: data.status.present ? data.status.value : this.status,
      name: data.name.present ? data.name.value : this.name,
      customerId: data.customerId.present
          ? data.customerId.value
          : this.customerId,
      warehouseId: data.warehouseId.present
          ? data.warehouseId.value
          : this.warehouseId,
      priceListId: data.priceListId.present
          ? data.priceListId.value
          : this.priceListId,
      discountPercentHundredths: data.discountPercentHundredths.present
          ? data.discountPercentHundredths.value
          : this.discountPercentHundredths,
      baseRowVersion: data.baseRowVersion.present
          ? data.baseRowVersion.value
          : this.baseRowVersion,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      ownerUserId: data.ownerUserId.present
          ? data.ownerUserId.value
          : this.ownerUserId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      serverSyncedAt: data.serverSyncedAt.present
          ? data.serverSyncedAt.value
          : this.serverSyncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CartDraftRow(')
          ..write('localId: $localId, ')
          ..write('serverId: $serverId, ')
          ..write('status: $status, ')
          ..write('name: $name, ')
          ..write('customerId: $customerId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('priceListId: $priceListId, ')
          ..write('discountPercentHundredths: $discountPercentHundredths, ')
          ..write('baseRowVersion: $baseRowVersion, ')
          ..write('dirty: $dirty, ')
          ..write('ownerUserId: $ownerUserId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('serverSyncedAt: $serverSyncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    localId,
    serverId,
    status,
    name,
    customerId,
    warehouseId,
    priceListId,
    discountPercentHundredths,
    baseRowVersion,
    dirty,
    ownerUserId,
    updatedAt,
    serverSyncedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CartDraftRow &&
          other.localId == this.localId &&
          other.serverId == this.serverId &&
          other.status == this.status &&
          other.name == this.name &&
          other.customerId == this.customerId &&
          other.warehouseId == this.warehouseId &&
          other.priceListId == this.priceListId &&
          other.discountPercentHundredths == this.discountPercentHundredths &&
          other.baseRowVersion == this.baseRowVersion &&
          other.dirty == this.dirty &&
          other.ownerUserId == this.ownerUserId &&
          other.updatedAt == this.updatedAt &&
          other.serverSyncedAt == this.serverSyncedAt);
}

class CartDraftCompanion extends UpdateCompanion<CartDraftRow> {
  final Value<String> localId;
  final Value<String?> serverId;
  final Value<String> status;
  final Value<String?> name;
  final Value<String?> customerId;
  final Value<String?> warehouseId;
  final Value<String?> priceListId;
  final Value<int> discountPercentHundredths;
  final Value<int?> baseRowVersion;
  final Value<bool> dirty;
  final Value<String> ownerUserId;
  final Value<int> updatedAt;
  final Value<int?> serverSyncedAt;
  final Value<int> rowid;
  const CartDraftCompanion({
    this.localId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.status = const Value.absent(),
    this.name = const Value.absent(),
    this.customerId = const Value.absent(),
    this.warehouseId = const Value.absent(),
    this.priceListId = const Value.absent(),
    this.discountPercentHundredths = const Value.absent(),
    this.baseRowVersion = const Value.absent(),
    this.dirty = const Value.absent(),
    this.ownerUserId = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.serverSyncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CartDraftCompanion.insert({
    required String localId,
    this.serverId = const Value.absent(),
    required String status,
    this.name = const Value.absent(),
    this.customerId = const Value.absent(),
    this.warehouseId = const Value.absent(),
    this.priceListId = const Value.absent(),
    this.discountPercentHundredths = const Value.absent(),
    this.baseRowVersion = const Value.absent(),
    this.dirty = const Value.absent(),
    required String ownerUserId,
    required int updatedAt,
    this.serverSyncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : localId = Value(localId),
       status = Value(status),
       ownerUserId = Value(ownerUserId),
       updatedAt = Value(updatedAt);
  static Insertable<CartDraftRow> custom({
    Expression<String>? localId,
    Expression<String>? serverId,
    Expression<String>? status,
    Expression<String>? name,
    Expression<String>? customerId,
    Expression<String>? warehouseId,
    Expression<String>? priceListId,
    Expression<int>? discountPercentHundredths,
    Expression<int>? baseRowVersion,
    Expression<bool>? dirty,
    Expression<String>? ownerUserId,
    Expression<int>? updatedAt,
    Expression<int>? serverSyncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (localId != null) 'local_id': localId,
      if (serverId != null) 'server_id': serverId,
      if (status != null) 'status': status,
      if (name != null) 'name': name,
      if (customerId != null) 'customer_id': customerId,
      if (warehouseId != null) 'warehouse_id': warehouseId,
      if (priceListId != null) 'price_list_id': priceListId,
      if (discountPercentHundredths != null)
        'discount_percent_hundredths': discountPercentHundredths,
      if (baseRowVersion != null) 'base_row_version': baseRowVersion,
      if (dirty != null) 'dirty': dirty,
      if (ownerUserId != null) 'owner_user_id': ownerUserId,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (serverSyncedAt != null) 'server_synced_at': serverSyncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CartDraftCompanion copyWith({
    Value<String>? localId,
    Value<String?>? serverId,
    Value<String>? status,
    Value<String?>? name,
    Value<String?>? customerId,
    Value<String?>? warehouseId,
    Value<String?>? priceListId,
    Value<int>? discountPercentHundredths,
    Value<int?>? baseRowVersion,
    Value<bool>? dirty,
    Value<String>? ownerUserId,
    Value<int>? updatedAt,
    Value<int?>? serverSyncedAt,
    Value<int>? rowid,
  }) {
    return CartDraftCompanion(
      localId: localId ?? this.localId,
      serverId: serverId ?? this.serverId,
      status: status ?? this.status,
      name: name ?? this.name,
      customerId: customerId ?? this.customerId,
      warehouseId: warehouseId ?? this.warehouseId,
      priceListId: priceListId ?? this.priceListId,
      discountPercentHundredths:
          discountPercentHundredths ?? this.discountPercentHundredths,
      baseRowVersion: baseRowVersion ?? this.baseRowVersion,
      dirty: dirty ?? this.dirty,
      ownerUserId: ownerUserId ?? this.ownerUserId,
      updatedAt: updatedAt ?? this.updatedAt,
      serverSyncedAt: serverSyncedAt ?? this.serverSyncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localId.present) {
      map['local_id'] = Variable<String>(localId.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (warehouseId.present) {
      map['warehouse_id'] = Variable<String>(warehouseId.value);
    }
    if (priceListId.present) {
      map['price_list_id'] = Variable<String>(priceListId.value);
    }
    if (discountPercentHundredths.present) {
      map['discount_percent_hundredths'] = Variable<int>(
        discountPercentHundredths.value,
      );
    }
    if (baseRowVersion.present) {
      map['base_row_version'] = Variable<int>(baseRowVersion.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (ownerUserId.present) {
      map['owner_user_id'] = Variable<String>(ownerUserId.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (serverSyncedAt.present) {
      map['server_synced_at'] = Variable<int>(serverSyncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CartDraftCompanion(')
          ..write('localId: $localId, ')
          ..write('serverId: $serverId, ')
          ..write('status: $status, ')
          ..write('name: $name, ')
          ..write('customerId: $customerId, ')
          ..write('warehouseId: $warehouseId, ')
          ..write('priceListId: $priceListId, ')
          ..write('discountPercentHundredths: $discountPercentHundredths, ')
          ..write('baseRowVersion: $baseRowVersion, ')
          ..write('dirty: $dirty, ')
          ..write('ownerUserId: $ownerUserId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('serverSyncedAt: $serverSyncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CartItemsDraftTable extends CartItemsDraft
    with TableInfo<$CartItemsDraftTable, CartItemDraftRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CartItemsDraftTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localItemIdMeta = const VerificationMeta(
    'localItemId',
  );
  @override
  late final GeneratedColumn<String> localItemId = GeneratedColumn<String>(
    'local_item_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localCartIdMeta = const VerificationMeta(
    'localCartId',
  );
  @override
  late final GeneratedColumn<String> localCartId = GeneratedColumn<String>(
    'local_cart_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverItemIdMeta = const VerificationMeta(
    'serverItemId',
  );
  @override
  late final GeneratedColumn<String> serverItemId = GeneratedColumn<String>(
    'server_item_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _variantIdMeta = const VerificationMeta(
    'variantId',
  );
  @override
  late final GeneratedColumn<String> variantId = GeneratedColumn<String>(
    'variant_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _packagingIdMeta = const VerificationMeta(
    'packagingId',
  );
  @override
  late final GeneratedColumn<String> packagingId = GeneratedColumn<String>(
    'packaging_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _quantityMilliMeta = const VerificationMeta(
    'quantityMilli',
  );
  @override
  late final GeneratedColumn<int> quantityMilli = GeneratedColumn<int>(
    'quantity_milli',
    aliasedName,
    false,
    check: () => ComparableExpr(quantityMilli).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _unitIdMeta = const VerificationMeta('unitId');
  @override
  late final GeneratedColumn<String> unitId = GeneratedColumn<String>(
    'unit_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _priceSnapshotTyiynMeta =
      const VerificationMeta('priceSnapshotTyiyn');
  @override
  late final GeneratedColumn<int> priceSnapshotTyiyn = GeneratedColumn<int>(
    'price_snapshot_tyiyn',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stockSnapshotMilliMeta =
      const VerificationMeta('stockSnapshotMilli');
  @override
  late final GeneratedColumn<int> stockSnapshotMilli = GeneratedColumn<int>(
    'stock_snapshot_milli',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _priceChangedMeta = const VerificationMeta(
    'priceChanged',
  );
  @override
  late final GeneratedColumn<bool> priceChanged = GeneratedColumn<bool>(
    'price_changed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("price_changed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _stockInsufficientMeta = const VerificationMeta(
    'stockInsufficient',
  );
  @override
  late final GeneratedColumn<bool> stockInsufficient = GeneratedColumn<bool>(
    'stock_insufficient',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("stock_insufficient" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _lineNoMeta = const VerificationMeta('lineNo');
  @override
  late final GeneratedColumn<int> lineNo = GeneratedColumn<int>(
    'line_no',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ownerUserIdMeta = const VerificationMeta(
    'ownerUserId',
  );
  @override
  late final GeneratedColumn<String> ownerUserId = GeneratedColumn<String>(
    'owner_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _syncStateMeta = const VerificationMeta(
    'syncState',
  );
  @override
  late final GeneratedColumn<String> syncState = GeneratedColumn<String>(
    'sync_state',
    aliasedName,
    false,
    check: () => syncState.isIn(const ['synced', 'pending', 'dead']),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    localItemId,
    localCartId,
    serverItemId,
    variantId,
    packagingId,
    quantityMilli,
    unitId,
    priceSnapshotTyiyn,
    stockSnapshotMilli,
    priceChanged,
    stockInsufficient,
    lineNo,
    ownerUserId,
    syncState,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cart_items_draft';
  @override
  VerificationContext validateIntegrity(
    Insertable<CartItemDraftRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_item_id')) {
      context.handle(
        _localItemIdMeta,
        localItemId.isAcceptableOrUnknown(
          data['local_item_id']!,
          _localItemIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localItemIdMeta);
    }
    if (data.containsKey('local_cart_id')) {
      context.handle(
        _localCartIdMeta,
        localCartId.isAcceptableOrUnknown(
          data['local_cart_id']!,
          _localCartIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localCartIdMeta);
    }
    if (data.containsKey('server_item_id')) {
      context.handle(
        _serverItemIdMeta,
        serverItemId.isAcceptableOrUnknown(
          data['server_item_id']!,
          _serverItemIdMeta,
        ),
      );
    }
    if (data.containsKey('variant_id')) {
      context.handle(
        _variantIdMeta,
        variantId.isAcceptableOrUnknown(data['variant_id']!, _variantIdMeta),
      );
    } else if (isInserting) {
      context.missing(_variantIdMeta);
    }
    if (data.containsKey('packaging_id')) {
      context.handle(
        _packagingIdMeta,
        packagingId.isAcceptableOrUnknown(
          data['packaging_id']!,
          _packagingIdMeta,
        ),
      );
    }
    if (data.containsKey('quantity_milli')) {
      context.handle(
        _quantityMilliMeta,
        quantityMilli.isAcceptableOrUnknown(
          data['quantity_milli']!,
          _quantityMilliMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_quantityMilliMeta);
    }
    if (data.containsKey('unit_id')) {
      context.handle(
        _unitIdMeta,
        unitId.isAcceptableOrUnknown(data['unit_id']!, _unitIdMeta),
      );
    }
    if (data.containsKey('price_snapshot_tyiyn')) {
      context.handle(
        _priceSnapshotTyiynMeta,
        priceSnapshotTyiyn.isAcceptableOrUnknown(
          data['price_snapshot_tyiyn']!,
          _priceSnapshotTyiynMeta,
        ),
      );
    }
    if (data.containsKey('stock_snapshot_milli')) {
      context.handle(
        _stockSnapshotMilliMeta,
        stockSnapshotMilli.isAcceptableOrUnknown(
          data['stock_snapshot_milli']!,
          _stockSnapshotMilliMeta,
        ),
      );
    }
    if (data.containsKey('price_changed')) {
      context.handle(
        _priceChangedMeta,
        priceChanged.isAcceptableOrUnknown(
          data['price_changed']!,
          _priceChangedMeta,
        ),
      );
    }
    if (data.containsKey('stock_insufficient')) {
      context.handle(
        _stockInsufficientMeta,
        stockInsufficient.isAcceptableOrUnknown(
          data['stock_insufficient']!,
          _stockInsufficientMeta,
        ),
      );
    }
    if (data.containsKey('line_no')) {
      context.handle(
        _lineNoMeta,
        lineNo.isAcceptableOrUnknown(data['line_no']!, _lineNoMeta),
      );
    } else if (isInserting) {
      context.missing(_lineNoMeta);
    }
    if (data.containsKey('owner_user_id')) {
      context.handle(
        _ownerUserIdMeta,
        ownerUserId.isAcceptableOrUnknown(
          data['owner_user_id']!,
          _ownerUserIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_ownerUserIdMeta);
    }
    if (data.containsKey('sync_state')) {
      context.handle(
        _syncStateMeta,
        syncState.isAcceptableOrUnknown(data['sync_state']!, _syncStateMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localItemId};
  @override
  CartItemDraftRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CartItemDraftRow(
      localItemId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_item_id'],
      )!,
      localCartId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_cart_id'],
      )!,
      serverItemId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_item_id'],
      ),
      variantId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variant_id'],
      )!,
      packagingId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}packaging_id'],
      ),
      quantityMilli: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}quantity_milli'],
      )!,
      unitId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}unit_id'],
      ),
      priceSnapshotTyiyn: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}price_snapshot_tyiyn'],
      ),
      stockSnapshotMilli: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}stock_snapshot_milli'],
      ),
      priceChanged: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}price_changed'],
      )!,
      stockInsufficient: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}stock_insufficient'],
      )!,
      lineNo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}line_no'],
      )!,
      ownerUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_user_id'],
      )!,
      syncState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sync_state'],
      )!,
    );
  }

  @override
  $CartItemsDraftTable createAlias(String alias) {
    return $CartItemsDraftTable(attachedDatabase, alias);
  }
}

class CartItemDraftRow extends DataClass
    implements Insertable<CartItemDraftRow> {
  final String localItemId;
  final String localCartId;
  final String? serverItemId;
  final String variantId;
  final String? packagingId;
  final int quantityMilli;

  /// Единица количества строки (`Quantity.unitId`: упаковки — её единица, иначе базовая) — нужна телу
  /// `PUT /cart/items/{variantId}` записи `cart.sync` (`set_item.unitId`, 07 §11.2). Схема v5 (этап F, FQ-FND).
  final String? unitId;
  final int? priceSnapshotTyiyn;
  final int? stockSnapshotMilli;
  final bool priceChanged;
  final bool stockInsufficient;
  final int lineNo;
  final String ownerUserId;
  final String syncState;
  const CartItemDraftRow({
    required this.localItemId,
    required this.localCartId,
    this.serverItemId,
    required this.variantId,
    this.packagingId,
    required this.quantityMilli,
    this.unitId,
    this.priceSnapshotTyiyn,
    this.stockSnapshotMilli,
    required this.priceChanged,
    required this.stockInsufficient,
    required this.lineNo,
    required this.ownerUserId,
    required this.syncState,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['local_item_id'] = Variable<String>(localItemId);
    map['local_cart_id'] = Variable<String>(localCartId);
    if (!nullToAbsent || serverItemId != null) {
      map['server_item_id'] = Variable<String>(serverItemId);
    }
    map['variant_id'] = Variable<String>(variantId);
    if (!nullToAbsent || packagingId != null) {
      map['packaging_id'] = Variable<String>(packagingId);
    }
    map['quantity_milli'] = Variable<int>(quantityMilli);
    if (!nullToAbsent || unitId != null) {
      map['unit_id'] = Variable<String>(unitId);
    }
    if (!nullToAbsent || priceSnapshotTyiyn != null) {
      map['price_snapshot_tyiyn'] = Variable<int>(priceSnapshotTyiyn);
    }
    if (!nullToAbsent || stockSnapshotMilli != null) {
      map['stock_snapshot_milli'] = Variable<int>(stockSnapshotMilli);
    }
    map['price_changed'] = Variable<bool>(priceChanged);
    map['stock_insufficient'] = Variable<bool>(stockInsufficient);
    map['line_no'] = Variable<int>(lineNo);
    map['owner_user_id'] = Variable<String>(ownerUserId);
    map['sync_state'] = Variable<String>(syncState);
    return map;
  }

  CartItemsDraftCompanion toCompanion(bool nullToAbsent) {
    return CartItemsDraftCompanion(
      localItemId: Value(localItemId),
      localCartId: Value(localCartId),
      serverItemId: serverItemId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverItemId),
      variantId: Value(variantId),
      packagingId: packagingId == null && nullToAbsent
          ? const Value.absent()
          : Value(packagingId),
      quantityMilli: Value(quantityMilli),
      unitId: unitId == null && nullToAbsent
          ? const Value.absent()
          : Value(unitId),
      priceSnapshotTyiyn: priceSnapshotTyiyn == null && nullToAbsent
          ? const Value.absent()
          : Value(priceSnapshotTyiyn),
      stockSnapshotMilli: stockSnapshotMilli == null && nullToAbsent
          ? const Value.absent()
          : Value(stockSnapshotMilli),
      priceChanged: Value(priceChanged),
      stockInsufficient: Value(stockInsufficient),
      lineNo: Value(lineNo),
      ownerUserId: Value(ownerUserId),
      syncState: Value(syncState),
    );
  }

  factory CartItemDraftRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CartItemDraftRow(
      localItemId: serializer.fromJson<String>(json['localItemId']),
      localCartId: serializer.fromJson<String>(json['localCartId']),
      serverItemId: serializer.fromJson<String?>(json['serverItemId']),
      variantId: serializer.fromJson<String>(json['variantId']),
      packagingId: serializer.fromJson<String?>(json['packagingId']),
      quantityMilli: serializer.fromJson<int>(json['quantityMilli']),
      unitId: serializer.fromJson<String?>(json['unitId']),
      priceSnapshotTyiyn: serializer.fromJson<int?>(json['priceSnapshotTyiyn']),
      stockSnapshotMilli: serializer.fromJson<int?>(json['stockSnapshotMilli']),
      priceChanged: serializer.fromJson<bool>(json['priceChanged']),
      stockInsufficient: serializer.fromJson<bool>(json['stockInsufficient']),
      lineNo: serializer.fromJson<int>(json['lineNo']),
      ownerUserId: serializer.fromJson<String>(json['ownerUserId']),
      syncState: serializer.fromJson<String>(json['syncState']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'localItemId': serializer.toJson<String>(localItemId),
      'localCartId': serializer.toJson<String>(localCartId),
      'serverItemId': serializer.toJson<String?>(serverItemId),
      'variantId': serializer.toJson<String>(variantId),
      'packagingId': serializer.toJson<String?>(packagingId),
      'quantityMilli': serializer.toJson<int>(quantityMilli),
      'unitId': serializer.toJson<String?>(unitId),
      'priceSnapshotTyiyn': serializer.toJson<int?>(priceSnapshotTyiyn),
      'stockSnapshotMilli': serializer.toJson<int?>(stockSnapshotMilli),
      'priceChanged': serializer.toJson<bool>(priceChanged),
      'stockInsufficient': serializer.toJson<bool>(stockInsufficient),
      'lineNo': serializer.toJson<int>(lineNo),
      'ownerUserId': serializer.toJson<String>(ownerUserId),
      'syncState': serializer.toJson<String>(syncState),
    };
  }

  CartItemDraftRow copyWith({
    String? localItemId,
    String? localCartId,
    Value<String?> serverItemId = const Value.absent(),
    String? variantId,
    Value<String?> packagingId = const Value.absent(),
    int? quantityMilli,
    Value<String?> unitId = const Value.absent(),
    Value<int?> priceSnapshotTyiyn = const Value.absent(),
    Value<int?> stockSnapshotMilli = const Value.absent(),
    bool? priceChanged,
    bool? stockInsufficient,
    int? lineNo,
    String? ownerUserId,
    String? syncState,
  }) => CartItemDraftRow(
    localItemId: localItemId ?? this.localItemId,
    localCartId: localCartId ?? this.localCartId,
    serverItemId: serverItemId.present ? serverItemId.value : this.serverItemId,
    variantId: variantId ?? this.variantId,
    packagingId: packagingId.present ? packagingId.value : this.packagingId,
    quantityMilli: quantityMilli ?? this.quantityMilli,
    unitId: unitId.present ? unitId.value : this.unitId,
    priceSnapshotTyiyn: priceSnapshotTyiyn.present
        ? priceSnapshotTyiyn.value
        : this.priceSnapshotTyiyn,
    stockSnapshotMilli: stockSnapshotMilli.present
        ? stockSnapshotMilli.value
        : this.stockSnapshotMilli,
    priceChanged: priceChanged ?? this.priceChanged,
    stockInsufficient: stockInsufficient ?? this.stockInsufficient,
    lineNo: lineNo ?? this.lineNo,
    ownerUserId: ownerUserId ?? this.ownerUserId,
    syncState: syncState ?? this.syncState,
  );
  CartItemDraftRow copyWithCompanion(CartItemsDraftCompanion data) {
    return CartItemDraftRow(
      localItemId: data.localItemId.present
          ? data.localItemId.value
          : this.localItemId,
      localCartId: data.localCartId.present
          ? data.localCartId.value
          : this.localCartId,
      serverItemId: data.serverItemId.present
          ? data.serverItemId.value
          : this.serverItemId,
      variantId: data.variantId.present ? data.variantId.value : this.variantId,
      packagingId: data.packagingId.present
          ? data.packagingId.value
          : this.packagingId,
      quantityMilli: data.quantityMilli.present
          ? data.quantityMilli.value
          : this.quantityMilli,
      unitId: data.unitId.present ? data.unitId.value : this.unitId,
      priceSnapshotTyiyn: data.priceSnapshotTyiyn.present
          ? data.priceSnapshotTyiyn.value
          : this.priceSnapshotTyiyn,
      stockSnapshotMilli: data.stockSnapshotMilli.present
          ? data.stockSnapshotMilli.value
          : this.stockSnapshotMilli,
      priceChanged: data.priceChanged.present
          ? data.priceChanged.value
          : this.priceChanged,
      stockInsufficient: data.stockInsufficient.present
          ? data.stockInsufficient.value
          : this.stockInsufficient,
      lineNo: data.lineNo.present ? data.lineNo.value : this.lineNo,
      ownerUserId: data.ownerUserId.present
          ? data.ownerUserId.value
          : this.ownerUserId,
      syncState: data.syncState.present ? data.syncState.value : this.syncState,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CartItemDraftRow(')
          ..write('localItemId: $localItemId, ')
          ..write('localCartId: $localCartId, ')
          ..write('serverItemId: $serverItemId, ')
          ..write('variantId: $variantId, ')
          ..write('packagingId: $packagingId, ')
          ..write('quantityMilli: $quantityMilli, ')
          ..write('unitId: $unitId, ')
          ..write('priceSnapshotTyiyn: $priceSnapshotTyiyn, ')
          ..write('stockSnapshotMilli: $stockSnapshotMilli, ')
          ..write('priceChanged: $priceChanged, ')
          ..write('stockInsufficient: $stockInsufficient, ')
          ..write('lineNo: $lineNo, ')
          ..write('ownerUserId: $ownerUserId, ')
          ..write('syncState: $syncState')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    localItemId,
    localCartId,
    serverItemId,
    variantId,
    packagingId,
    quantityMilli,
    unitId,
    priceSnapshotTyiyn,
    stockSnapshotMilli,
    priceChanged,
    stockInsufficient,
    lineNo,
    ownerUserId,
    syncState,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CartItemDraftRow &&
          other.localItemId == this.localItemId &&
          other.localCartId == this.localCartId &&
          other.serverItemId == this.serverItemId &&
          other.variantId == this.variantId &&
          other.packagingId == this.packagingId &&
          other.quantityMilli == this.quantityMilli &&
          other.unitId == this.unitId &&
          other.priceSnapshotTyiyn == this.priceSnapshotTyiyn &&
          other.stockSnapshotMilli == this.stockSnapshotMilli &&
          other.priceChanged == this.priceChanged &&
          other.stockInsufficient == this.stockInsufficient &&
          other.lineNo == this.lineNo &&
          other.ownerUserId == this.ownerUserId &&
          other.syncState == this.syncState);
}

class CartItemsDraftCompanion extends UpdateCompanion<CartItemDraftRow> {
  final Value<String> localItemId;
  final Value<String> localCartId;
  final Value<String?> serverItemId;
  final Value<String> variantId;
  final Value<String?> packagingId;
  final Value<int> quantityMilli;
  final Value<String?> unitId;
  final Value<int?> priceSnapshotTyiyn;
  final Value<int?> stockSnapshotMilli;
  final Value<bool> priceChanged;
  final Value<bool> stockInsufficient;
  final Value<int> lineNo;
  final Value<String> ownerUserId;
  final Value<String> syncState;
  final Value<int> rowid;
  const CartItemsDraftCompanion({
    this.localItemId = const Value.absent(),
    this.localCartId = const Value.absent(),
    this.serverItemId = const Value.absent(),
    this.variantId = const Value.absent(),
    this.packagingId = const Value.absent(),
    this.quantityMilli = const Value.absent(),
    this.unitId = const Value.absent(),
    this.priceSnapshotTyiyn = const Value.absent(),
    this.stockSnapshotMilli = const Value.absent(),
    this.priceChanged = const Value.absent(),
    this.stockInsufficient = const Value.absent(),
    this.lineNo = const Value.absent(),
    this.ownerUserId = const Value.absent(),
    this.syncState = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CartItemsDraftCompanion.insert({
    required String localItemId,
    required String localCartId,
    this.serverItemId = const Value.absent(),
    required String variantId,
    this.packagingId = const Value.absent(),
    required int quantityMilli,
    this.unitId = const Value.absent(),
    this.priceSnapshotTyiyn = const Value.absent(),
    this.stockSnapshotMilli = const Value.absent(),
    this.priceChanged = const Value.absent(),
    this.stockInsufficient = const Value.absent(),
    required int lineNo,
    required String ownerUserId,
    this.syncState = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : localItemId = Value(localItemId),
       localCartId = Value(localCartId),
       variantId = Value(variantId),
       quantityMilli = Value(quantityMilli),
       lineNo = Value(lineNo),
       ownerUserId = Value(ownerUserId);
  static Insertable<CartItemDraftRow> custom({
    Expression<String>? localItemId,
    Expression<String>? localCartId,
    Expression<String>? serverItemId,
    Expression<String>? variantId,
    Expression<String>? packagingId,
    Expression<int>? quantityMilli,
    Expression<String>? unitId,
    Expression<int>? priceSnapshotTyiyn,
    Expression<int>? stockSnapshotMilli,
    Expression<bool>? priceChanged,
    Expression<bool>? stockInsufficient,
    Expression<int>? lineNo,
    Expression<String>? ownerUserId,
    Expression<String>? syncState,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (localItemId != null) 'local_item_id': localItemId,
      if (localCartId != null) 'local_cart_id': localCartId,
      if (serverItemId != null) 'server_item_id': serverItemId,
      if (variantId != null) 'variant_id': variantId,
      if (packagingId != null) 'packaging_id': packagingId,
      if (quantityMilli != null) 'quantity_milli': quantityMilli,
      if (unitId != null) 'unit_id': unitId,
      if (priceSnapshotTyiyn != null)
        'price_snapshot_tyiyn': priceSnapshotTyiyn,
      if (stockSnapshotMilli != null)
        'stock_snapshot_milli': stockSnapshotMilli,
      if (priceChanged != null) 'price_changed': priceChanged,
      if (stockInsufficient != null) 'stock_insufficient': stockInsufficient,
      if (lineNo != null) 'line_no': lineNo,
      if (ownerUserId != null) 'owner_user_id': ownerUserId,
      if (syncState != null) 'sync_state': syncState,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CartItemsDraftCompanion copyWith({
    Value<String>? localItemId,
    Value<String>? localCartId,
    Value<String?>? serverItemId,
    Value<String>? variantId,
    Value<String?>? packagingId,
    Value<int>? quantityMilli,
    Value<String?>? unitId,
    Value<int?>? priceSnapshotTyiyn,
    Value<int?>? stockSnapshotMilli,
    Value<bool>? priceChanged,
    Value<bool>? stockInsufficient,
    Value<int>? lineNo,
    Value<String>? ownerUserId,
    Value<String>? syncState,
    Value<int>? rowid,
  }) {
    return CartItemsDraftCompanion(
      localItemId: localItemId ?? this.localItemId,
      localCartId: localCartId ?? this.localCartId,
      serverItemId: serverItemId ?? this.serverItemId,
      variantId: variantId ?? this.variantId,
      packagingId: packagingId ?? this.packagingId,
      quantityMilli: quantityMilli ?? this.quantityMilli,
      unitId: unitId ?? this.unitId,
      priceSnapshotTyiyn: priceSnapshotTyiyn ?? this.priceSnapshotTyiyn,
      stockSnapshotMilli: stockSnapshotMilli ?? this.stockSnapshotMilli,
      priceChanged: priceChanged ?? this.priceChanged,
      stockInsufficient: stockInsufficient ?? this.stockInsufficient,
      lineNo: lineNo ?? this.lineNo,
      ownerUserId: ownerUserId ?? this.ownerUserId,
      syncState: syncState ?? this.syncState,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localItemId.present) {
      map['local_item_id'] = Variable<String>(localItemId.value);
    }
    if (localCartId.present) {
      map['local_cart_id'] = Variable<String>(localCartId.value);
    }
    if (serverItemId.present) {
      map['server_item_id'] = Variable<String>(serverItemId.value);
    }
    if (variantId.present) {
      map['variant_id'] = Variable<String>(variantId.value);
    }
    if (packagingId.present) {
      map['packaging_id'] = Variable<String>(packagingId.value);
    }
    if (quantityMilli.present) {
      map['quantity_milli'] = Variable<int>(quantityMilli.value);
    }
    if (unitId.present) {
      map['unit_id'] = Variable<String>(unitId.value);
    }
    if (priceSnapshotTyiyn.present) {
      map['price_snapshot_tyiyn'] = Variable<int>(priceSnapshotTyiyn.value);
    }
    if (stockSnapshotMilli.present) {
      map['stock_snapshot_milli'] = Variable<int>(stockSnapshotMilli.value);
    }
    if (priceChanged.present) {
      map['price_changed'] = Variable<bool>(priceChanged.value);
    }
    if (stockInsufficient.present) {
      map['stock_insufficient'] = Variable<bool>(stockInsufficient.value);
    }
    if (lineNo.present) {
      map['line_no'] = Variable<int>(lineNo.value);
    }
    if (ownerUserId.present) {
      map['owner_user_id'] = Variable<String>(ownerUserId.value);
    }
    if (syncState.present) {
      map['sync_state'] = Variable<String>(syncState.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CartItemsDraftCompanion(')
          ..write('localItemId: $localItemId, ')
          ..write('localCartId: $localCartId, ')
          ..write('serverItemId: $serverItemId, ')
          ..write('variantId: $variantId, ')
          ..write('packagingId: $packagingId, ')
          ..write('quantityMilli: $quantityMilli, ')
          ..write('unitId: $unitId, ')
          ..write('priceSnapshotTyiyn: $priceSnapshotTyiyn, ')
          ..write('stockSnapshotMilli: $stockSnapshotMilli, ')
          ..write('priceChanged: $priceChanged, ')
          ..write('stockInsufficient: $stockInsufficient, ')
          ..write('lineNo: $lineNo, ')
          ..write('ownerUserId: $ownerUserId, ')
          ..write('syncState: $syncState, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OutboxActionsTable extends OutboxActions
    with TableInfo<$OutboxActionsTable, OutboxActionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OutboxActionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    check: () => type.isIn(outboxActionTypes),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _idempotencyKeyMeta = const VerificationMeta(
    'idempotencyKey',
  );
  @override
  late final GeneratedColumn<String> idempotencyKey = GeneratedColumn<String>(
    'idempotency_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _ownerUserIdMeta = const VerificationMeta(
    'ownerUserId',
  );
  @override
  late final GeneratedColumn<String> ownerUserId = GeneratedColumn<String>(
    'owner_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    check: () =>
        status.isIn(const ['pending', 'sending', 'done', 'failed', 'dead']),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<int> nextAttemptAt = GeneratedColumn<int>(
    'next_attempt_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    type,
    payloadJson,
    idempotencyKey,
    ownerUserId,
    status,
    attempts,
    lastError,
    createdAt,
    nextAttemptAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox_actions';
  @override
  VerificationContext validateIntegrity(
    Insertable<OutboxActionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('idempotency_key')) {
      context.handle(
        _idempotencyKeyMeta,
        idempotencyKey.isAcceptableOrUnknown(
          data['idempotency_key']!,
          _idempotencyKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_idempotencyKeyMeta);
    }
    if (data.containsKey('owner_user_id')) {
      context.handle(
        _ownerUserIdMeta,
        ownerUserId.isAcceptableOrUnknown(
          data['owner_user_id']!,
          _ownerUserIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_ownerUserIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  OutboxActionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OutboxActionRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      idempotencyKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}idempotency_key'],
      )!,
      ownerUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_user_id'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_attempt_at'],
      ),
    );
  }

  @override
  $OutboxActionsTable createAlias(String alias) {
    return $OutboxActionsTable(attachedDatabase, alias);
  }
}

class OutboxActionRow extends DataClass implements Insertable<OutboxActionRow> {
  final int id;
  final String type;
  final String payloadJson;
  final String idempotencyKey;
  final String ownerUserId;
  final String status;
  final int attempts;
  final String? lastError;
  final int createdAt;
  final int? nextAttemptAt;
  const OutboxActionRow({
    required this.id,
    required this.type,
    required this.payloadJson,
    required this.idempotencyKey,
    required this.ownerUserId,
    required this.status,
    required this.attempts,
    this.lastError,
    required this.createdAt,
    this.nextAttemptAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['type'] = Variable<String>(type);
    map['payload_json'] = Variable<String>(payloadJson);
    map['idempotency_key'] = Variable<String>(idempotencyKey);
    map['owner_user_id'] = Variable<String>(ownerUserId);
    map['status'] = Variable<String>(status);
    map['attempts'] = Variable<int>(attempts);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt);
    }
    return map;
  }

  OutboxActionsCompanion toCompanion(bool nullToAbsent) {
    return OutboxActionsCompanion(
      id: Value(id),
      type: Value(type),
      payloadJson: Value(payloadJson),
      idempotencyKey: Value(idempotencyKey),
      ownerUserId: Value(ownerUserId),
      status: Value(status),
      attempts: Value(attempts),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      createdAt: Value(createdAt),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
    );
  }

  factory OutboxActionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OutboxActionRow(
      id: serializer.fromJson<int>(json['id']),
      type: serializer.fromJson<String>(json['type']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      idempotencyKey: serializer.fromJson<String>(json['idempotencyKey']),
      ownerUserId: serializer.fromJson<String>(json['ownerUserId']),
      status: serializer.fromJson<String>(json['status']),
      attempts: serializer.fromJson<int>(json['attempts']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      nextAttemptAt: serializer.fromJson<int?>(json['nextAttemptAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'type': serializer.toJson<String>(type),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'idempotencyKey': serializer.toJson<String>(idempotencyKey),
      'ownerUserId': serializer.toJson<String>(ownerUserId),
      'status': serializer.toJson<String>(status),
      'attempts': serializer.toJson<int>(attempts),
      'lastError': serializer.toJson<String?>(lastError),
      'createdAt': serializer.toJson<int>(createdAt),
      'nextAttemptAt': serializer.toJson<int?>(nextAttemptAt),
    };
  }

  OutboxActionRow copyWith({
    int? id,
    String? type,
    String? payloadJson,
    String? idempotencyKey,
    String? ownerUserId,
    String? status,
    int? attempts,
    Value<String?> lastError = const Value.absent(),
    int? createdAt,
    Value<int?> nextAttemptAt = const Value.absent(),
  }) => OutboxActionRow(
    id: id ?? this.id,
    type: type ?? this.type,
    payloadJson: payloadJson ?? this.payloadJson,
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    ownerUserId: ownerUserId ?? this.ownerUserId,
    status: status ?? this.status,
    attempts: attempts ?? this.attempts,
    lastError: lastError.present ? lastError.value : this.lastError,
    createdAt: createdAt ?? this.createdAt,
    nextAttemptAt: nextAttemptAt.present
        ? nextAttemptAt.value
        : this.nextAttemptAt,
  );
  OutboxActionRow copyWithCompanion(OutboxActionsCompanion data) {
    return OutboxActionRow(
      id: data.id.present ? data.id.value : this.id,
      type: data.type.present ? data.type.value : this.type,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      idempotencyKey: data.idempotencyKey.present
          ? data.idempotencyKey.value
          : this.idempotencyKey,
      ownerUserId: data.ownerUserId.present
          ? data.ownerUserId.value
          : this.ownerUserId,
      status: data.status.present ? data.status.value : this.status,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OutboxActionRow(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('ownerUserId: $ownerUserId, ')
          ..write('status: $status, ')
          ..write('attempts: $attempts, ')
          ..write('lastError: $lastError, ')
          ..write('createdAt: $createdAt, ')
          ..write('nextAttemptAt: $nextAttemptAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    type,
    payloadJson,
    idempotencyKey,
    ownerUserId,
    status,
    attempts,
    lastError,
    createdAt,
    nextAttemptAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OutboxActionRow &&
          other.id == this.id &&
          other.type == this.type &&
          other.payloadJson == this.payloadJson &&
          other.idempotencyKey == this.idempotencyKey &&
          other.ownerUserId == this.ownerUserId &&
          other.status == this.status &&
          other.attempts == this.attempts &&
          other.lastError == this.lastError &&
          other.createdAt == this.createdAt &&
          other.nextAttemptAt == this.nextAttemptAt);
}

class OutboxActionsCompanion extends UpdateCompanion<OutboxActionRow> {
  final Value<int> id;
  final Value<String> type;
  final Value<String> payloadJson;
  final Value<String> idempotencyKey;
  final Value<String> ownerUserId;
  final Value<String> status;
  final Value<int> attempts;
  final Value<String?> lastError;
  final Value<int> createdAt;
  final Value<int?> nextAttemptAt;
  const OutboxActionsCompanion({
    this.id = const Value.absent(),
    this.type = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.idempotencyKey = const Value.absent(),
    this.ownerUserId = const Value.absent(),
    this.status = const Value.absent(),
    this.attempts = const Value.absent(),
    this.lastError = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
  });
  OutboxActionsCompanion.insert({
    this.id = const Value.absent(),
    required String type,
    required String payloadJson,
    required String idempotencyKey,
    required String ownerUserId,
    this.status = const Value.absent(),
    this.attempts = const Value.absent(),
    this.lastError = const Value.absent(),
    required int createdAt,
    this.nextAttemptAt = const Value.absent(),
  }) : type = Value(type),
       payloadJson = Value(payloadJson),
       idempotencyKey = Value(idempotencyKey),
       ownerUserId = Value(ownerUserId),
       createdAt = Value(createdAt);
  static Insertable<OutboxActionRow> custom({
    Expression<int>? id,
    Expression<String>? type,
    Expression<String>? payloadJson,
    Expression<String>? idempotencyKey,
    Expression<String>? ownerUserId,
    Expression<String>? status,
    Expression<int>? attempts,
    Expression<String>? lastError,
    Expression<int>? createdAt,
    Expression<int>? nextAttemptAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (type != null) 'type': type,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      if (ownerUserId != null) 'owner_user_id': ownerUserId,
      if (status != null) 'status': status,
      if (attempts != null) 'attempts': attempts,
      if (lastError != null) 'last_error': lastError,
      if (createdAt != null) 'created_at': createdAt,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
    });
  }

  OutboxActionsCompanion copyWith({
    Value<int>? id,
    Value<String>? type,
    Value<String>? payloadJson,
    Value<String>? idempotencyKey,
    Value<String>? ownerUserId,
    Value<String>? status,
    Value<int>? attempts,
    Value<String?>? lastError,
    Value<int>? createdAt,
    Value<int?>? nextAttemptAt,
  }) {
    return OutboxActionsCompanion(
      id: id ?? this.id,
      type: type ?? this.type,
      payloadJson: payloadJson ?? this.payloadJson,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      ownerUserId: ownerUserId ?? this.ownerUserId,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      lastError: lastError ?? this.lastError,
      createdAt: createdAt ?? this.createdAt,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (idempotencyKey.present) {
      map['idempotency_key'] = Variable<String>(idempotencyKey.value);
    }
    if (ownerUserId.present) {
      map['owner_user_id'] = Variable<String>(ownerUserId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OutboxActionsCompanion(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('ownerUserId: $ownerUserId, ')
          ..write('status: $status, ')
          ..write('attempts: $attempts, ')
          ..write('lastError: $lastError, ')
          ..write('createdAt: $createdAt, ')
          ..write('nextAttemptAt: $nextAttemptAt')
          ..write(')'))
        .toString();
  }
}

class $LocalRecentProductsTable extends LocalRecentProducts
    with TableInfo<$LocalRecentProductsTable, RecentProductRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalRecentProductsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastViewedAtMeta = const VerificationMeta(
    'lastViewedAt',
  );
  @override
  late final GeneratedColumn<int> lastViewedAt = GeneratedColumn<int>(
    'last_viewed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _viewCountMeta = const VerificationMeta(
    'viewCount',
  );
  @override
  late final GeneratedColumn<int> viewCount = GeneratedColumn<int>(
    'view_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  @override
  List<GeneratedColumn> get $columns => [productId, lastViewedAt, viewCount];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recent_products';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecentProductRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('last_viewed_at')) {
      context.handle(
        _lastViewedAtMeta,
        lastViewedAt.isAcceptableOrUnknown(
          data['last_viewed_at']!,
          _lastViewedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastViewedAtMeta);
    }
    if (data.containsKey('view_count')) {
      context.handle(
        _viewCountMeta,
        viewCount.isAcceptableOrUnknown(data['view_count']!, _viewCountMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {productId};
  @override
  RecentProductRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecentProductRow(
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      lastViewedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_viewed_at'],
      )!,
      viewCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}view_count'],
      )!,
    );
  }

  @override
  $LocalRecentProductsTable createAlias(String alias) {
    return $LocalRecentProductsTable(attachedDatabase, alias);
  }
}

class RecentProductRow extends DataClass
    implements Insertable<RecentProductRow> {
  final String productId;
  final int lastViewedAt;
  final int viewCount;
  const RecentProductRow({
    required this.productId,
    required this.lastViewedAt,
    required this.viewCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['product_id'] = Variable<String>(productId);
    map['last_viewed_at'] = Variable<int>(lastViewedAt);
    map['view_count'] = Variable<int>(viewCount);
    return map;
  }

  LocalRecentProductsCompanion toCompanion(bool nullToAbsent) {
    return LocalRecentProductsCompanion(
      productId: Value(productId),
      lastViewedAt: Value(lastViewedAt),
      viewCount: Value(viewCount),
    );
  }

  factory RecentProductRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecentProductRow(
      productId: serializer.fromJson<String>(json['productId']),
      lastViewedAt: serializer.fromJson<int>(json['lastViewedAt']),
      viewCount: serializer.fromJson<int>(json['viewCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'productId': serializer.toJson<String>(productId),
      'lastViewedAt': serializer.toJson<int>(lastViewedAt),
      'viewCount': serializer.toJson<int>(viewCount),
    };
  }

  RecentProductRow copyWith({
    String? productId,
    int? lastViewedAt,
    int? viewCount,
  }) => RecentProductRow(
    productId: productId ?? this.productId,
    lastViewedAt: lastViewedAt ?? this.lastViewedAt,
    viewCount: viewCount ?? this.viewCount,
  );
  RecentProductRow copyWithCompanion(LocalRecentProductsCompanion data) {
    return RecentProductRow(
      productId: data.productId.present ? data.productId.value : this.productId,
      lastViewedAt: data.lastViewedAt.present
          ? data.lastViewedAt.value
          : this.lastViewedAt,
      viewCount: data.viewCount.present ? data.viewCount.value : this.viewCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecentProductRow(')
          ..write('productId: $productId, ')
          ..write('lastViewedAt: $lastViewedAt, ')
          ..write('viewCount: $viewCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(productId, lastViewedAt, viewCount);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecentProductRow &&
          other.productId == this.productId &&
          other.lastViewedAt == this.lastViewedAt &&
          other.viewCount == this.viewCount);
}

class LocalRecentProductsCompanion extends UpdateCompanion<RecentProductRow> {
  final Value<String> productId;
  final Value<int> lastViewedAt;
  final Value<int> viewCount;
  final Value<int> rowid;
  const LocalRecentProductsCompanion({
    this.productId = const Value.absent(),
    this.lastViewedAt = const Value.absent(),
    this.viewCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalRecentProductsCompanion.insert({
    required String productId,
    required int lastViewedAt,
    this.viewCount = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : productId = Value(productId),
       lastViewedAt = Value(lastViewedAt);
  static Insertable<RecentProductRow> custom({
    Expression<String>? productId,
    Expression<int>? lastViewedAt,
    Expression<int>? viewCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (productId != null) 'product_id': productId,
      if (lastViewedAt != null) 'last_viewed_at': lastViewedAt,
      if (viewCount != null) 'view_count': viewCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalRecentProductsCompanion copyWith({
    Value<String>? productId,
    Value<int>? lastViewedAt,
    Value<int>? viewCount,
    Value<int>? rowid,
  }) {
    return LocalRecentProductsCompanion(
      productId: productId ?? this.productId,
      lastViewedAt: lastViewedAt ?? this.lastViewedAt,
      viewCount: viewCount ?? this.viewCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (lastViewedAt.present) {
      map['last_viewed_at'] = Variable<int>(lastViewedAt.value);
    }
    if (viewCount.present) {
      map['view_count'] = Variable<int>(viewCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalRecentProductsCompanion(')
          ..write('productId: $productId, ')
          ..write('lastViewedAt: $lastViewedAt, ')
          ..write('viewCount: $viewCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $NotificationsCacheTable extends NotificationsCache
    with TableInfo<$NotificationsCacheTable, NotificationCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotificationsCacheTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _severityMeta = const VerificationMeta(
    'severity',
  );
  @override
  late final GeneratedColumn<String> severity = GeneratedColumn<String>(
    'severity',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _readAtMeta = const VerificationMeta('readAt');
  @override
  late final GeneratedColumn<int> readAt = GeneratedColumn<int>(
    'read_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    severity,
    title,
    body,
    payloadJson,
    createdAt,
    readAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notifications_cache';
  @override
  VerificationContext validateIntegrity(
    Insertable<NotificationCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('severity')) {
      context.handle(
        _severityMeta,
        severity.isAcceptableOrUnknown(data['severity']!, _severityMeta),
      );
    } else if (isInserting) {
      context.missing(_severityMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('read_at')) {
      context.handle(
        _readAtMeta,
        readAt.isAcceptableOrUnknown(data['read_at']!, _readAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  NotificationCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NotificationCacheRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      severity: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}severity'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      ),
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      readAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}read_at'],
      ),
    );
  }

  @override
  $NotificationsCacheTable createAlias(String alias) {
    return $NotificationsCacheTable(attachedDatabase, alias);
  }
}

class NotificationCacheRow extends DataClass
    implements Insertable<NotificationCacheRow> {
  final String id;
  final String kind;
  final String severity;
  final String title;
  final String? body;
  final String? payloadJson;
  final int createdAt;
  final int? readAt;
  const NotificationCacheRow({
    required this.id,
    required this.kind,
    required this.severity,
    required this.title,
    this.body,
    this.payloadJson,
    required this.createdAt,
    this.readAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['severity'] = Variable<String>(severity);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || body != null) {
      map['body'] = Variable<String>(body);
    }
    if (!nullToAbsent || payloadJson != null) {
      map['payload_json'] = Variable<String>(payloadJson);
    }
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || readAt != null) {
      map['read_at'] = Variable<int>(readAt);
    }
    return map;
  }

  NotificationsCacheCompanion toCompanion(bool nullToAbsent) {
    return NotificationsCacheCompanion(
      id: Value(id),
      kind: Value(kind),
      severity: Value(severity),
      title: Value(title),
      body: body == null && nullToAbsent ? const Value.absent() : Value(body),
      payloadJson: payloadJson == null && nullToAbsent
          ? const Value.absent()
          : Value(payloadJson),
      createdAt: Value(createdAt),
      readAt: readAt == null && nullToAbsent
          ? const Value.absent()
          : Value(readAt),
    );
  }

  factory NotificationCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NotificationCacheRow(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      severity: serializer.fromJson<String>(json['severity']),
      title: serializer.fromJson<String>(json['title']),
      body: serializer.fromJson<String?>(json['body']),
      payloadJson: serializer.fromJson<String?>(json['payloadJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      readAt: serializer.fromJson<int?>(json['readAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'severity': serializer.toJson<String>(severity),
      'title': serializer.toJson<String>(title),
      'body': serializer.toJson<String?>(body),
      'payloadJson': serializer.toJson<String?>(payloadJson),
      'createdAt': serializer.toJson<int>(createdAt),
      'readAt': serializer.toJson<int?>(readAt),
    };
  }

  NotificationCacheRow copyWith({
    String? id,
    String? kind,
    String? severity,
    String? title,
    Value<String?> body = const Value.absent(),
    Value<String?> payloadJson = const Value.absent(),
    int? createdAt,
    Value<int?> readAt = const Value.absent(),
  }) => NotificationCacheRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    severity: severity ?? this.severity,
    title: title ?? this.title,
    body: body.present ? body.value : this.body,
    payloadJson: payloadJson.present ? payloadJson.value : this.payloadJson,
    createdAt: createdAt ?? this.createdAt,
    readAt: readAt.present ? readAt.value : this.readAt,
  );
  NotificationCacheRow copyWithCompanion(NotificationsCacheCompanion data) {
    return NotificationCacheRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      severity: data.severity.present ? data.severity.value : this.severity,
      title: data.title.present ? data.title.value : this.title,
      body: data.body.present ? data.body.value : this.body,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      readAt: data.readAt.present ? data.readAt.value : this.readAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NotificationCacheRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('severity: $severity, ')
          ..write('title: $title, ')
          ..write('body: $body, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('readAt: $readAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    severity,
    title,
    body,
    payloadJson,
    createdAt,
    readAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NotificationCacheRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.severity == this.severity &&
          other.title == this.title &&
          other.body == this.body &&
          other.payloadJson == this.payloadJson &&
          other.createdAt == this.createdAt &&
          other.readAt == this.readAt);
}

class NotificationsCacheCompanion
    extends UpdateCompanion<NotificationCacheRow> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String> severity;
  final Value<String> title;
  final Value<String?> body;
  final Value<String?> payloadJson;
  final Value<int> createdAt;
  final Value<int?> readAt;
  final Value<int> rowid;
  const NotificationsCacheCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.severity = const Value.absent(),
    this.title = const Value.absent(),
    this.body = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.readAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotificationsCacheCompanion.insert({
    required String id,
    required String kind,
    required String severity,
    required String title,
    this.body = const Value.absent(),
    this.payloadJson = const Value.absent(),
    required int createdAt,
    this.readAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       severity = Value(severity),
       title = Value(title),
       createdAt = Value(createdAt);
  static Insertable<NotificationCacheRow> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? severity,
    Expression<String>? title,
    Expression<String>? body,
    Expression<String>? payloadJson,
    Expression<int>? createdAt,
    Expression<int>? readAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (severity != null) 'severity': severity,
      if (title != null) 'title': title,
      if (body != null) 'body': body,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (createdAt != null) 'created_at': createdAt,
      if (readAt != null) 'read_at': readAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotificationsCacheCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String>? severity,
    Value<String>? title,
    Value<String?>? body,
    Value<String?>? payloadJson,
    Value<int>? createdAt,
    Value<int?>? readAt,
    Value<int>? rowid,
  }) {
    return NotificationsCacheCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      severity: severity ?? this.severity,
      title: title ?? this.title,
      body: body ?? this.body,
      payloadJson: payloadJson ?? this.payloadJson,
      createdAt: createdAt ?? this.createdAt,
      readAt: readAt ?? this.readAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (severity.present) {
      map['severity'] = Variable<String>(severity.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (readAt.present) {
      map['read_at'] = Variable<int>(readAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotificationsCacheCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('severity: $severity, ')
          ..write('title: $title, ')
          ..write('body: $body, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('readAt: $readAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalSettingsTable extends LocalSettings
    with TableInfo<$LocalSettingsTable, SettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueJsonMeta = const VerificationMeta(
    'valueJson',
  );
  @override
  late final GeneratedColumn<String> valueJson = GeneratedColumn<String>(
    'value_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeMeta = const VerificationMeta('scope');
  @override
  late final GeneratedColumn<String> scope = GeneratedColumn<String>(
    'scope',
    aliasedName,
    false,
    check: () => scope.isIn(const ['user', 'device']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    key,
    valueJson,
    scope,
    updatedAt,
    dirty,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<SettingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value_json')) {
      context.handle(
        _valueJsonMeta,
        valueJson.isAcceptableOrUnknown(data['value_json']!, _valueJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_valueJsonMeta);
    }
    if (data.containsKey('scope')) {
      context.handle(
        _scopeMeta,
        scope.isAcceptableOrUnknown(data['scope']!, _scopeMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      valueJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value_json'],
      )!,
      scope: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
    );
  }

  @override
  $LocalSettingsTable createAlias(String alias) {
    return $LocalSettingsTable(attachedDatabase, alias);
  }
}

class SettingRow extends DataClass implements Insertable<SettingRow> {
  final String key;
  final String valueJson;
  final String scope;
  final int updatedAt;
  final bool dirty;
  const SettingRow({
    required this.key,
    required this.valueJson,
    required this.scope,
    required this.updatedAt,
    required this.dirty,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value_json'] = Variable<String>(valueJson);
    map['scope'] = Variable<String>(scope);
    map['updated_at'] = Variable<int>(updatedAt);
    map['dirty'] = Variable<bool>(dirty);
    return map;
  }

  LocalSettingsCompanion toCompanion(bool nullToAbsent) {
    return LocalSettingsCompanion(
      key: Value(key),
      valueJson: Value(valueJson),
      scope: Value(scope),
      updatedAt: Value(updatedAt),
      dirty: Value(dirty),
    );
  }

  factory SettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingRow(
      key: serializer.fromJson<String>(json['key']),
      valueJson: serializer.fromJson<String>(json['valueJson']),
      scope: serializer.fromJson<String>(json['scope']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      dirty: serializer.fromJson<bool>(json['dirty']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'valueJson': serializer.toJson<String>(valueJson),
      'scope': serializer.toJson<String>(scope),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'dirty': serializer.toJson<bool>(dirty),
    };
  }

  SettingRow copyWith({
    String? key,
    String? valueJson,
    String? scope,
    int? updatedAt,
    bool? dirty,
  }) => SettingRow(
    key: key ?? this.key,
    valueJson: valueJson ?? this.valueJson,
    scope: scope ?? this.scope,
    updatedAt: updatedAt ?? this.updatedAt,
    dirty: dirty ?? this.dirty,
  );
  SettingRow copyWithCompanion(LocalSettingsCompanion data) {
    return SettingRow(
      key: data.key.present ? data.key.value : this.key,
      valueJson: data.valueJson.present ? data.valueJson.value : this.valueJson,
      scope: data.scope.present ? data.scope.value : this.scope,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingRow(')
          ..write('key: $key, ')
          ..write('valueJson: $valueJson, ')
          ..write('scope: $scope, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('dirty: $dirty')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, valueJson, scope, updatedAt, dirty);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingRow &&
          other.key == this.key &&
          other.valueJson == this.valueJson &&
          other.scope == this.scope &&
          other.updatedAt == this.updatedAt &&
          other.dirty == this.dirty);
}

class LocalSettingsCompanion extends UpdateCompanion<SettingRow> {
  final Value<String> key;
  final Value<String> valueJson;
  final Value<String> scope;
  final Value<int> updatedAt;
  final Value<bool> dirty;
  final Value<int> rowid;
  const LocalSettingsCompanion({
    this.key = const Value.absent(),
    this.valueJson = const Value.absent(),
    this.scope = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.dirty = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalSettingsCompanion.insert({
    required String key,
    required String valueJson,
    required String scope,
    required int updatedAt,
    this.dirty = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       valueJson = Value(valueJson),
       scope = Value(scope),
       updatedAt = Value(updatedAt);
  static Insertable<SettingRow> custom({
    Expression<String>? key,
    Expression<String>? valueJson,
    Expression<String>? scope,
    Expression<int>? updatedAt,
    Expression<bool>? dirty,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (valueJson != null) 'value_json': valueJson,
      if (scope != null) 'scope': scope,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (dirty != null) 'dirty': dirty,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? valueJson,
    Value<String>? scope,
    Value<int>? updatedAt,
    Value<bool>? dirty,
    Value<int>? rowid,
  }) {
    return LocalSettingsCompanion(
      key: key ?? this.key,
      valueJson: valueJson ?? this.valueJson,
      scope: scope ?? this.scope,
      updatedAt: updatedAt ?? this.updatedAt,
      dirty: dirty ?? this.dirty,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (valueJson.present) {
      map['value_json'] = Variable<String>(valueJson.value);
    }
    if (scope.present) {
      map['scope'] = Variable<String>(scope.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalSettingsCompanion(')
          ..write('key: $key, ')
          ..write('valueJson: $valueJson, ')
          ..write('scope: $scope, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('dirty: $dirty, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RegistrationDraftTable extends RegistrationDraft
    with TableInfo<$RegistrationDraftTable, RegistrationDraftRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RegistrationDraftTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueJsonMeta = const VerificationMeta(
    'valueJson',
  );
  @override
  late final GeneratedColumn<String> valueJson = GeneratedColumn<String>(
    'value_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, valueJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'registration_draft';
  @override
  VerificationContext validateIntegrity(
    Insertable<RegistrationDraftRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value_json')) {
      context.handle(
        _valueJsonMeta,
        valueJson.isAcceptableOrUnknown(data['value_json']!, _valueJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_valueJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  RegistrationDraftRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RegistrationDraftRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      valueJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value_json'],
      )!,
    );
  }

  @override
  $RegistrationDraftTable createAlias(String alias) {
    return $RegistrationDraftTable(attachedDatabase, alias);
  }
}

class RegistrationDraftRow extends DataClass
    implements Insertable<RegistrationDraftRow> {
  final String key;
  final String valueJson;
  const RegistrationDraftRow({required this.key, required this.valueJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value_json'] = Variable<String>(valueJson);
    return map;
  }

  RegistrationDraftCompanion toCompanion(bool nullToAbsent) {
    return RegistrationDraftCompanion(
      key: Value(key),
      valueJson: Value(valueJson),
    );
  }

  factory RegistrationDraftRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RegistrationDraftRow(
      key: serializer.fromJson<String>(json['key']),
      valueJson: serializer.fromJson<String>(json['valueJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'valueJson': serializer.toJson<String>(valueJson),
    };
  }

  RegistrationDraftRow copyWith({String? key, String? valueJson}) =>
      RegistrationDraftRow(
        key: key ?? this.key,
        valueJson: valueJson ?? this.valueJson,
      );
  RegistrationDraftRow copyWithCompanion(RegistrationDraftCompanion data) {
    return RegistrationDraftRow(
      key: data.key.present ? data.key.value : this.key,
      valueJson: data.valueJson.present ? data.valueJson.value : this.valueJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RegistrationDraftRow(')
          ..write('key: $key, ')
          ..write('valueJson: $valueJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, valueJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RegistrationDraftRow &&
          other.key == this.key &&
          other.valueJson == this.valueJson);
}

class RegistrationDraftCompanion extends UpdateCompanion<RegistrationDraftRow> {
  final Value<String> key;
  final Value<String> valueJson;
  final Value<int> rowid;
  const RegistrationDraftCompanion({
    this.key = const Value.absent(),
    this.valueJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RegistrationDraftCompanion.insert({
    required String key,
    required String valueJson,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       valueJson = Value(valueJson);
  static Insertable<RegistrationDraftRow> custom({
    Expression<String>? key,
    Expression<String>? valueJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (valueJson != null) 'value_json': valueJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RegistrationDraftCompanion copyWith({
    Value<String>? key,
    Value<String>? valueJson,
    Value<int>? rowid,
  }) {
    return RegistrationDraftCompanion(
      key: key ?? this.key,
      valueJson: valueJson ?? this.valueJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (valueJson.present) {
      map['value_json'] = Variable<String>(valueJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RegistrationDraftCompanion(')
          ..write('key: $key, ')
          ..write('valueJson: $valueJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CheckoutDraftTable extends CheckoutDraft
    with TableInfo<$CheckoutDraftTable, CheckoutDraftRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CheckoutDraftTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localCartIdMeta = const VerificationMeta(
    'localCartId',
  );
  @override
  late final GeneratedColumn<String> localCartId = GeneratedColumn<String>(
    'local_cart_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stepMeta = const VerificationMeta('step');
  @override
  late final GeneratedColumn<String> step = GeneratedColumn<String>(
    'step',
    aliasedName,
    false,
    check: () => step.isIn(const ['customer', 'delivery', 'payment', 'review']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _customerIdMeta = const VerificationMeta(
    'customerId',
  );
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
    'customer_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deliveryMethodMeta = const VerificationMeta(
    'deliveryMethod',
  );
  @override
  late final GeneratedColumn<String> deliveryMethod = GeneratedColumn<String>(
    'delivery_method',
    aliasedName,
    true,
    check: () => deliveryMethod.isIn(const ['pickup', 'delivery']),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _receiverKindMeta = const VerificationMeta(
    'receiverKind',
  );
  @override
  late final GeneratedColumn<String> receiverKind = GeneratedColumn<String>(
    'receiver_kind',
    aliasedName,
    true,
    check: () => receiverKind.isIn(const ['customer', 'other_person']),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _paymentMethodMeta = const VerificationMeta(
    'paymentMethod',
  );
  @override
  late final GeneratedColumn<String> paymentMethod = GeneratedColumn<String>(
    'payment_method',
    aliasedName,
    true,
    check: () => paymentMethod.isIn(const ['cash', 'qr_bakai', 'credit']),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _orderIdempotencyKeyMeta =
      const VerificationMeta('orderIdempotencyKey');
  @override
  late final GeneratedColumn<String> orderIdempotencyKey =
      GeneratedColumn<String>(
        'order_idempotency_key',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _submittedAtMeta = const VerificationMeta(
    'submittedAt',
  );
  @override
  late final GeneratedColumn<int> submittedAt = GeneratedColumn<int>(
    'submitted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    localCartId,
    step,
    customerId,
    deliveryMethod,
    receiverKind,
    paymentMethod,
    orderIdempotencyKey,
    submittedAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'checkout_draft';
  @override
  VerificationContext validateIntegrity(
    Insertable<CheckoutDraftRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_cart_id')) {
      context.handle(
        _localCartIdMeta,
        localCartId.isAcceptableOrUnknown(
          data['local_cart_id']!,
          _localCartIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localCartIdMeta);
    }
    if (data.containsKey('step')) {
      context.handle(
        _stepMeta,
        step.isAcceptableOrUnknown(data['step']!, _stepMeta),
      );
    } else if (isInserting) {
      context.missing(_stepMeta);
    }
    if (data.containsKey('customer_id')) {
      context.handle(
        _customerIdMeta,
        customerId.isAcceptableOrUnknown(data['customer_id']!, _customerIdMeta),
      );
    }
    if (data.containsKey('delivery_method')) {
      context.handle(
        _deliveryMethodMeta,
        deliveryMethod.isAcceptableOrUnknown(
          data['delivery_method']!,
          _deliveryMethodMeta,
        ),
      );
    }
    if (data.containsKey('receiver_kind')) {
      context.handle(
        _receiverKindMeta,
        receiverKind.isAcceptableOrUnknown(
          data['receiver_kind']!,
          _receiverKindMeta,
        ),
      );
    }
    if (data.containsKey('payment_method')) {
      context.handle(
        _paymentMethodMeta,
        paymentMethod.isAcceptableOrUnknown(
          data['payment_method']!,
          _paymentMethodMeta,
        ),
      );
    }
    if (data.containsKey('order_idempotency_key')) {
      context.handle(
        _orderIdempotencyKeyMeta,
        orderIdempotencyKey.isAcceptableOrUnknown(
          data['order_idempotency_key']!,
          _orderIdempotencyKeyMeta,
        ),
      );
    }
    if (data.containsKey('submitted_at')) {
      context.handle(
        _submittedAtMeta,
        submittedAt.isAcceptableOrUnknown(
          data['submitted_at']!,
          _submittedAtMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localCartId};
  @override
  CheckoutDraftRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CheckoutDraftRow(
      localCartId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_cart_id'],
      )!,
      step: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}step'],
      )!,
      customerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}customer_id'],
      ),
      deliveryMethod: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}delivery_method'],
      ),
      receiverKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receiver_kind'],
      ),
      paymentMethod: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payment_method'],
      ),
      orderIdempotencyKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}order_idempotency_key'],
      ),
      submittedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}submitted_at'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $CheckoutDraftTable createAlias(String alias) {
    return $CheckoutDraftTable(attachedDatabase, alias);
  }
}

class CheckoutDraftRow extends DataClass
    implements Insertable<CheckoutDraftRow> {
  final String localCartId;
  final String step;
  final String? customerId;
  final String? deliveryMethod;
  final String? receiverKind;
  final String? paymentMethod;
  final String? orderIdempotencyKey;
  final int? submittedAt;
  final int updatedAt;
  const CheckoutDraftRow({
    required this.localCartId,
    required this.step,
    this.customerId,
    this.deliveryMethod,
    this.receiverKind,
    this.paymentMethod,
    this.orderIdempotencyKey,
    this.submittedAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['local_cart_id'] = Variable<String>(localCartId);
    map['step'] = Variable<String>(step);
    if (!nullToAbsent || customerId != null) {
      map['customer_id'] = Variable<String>(customerId);
    }
    if (!nullToAbsent || deliveryMethod != null) {
      map['delivery_method'] = Variable<String>(deliveryMethod);
    }
    if (!nullToAbsent || receiverKind != null) {
      map['receiver_kind'] = Variable<String>(receiverKind);
    }
    if (!nullToAbsent || paymentMethod != null) {
      map['payment_method'] = Variable<String>(paymentMethod);
    }
    if (!nullToAbsent || orderIdempotencyKey != null) {
      map['order_idempotency_key'] = Variable<String>(orderIdempotencyKey);
    }
    if (!nullToAbsent || submittedAt != null) {
      map['submitted_at'] = Variable<int>(submittedAt);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  CheckoutDraftCompanion toCompanion(bool nullToAbsent) {
    return CheckoutDraftCompanion(
      localCartId: Value(localCartId),
      step: Value(step),
      customerId: customerId == null && nullToAbsent
          ? const Value.absent()
          : Value(customerId),
      deliveryMethod: deliveryMethod == null && nullToAbsent
          ? const Value.absent()
          : Value(deliveryMethod),
      receiverKind: receiverKind == null && nullToAbsent
          ? const Value.absent()
          : Value(receiverKind),
      paymentMethod: paymentMethod == null && nullToAbsent
          ? const Value.absent()
          : Value(paymentMethod),
      orderIdempotencyKey: orderIdempotencyKey == null && nullToAbsent
          ? const Value.absent()
          : Value(orderIdempotencyKey),
      submittedAt: submittedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(submittedAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory CheckoutDraftRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CheckoutDraftRow(
      localCartId: serializer.fromJson<String>(json['localCartId']),
      step: serializer.fromJson<String>(json['step']),
      customerId: serializer.fromJson<String?>(json['customerId']),
      deliveryMethod: serializer.fromJson<String?>(json['deliveryMethod']),
      receiverKind: serializer.fromJson<String?>(json['receiverKind']),
      paymentMethod: serializer.fromJson<String?>(json['paymentMethod']),
      orderIdempotencyKey: serializer.fromJson<String?>(
        json['orderIdempotencyKey'],
      ),
      submittedAt: serializer.fromJson<int?>(json['submittedAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'localCartId': serializer.toJson<String>(localCartId),
      'step': serializer.toJson<String>(step),
      'customerId': serializer.toJson<String?>(customerId),
      'deliveryMethod': serializer.toJson<String?>(deliveryMethod),
      'receiverKind': serializer.toJson<String?>(receiverKind),
      'paymentMethod': serializer.toJson<String?>(paymentMethod),
      'orderIdempotencyKey': serializer.toJson<String?>(orderIdempotencyKey),
      'submittedAt': serializer.toJson<int?>(submittedAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  CheckoutDraftRow copyWith({
    String? localCartId,
    String? step,
    Value<String?> customerId = const Value.absent(),
    Value<String?> deliveryMethod = const Value.absent(),
    Value<String?> receiverKind = const Value.absent(),
    Value<String?> paymentMethod = const Value.absent(),
    Value<String?> orderIdempotencyKey = const Value.absent(),
    Value<int?> submittedAt = const Value.absent(),
    int? updatedAt,
  }) => CheckoutDraftRow(
    localCartId: localCartId ?? this.localCartId,
    step: step ?? this.step,
    customerId: customerId.present ? customerId.value : this.customerId,
    deliveryMethod: deliveryMethod.present
        ? deliveryMethod.value
        : this.deliveryMethod,
    receiverKind: receiverKind.present ? receiverKind.value : this.receiverKind,
    paymentMethod: paymentMethod.present
        ? paymentMethod.value
        : this.paymentMethod,
    orderIdempotencyKey: orderIdempotencyKey.present
        ? orderIdempotencyKey.value
        : this.orderIdempotencyKey,
    submittedAt: submittedAt.present ? submittedAt.value : this.submittedAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CheckoutDraftRow copyWithCompanion(CheckoutDraftCompanion data) {
    return CheckoutDraftRow(
      localCartId: data.localCartId.present
          ? data.localCartId.value
          : this.localCartId,
      step: data.step.present ? data.step.value : this.step,
      customerId: data.customerId.present
          ? data.customerId.value
          : this.customerId,
      deliveryMethod: data.deliveryMethod.present
          ? data.deliveryMethod.value
          : this.deliveryMethod,
      receiverKind: data.receiverKind.present
          ? data.receiverKind.value
          : this.receiverKind,
      paymentMethod: data.paymentMethod.present
          ? data.paymentMethod.value
          : this.paymentMethod,
      orderIdempotencyKey: data.orderIdempotencyKey.present
          ? data.orderIdempotencyKey.value
          : this.orderIdempotencyKey,
      submittedAt: data.submittedAt.present
          ? data.submittedAt.value
          : this.submittedAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CheckoutDraftRow(')
          ..write('localCartId: $localCartId, ')
          ..write('step: $step, ')
          ..write('customerId: $customerId, ')
          ..write('deliveryMethod: $deliveryMethod, ')
          ..write('receiverKind: $receiverKind, ')
          ..write('paymentMethod: $paymentMethod, ')
          ..write('orderIdempotencyKey: $orderIdempotencyKey, ')
          ..write('submittedAt: $submittedAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    localCartId,
    step,
    customerId,
    deliveryMethod,
    receiverKind,
    paymentMethod,
    orderIdempotencyKey,
    submittedAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CheckoutDraftRow &&
          other.localCartId == this.localCartId &&
          other.step == this.step &&
          other.customerId == this.customerId &&
          other.deliveryMethod == this.deliveryMethod &&
          other.receiverKind == this.receiverKind &&
          other.paymentMethod == this.paymentMethod &&
          other.orderIdempotencyKey == this.orderIdempotencyKey &&
          other.submittedAt == this.submittedAt &&
          other.updatedAt == this.updatedAt);
}

class CheckoutDraftCompanion extends UpdateCompanion<CheckoutDraftRow> {
  final Value<String> localCartId;
  final Value<String> step;
  final Value<String?> customerId;
  final Value<String?> deliveryMethod;
  final Value<String?> receiverKind;
  final Value<String?> paymentMethod;
  final Value<String?> orderIdempotencyKey;
  final Value<int?> submittedAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const CheckoutDraftCompanion({
    this.localCartId = const Value.absent(),
    this.step = const Value.absent(),
    this.customerId = const Value.absent(),
    this.deliveryMethod = const Value.absent(),
    this.receiverKind = const Value.absent(),
    this.paymentMethod = const Value.absent(),
    this.orderIdempotencyKey = const Value.absent(),
    this.submittedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CheckoutDraftCompanion.insert({
    required String localCartId,
    required String step,
    this.customerId = const Value.absent(),
    this.deliveryMethod = const Value.absent(),
    this.receiverKind = const Value.absent(),
    this.paymentMethod = const Value.absent(),
    this.orderIdempotencyKey = const Value.absent(),
    this.submittedAt = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : localCartId = Value(localCartId),
       step = Value(step),
       updatedAt = Value(updatedAt);
  static Insertable<CheckoutDraftRow> custom({
    Expression<String>? localCartId,
    Expression<String>? step,
    Expression<String>? customerId,
    Expression<String>? deliveryMethod,
    Expression<String>? receiverKind,
    Expression<String>? paymentMethod,
    Expression<String>? orderIdempotencyKey,
    Expression<int>? submittedAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (localCartId != null) 'local_cart_id': localCartId,
      if (step != null) 'step': step,
      if (customerId != null) 'customer_id': customerId,
      if (deliveryMethod != null) 'delivery_method': deliveryMethod,
      if (receiverKind != null) 'receiver_kind': receiverKind,
      if (paymentMethod != null) 'payment_method': paymentMethod,
      if (orderIdempotencyKey != null)
        'order_idempotency_key': orderIdempotencyKey,
      if (submittedAt != null) 'submitted_at': submittedAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CheckoutDraftCompanion copyWith({
    Value<String>? localCartId,
    Value<String>? step,
    Value<String?>? customerId,
    Value<String?>? deliveryMethod,
    Value<String?>? receiverKind,
    Value<String?>? paymentMethod,
    Value<String?>? orderIdempotencyKey,
    Value<int?>? submittedAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return CheckoutDraftCompanion(
      localCartId: localCartId ?? this.localCartId,
      step: step ?? this.step,
      customerId: customerId ?? this.customerId,
      deliveryMethod: deliveryMethod ?? this.deliveryMethod,
      receiverKind: receiverKind ?? this.receiverKind,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      orderIdempotencyKey: orderIdempotencyKey ?? this.orderIdempotencyKey,
      submittedAt: submittedAt ?? this.submittedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localCartId.present) {
      map['local_cart_id'] = Variable<String>(localCartId.value);
    }
    if (step.present) {
      map['step'] = Variable<String>(step.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (deliveryMethod.present) {
      map['delivery_method'] = Variable<String>(deliveryMethod.value);
    }
    if (receiverKind.present) {
      map['receiver_kind'] = Variable<String>(receiverKind.value);
    }
    if (paymentMethod.present) {
      map['payment_method'] = Variable<String>(paymentMethod.value);
    }
    if (orderIdempotencyKey.present) {
      map['order_idempotency_key'] = Variable<String>(
        orderIdempotencyKey.value,
      );
    }
    if (submittedAt.present) {
      map['submitted_at'] = Variable<int>(submittedAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CheckoutDraftCompanion(')
          ..write('localCartId: $localCartId, ')
          ..write('step: $step, ')
          ..write('customerId: $customerId, ')
          ..write('deliveryMethod: $deliveryMethod, ')
          ..write('receiverKind: $receiverKind, ')
          ..write('paymentMethod: $paymentMethod, ')
          ..write('orderIdempotencyKey: $orderIdempotencyKey, ')
          ..write('submittedAt: $submittedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncMetaTable extends SyncMeta
    with TableInfo<$SyncMetaTable, SyncMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _entityMeta = const VerificationMeta('entity');
  @override
  late final GeneratedColumn<String> entity = GeneratedColumn<String>(
    'entity',
    aliasedName,
    false,
    check: () => entity.isIn(syncMetaEntities),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastSuccessAtMeta = const VerificationMeta(
    'lastSuccessAt',
  );
  @override
  late final GeneratedColumn<int> lastSuccessAt = GeneratedColumn<int>(
    'last_success_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverCursorMeta = const VerificationMeta(
    'serverCursor',
  );
  @override
  late final GeneratedColumn<String> serverCursor = GeneratedColumn<String>(
    'server_cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _asOfMeta = const VerificationMeta('asOf');
  @override
  late final GeneratedColumn<int> asOf = GeneratedColumn<int>(
    'as_of',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _staleAfterSecMeta = const VerificationMeta(
    'staleAfterSec',
  );
  @override
  late final GeneratedColumn<int> staleAfterSec = GeneratedColumn<int>(
    'stale_after_sec',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    entity,
    lastSuccessAt,
    serverCursor,
    lastError,
    asOf,
    staleAfterSec,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('entity')) {
      context.handle(
        _entityMeta,
        entity.isAcceptableOrUnknown(data['entity']!, _entityMeta),
      );
    } else if (isInserting) {
      context.missing(_entityMeta);
    }
    if (data.containsKey('last_success_at')) {
      context.handle(
        _lastSuccessAtMeta,
        lastSuccessAt.isAcceptableOrUnknown(
          data['last_success_at']!,
          _lastSuccessAtMeta,
        ),
      );
    }
    if (data.containsKey('server_cursor')) {
      context.handle(
        _serverCursorMeta,
        serverCursor.isAcceptableOrUnknown(
          data['server_cursor']!,
          _serverCursorMeta,
        ),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('as_of')) {
      context.handle(
        _asOfMeta,
        asOf.isAcceptableOrUnknown(data['as_of']!, _asOfMeta),
      );
    }
    if (data.containsKey('stale_after_sec')) {
      context.handle(
        _staleAfterSecMeta,
        staleAfterSec.isAcceptableOrUnknown(
          data['stale_after_sec']!,
          _staleAfterSecMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {entity};
  @override
  SyncMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncMetaRow(
      entity: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity'],
      )!,
      lastSuccessAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_success_at'],
      ),
      serverCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_cursor'],
      ),
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      asOf: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}as_of'],
      ),
      staleAfterSec: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}stale_after_sec'],
      ),
    );
  }

  @override
  $SyncMetaTable createAlias(String alias) {
    return $SyncMetaTable(attachedDatabase, alias);
  }
}

class SyncMetaRow extends DataClass implements Insertable<SyncMetaRow> {
  final String entity;
  final int? lastSuccessAt;
  final String? serverCursor;
  final String? lastError;
  final int? asOf;

  /// Порог устаревания из `GET /sync/status` (`maxAgeWarningSec`, 08 §3.13). Схема v2.
  final int? staleAfterSec;
  const SyncMetaRow({
    required this.entity,
    this.lastSuccessAt,
    this.serverCursor,
    this.lastError,
    this.asOf,
    this.staleAfterSec,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entity'] = Variable<String>(entity);
    if (!nullToAbsent || lastSuccessAt != null) {
      map['last_success_at'] = Variable<int>(lastSuccessAt);
    }
    if (!nullToAbsent || serverCursor != null) {
      map['server_cursor'] = Variable<String>(serverCursor);
    }
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    if (!nullToAbsent || asOf != null) {
      map['as_of'] = Variable<int>(asOf);
    }
    if (!nullToAbsent || staleAfterSec != null) {
      map['stale_after_sec'] = Variable<int>(staleAfterSec);
    }
    return map;
  }

  SyncMetaCompanion toCompanion(bool nullToAbsent) {
    return SyncMetaCompanion(
      entity: Value(entity),
      lastSuccessAt: lastSuccessAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSuccessAt),
      serverCursor: serverCursor == null && nullToAbsent
          ? const Value.absent()
          : Value(serverCursor),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      asOf: asOf == null && nullToAbsent ? const Value.absent() : Value(asOf),
      staleAfterSec: staleAfterSec == null && nullToAbsent
          ? const Value.absent()
          : Value(staleAfterSec),
    );
  }

  factory SyncMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncMetaRow(
      entity: serializer.fromJson<String>(json['entity']),
      lastSuccessAt: serializer.fromJson<int?>(json['lastSuccessAt']),
      serverCursor: serializer.fromJson<String?>(json['serverCursor']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      asOf: serializer.fromJson<int?>(json['asOf']),
      staleAfterSec: serializer.fromJson<int?>(json['staleAfterSec']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entity': serializer.toJson<String>(entity),
      'lastSuccessAt': serializer.toJson<int?>(lastSuccessAt),
      'serverCursor': serializer.toJson<String?>(serverCursor),
      'lastError': serializer.toJson<String?>(lastError),
      'asOf': serializer.toJson<int?>(asOf),
      'staleAfterSec': serializer.toJson<int?>(staleAfterSec),
    };
  }

  SyncMetaRow copyWith({
    String? entity,
    Value<int?> lastSuccessAt = const Value.absent(),
    Value<String?> serverCursor = const Value.absent(),
    Value<String?> lastError = const Value.absent(),
    Value<int?> asOf = const Value.absent(),
    Value<int?> staleAfterSec = const Value.absent(),
  }) => SyncMetaRow(
    entity: entity ?? this.entity,
    lastSuccessAt: lastSuccessAt.present
        ? lastSuccessAt.value
        : this.lastSuccessAt,
    serverCursor: serverCursor.present ? serverCursor.value : this.serverCursor,
    lastError: lastError.present ? lastError.value : this.lastError,
    asOf: asOf.present ? asOf.value : this.asOf,
    staleAfterSec: staleAfterSec.present
        ? staleAfterSec.value
        : this.staleAfterSec,
  );
  SyncMetaRow copyWithCompanion(SyncMetaCompanion data) {
    return SyncMetaRow(
      entity: data.entity.present ? data.entity.value : this.entity,
      lastSuccessAt: data.lastSuccessAt.present
          ? data.lastSuccessAt.value
          : this.lastSuccessAt,
      serverCursor: data.serverCursor.present
          ? data.serverCursor.value
          : this.serverCursor,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      asOf: data.asOf.present ? data.asOf.value : this.asOf,
      staleAfterSec: data.staleAfterSec.present
          ? data.staleAfterSec.value
          : this.staleAfterSec,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetaRow(')
          ..write('entity: $entity, ')
          ..write('lastSuccessAt: $lastSuccessAt, ')
          ..write('serverCursor: $serverCursor, ')
          ..write('lastError: $lastError, ')
          ..write('asOf: $asOf, ')
          ..write('staleAfterSec: $staleAfterSec')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    entity,
    lastSuccessAt,
    serverCursor,
    lastError,
    asOf,
    staleAfterSec,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncMetaRow &&
          other.entity == this.entity &&
          other.lastSuccessAt == this.lastSuccessAt &&
          other.serverCursor == this.serverCursor &&
          other.lastError == this.lastError &&
          other.asOf == this.asOf &&
          other.staleAfterSec == this.staleAfterSec);
}

class SyncMetaCompanion extends UpdateCompanion<SyncMetaRow> {
  final Value<String> entity;
  final Value<int?> lastSuccessAt;
  final Value<String?> serverCursor;
  final Value<String?> lastError;
  final Value<int?> asOf;
  final Value<int?> staleAfterSec;
  final Value<int> rowid;
  const SyncMetaCompanion({
    this.entity = const Value.absent(),
    this.lastSuccessAt = const Value.absent(),
    this.serverCursor = const Value.absent(),
    this.lastError = const Value.absent(),
    this.asOf = const Value.absent(),
    this.staleAfterSec = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncMetaCompanion.insert({
    required String entity,
    this.lastSuccessAt = const Value.absent(),
    this.serverCursor = const Value.absent(),
    this.lastError = const Value.absent(),
    this.asOf = const Value.absent(),
    this.staleAfterSec = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : entity = Value(entity);
  static Insertable<SyncMetaRow> custom({
    Expression<String>? entity,
    Expression<int>? lastSuccessAt,
    Expression<String>? serverCursor,
    Expression<String>? lastError,
    Expression<int>? asOf,
    Expression<int>? staleAfterSec,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (entity != null) 'entity': entity,
      if (lastSuccessAt != null) 'last_success_at': lastSuccessAt,
      if (serverCursor != null) 'server_cursor': serverCursor,
      if (lastError != null) 'last_error': lastError,
      if (asOf != null) 'as_of': asOf,
      if (staleAfterSec != null) 'stale_after_sec': staleAfterSec,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncMetaCompanion copyWith({
    Value<String>? entity,
    Value<int?>? lastSuccessAt,
    Value<String?>? serverCursor,
    Value<String?>? lastError,
    Value<int?>? asOf,
    Value<int?>? staleAfterSec,
    Value<int>? rowid,
  }) {
    return SyncMetaCompanion(
      entity: entity ?? this.entity,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      serverCursor: serverCursor ?? this.serverCursor,
      lastError: lastError ?? this.lastError,
      asOf: asOf ?? this.asOf,
      staleAfterSec: staleAfterSec ?? this.staleAfterSec,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (entity.present) {
      map['entity'] = Variable<String>(entity.value);
    }
    if (lastSuccessAt.present) {
      map['last_success_at'] = Variable<int>(lastSuccessAt.value);
    }
    if (serverCursor.present) {
      map['server_cursor'] = Variable<String>(serverCursor.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (asOf.present) {
      map['as_of'] = Variable<int>(asOf.value);
    }
    if (staleAfterSec.present) {
      map['stale_after_sec'] = Variable<int>(staleAfterSec.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetaCompanion(')
          ..write('entity: $entity, ')
          ..write('lastSuccessAt: $lastSuccessAt, ')
          ..write('serverCursor: $serverCursor, ')
          ..write('lastError: $lastError, ')
          ..write('asOf: $asOf, ')
          ..write('staleAfterSec: $staleAfterSec, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppMetaTable extends AppMeta with TableInfo<$AppMetaTable, AppMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppMetaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AppMetaTable createAlias(String alias) {
    return $AppMetaTable(attachedDatabase, alias);
  }
}

class AppMetaRow extends DataClass implements Insertable<AppMetaRow> {
  final String key;
  final String value;
  const AppMetaRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppMetaCompanion toCompanion(bool nullToAbsent) {
    return AppMetaCompanion(key: Value(key), value: Value(value));
  }

  factory AppMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppMetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppMetaRow copyWith({String? key, String? value}) =>
      AppMetaRow(key: key ?? this.key, value: value ?? this.value);
  AppMetaRow copyWithCompanion(AppMetaCompanion data) {
    return AppMetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppMetaRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppMetaRow &&
          other.key == this.key &&
          other.value == this.value);
}

class AppMetaCompanion extends UpdateCompanion<AppMetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppMetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppMetaCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppMetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppMetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppMetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppMetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $LocalCategoriesTable localCategories = $LocalCategoriesTable(
    this,
  );
  late final $LocalProductsTable localProducts = $LocalProductsTable(this);
  late final $LocalProductVariantsTable localProductVariants =
      $LocalProductVariantsTable(this);
  late final $LocalUnitsTable localUnits = $LocalUnitsTable(this);
  late final $LocalPackagingsTable localPackagings = $LocalPackagingsTable(
    this,
  );
  late final $LocalBarcodesTable localBarcodes = $LocalBarcodesTable(this);
  late final $LocalWarehousesTable localWarehouses = $LocalWarehousesTable(
    this,
  );
  late final $LocalPriceListsTable localPriceLists = $LocalPriceListsTable(
    this,
  );
  late final $LocalPricesTable localPrices = $LocalPricesTable(this);
  late final $LocalStockBalancesTable localStockBalances =
      $LocalStockBalancesTable(this);
  late final $LocalProductImagesMetaTable localProductImagesMeta =
      $LocalProductImagesMetaTable(this);
  late final $LocalFavoritesProductsTable localFavoritesProducts =
      $LocalFavoritesProductsTable(this);
  late final $LocalFavoritesCustomersTable localFavoritesCustomers =
      $LocalFavoritesCustomersTable(this);
  late final $CartDraftTable cartDraft = $CartDraftTable(this);
  late final $CartItemsDraftTable cartItemsDraft = $CartItemsDraftTable(this);
  late final $OutboxActionsTable outboxActions = $OutboxActionsTable(this);
  late final $LocalRecentProductsTable localRecentProducts =
      $LocalRecentProductsTable(this);
  late final $NotificationsCacheTable notificationsCache =
      $NotificationsCacheTable(this);
  late final $LocalSettingsTable localSettings = $LocalSettingsTable(this);
  late final $RegistrationDraftTable registrationDraft =
      $RegistrationDraftTable(this);
  late final $CheckoutDraftTable checkoutDraft = $CheckoutDraftTable(this);
  late final $SyncMetaTable syncMeta = $SyncMetaTable(this);
  late final $AppMetaTable appMeta = $AppMetaTable(this);
  late final Index categoriesParentIdx = Index(
    'categories_parent_idx',
    'CREATE INDEX categories_parent_idx ON categories (parent_id)',
  );
  late final Index categoriesPathIdx = Index(
    'categories_path_idx',
    'CREATE INDEX categories_path_idx ON categories (path)',
  );
  late final Index productsCategoryIdx = Index(
    'products_category_idx',
    'CREATE INDEX products_category_idx ON products (category_id)',
  );
  late final Index productsSkuNormIdx = Index(
    'products_sku_norm_idx',
    'CREATE INDEX products_sku_norm_idx ON products (sku_norm)',
  );
  late final Index productsNameNormIdx = Index(
    'products_name_norm_idx',
    'CREATE INDEX products_name_norm_idx ON products (name_norm)',
  );
  late final Index productVariantsProductIdx = Index(
    'product_variants_product_idx',
    'CREATE INDEX product_variants_product_idx ON product_variants (product_id)',
  );
  late final Index productVariantsSkuNormIdx = Index(
    'product_variants_sku_norm_idx',
    'CREATE INDEX product_variants_sku_norm_idx ON product_variants (sku_norm)',
  );
  late final Index packagingsProductIdx = Index(
    'packagings_product_idx',
    'CREATE INDEX packagings_product_idx ON packagings (product_id)',
  );
  late final Index packagingsVariantIdx = Index(
    'packagings_variant_idx',
    'CREATE INDEX packagings_variant_idx ON packagings (variant_id)',
  );
  late final Index barcodesVariantIdx = Index(
    'barcodes_variant_idx',
    'CREATE INDEX barcodes_variant_idx ON barcodes (variant_id)',
  );
  late final Index barcodesServerIdIdx = Index(
    'barcodes_server_id_idx',
    'CREATE INDEX barcodes_server_id_idx ON barcodes (server_id)',
  );
  late final Index pricesListVariantIdx = Index(
    'prices_list_variant_idx',
    'CREATE INDEX prices_list_variant_idx ON prices (price_list_id, variant_id)',
  );
  late final Index pricesServerIdIdx = Index(
    'prices_server_id_idx',
    'CREATE INDEX prices_server_id_idx ON prices (server_id)',
  );
  late final Index stockBalancesWarehouseAvailableIdx = Index(
    'stock_balances_warehouse_available_idx',
    'CREATE INDEX stock_balances_warehouse_available_idx ON stock_balances (warehouse_id, available_milli)',
  );
  late final Index productImagesMetaProductIdx = Index(
    'product_images_meta_product_idx',
    'CREATE INDEX product_images_meta_product_idx ON product_images_meta (product_id)',
  );
  late final Index productImagesMetaServerIdIdx = Index(
    'product_images_meta_server_id_idx',
    'CREATE INDEX product_images_meta_server_id_idx ON product_images_meta (server_id)',
  );
  late final Index cartDraftStatusIdx = Index(
    'cart_draft_status_idx',
    'CREATE INDEX cart_draft_status_idx ON cart_draft (status)',
  );
  late final Index cartItemsDraftCartIdx = Index(
    'cart_items_draft_cart_idx',
    'CREATE INDEX cart_items_draft_cart_idx ON cart_items_draft (local_cart_id)',
  );
  late final Index outboxActionsOwnerStatusNextIdx = Index(
    'outbox_actions_owner_status_next_idx',
    'CREATE INDEX outbox_actions_owner_status_next_idx ON outbox_actions (owner_user_id, status, next_attempt_at)',
  );
  late final Index recentProductsViewedIdx = Index(
    'recent_products_viewed_idx',
    'CREATE INDEX recent_products_viewed_idx ON recent_products (last_viewed_at)',
  );
  late final Index notificationsCacheReadIdx = Index(
    'notifications_cache_read_idx',
    'CREATE INDEX notifications_cache_read_idx ON notifications_cache (read_at)',
  );
  late final AppMetaDao appMetaDao = AppMetaDao(this as AppDatabase);
  late final CatalogDao catalogDao = CatalogDao(this as AppDatabase);
  late final FavoritesDao favoritesDao = FavoritesDao(this as AppDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    localCategories,
    localProducts,
    localProductVariants,
    localUnits,
    localPackagings,
    localBarcodes,
    localWarehouses,
    localPriceLists,
    localPrices,
    localStockBalances,
    localProductImagesMeta,
    localFavoritesProducts,
    localFavoritesCustomers,
    cartDraft,
    cartItemsDraft,
    outboxActions,
    localRecentProducts,
    notificationsCache,
    localSettings,
    registrationDraft,
    checkoutDraft,
    syncMeta,
    appMeta,
    categoriesParentIdx,
    categoriesPathIdx,
    productsCategoryIdx,
    productsSkuNormIdx,
    productsNameNormIdx,
    productVariantsProductIdx,
    productVariantsSkuNormIdx,
    packagingsProductIdx,
    packagingsVariantIdx,
    barcodesVariantIdx,
    barcodesServerIdIdx,
    pricesListVariantIdx,
    pricesServerIdIdx,
    stockBalancesWarehouseAvailableIdx,
    productImagesMetaProductIdx,
    productImagesMetaServerIdIdx,
    cartDraftStatusIdx,
    cartItemsDraftCartIdx,
    outboxActionsOwnerStatusNextIdx,
    recentProductsViewedIdx,
    notificationsCacheReadIdx,
  ];
}

typedef $$LocalCategoriesTableCreateCompanionBuilder =
    LocalCategoriesCompanion Function({
      required String id,
      Value<String?> parentId,
      required String name,
      required String nameNorm,
      required String path,
      required int depth,
      Value<int> sortOrder,
      Value<String?> iconKey,
      Value<String?> imageSha,
      Value<int> productCount,
      Value<bool> isVisible,
      Value<bool> deletionMark,
      required int serverUpdatedAt,
      Value<int> rowid,
    });
typedef $$LocalCategoriesTableUpdateCompanionBuilder =
    LocalCategoriesCompanion Function({
      Value<String> id,
      Value<String?> parentId,
      Value<String> name,
      Value<String> nameNorm,
      Value<String> path,
      Value<int> depth,
      Value<int> sortOrder,
      Value<String?> iconKey,
      Value<String?> imageSha,
      Value<int> productCount,
      Value<bool> isVisible,
      Value<bool> deletionMark,
      Value<int> serverUpdatedAt,
      Value<int> rowid,
    });

class $$LocalCategoriesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalCategoriesTable> {
  $$LocalCategoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nameNorm => $composableBuilder(
    column: $table.nameNorm,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get depth => $composableBuilder(
    column: $table.depth,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get iconKey => $composableBuilder(
    column: $table.iconKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imageSha => $composableBuilder(
    column: $table.imageSha,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get productCount => $composableBuilder(
    column: $table.productCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isVisible => $composableBuilder(
    column: $table.isVisible,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deletionMark => $composableBuilder(
    column: $table.deletionMark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalCategoriesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalCategoriesTable> {
  $$LocalCategoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nameNorm => $composableBuilder(
    column: $table.nameNorm,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get depth => $composableBuilder(
    column: $table.depth,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get iconKey => $composableBuilder(
    column: $table.iconKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imageSha => $composableBuilder(
    column: $table.imageSha,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get productCount => $composableBuilder(
    column: $table.productCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isVisible => $composableBuilder(
    column: $table.isVisible,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deletionMark => $composableBuilder(
    column: $table.deletionMark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalCategoriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalCategoriesTable> {
  $$LocalCategoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get nameNorm =>
      $composableBuilder(column: $table.nameNorm, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get depth =>
      $composableBuilder(column: $table.depth, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<String> get iconKey =>
      $composableBuilder(column: $table.iconKey, builder: (column) => column);

  GeneratedColumn<String> get imageSha =>
      $composableBuilder(column: $table.imageSha, builder: (column) => column);

  GeneratedColumn<int> get productCount => $composableBuilder(
    column: $table.productCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isVisible =>
      $composableBuilder(column: $table.isVisible, builder: (column) => column);

  GeneratedColumn<bool> get deletionMark => $composableBuilder(
    column: $table.deletionMark,
    builder: (column) => column,
  );

  GeneratedColumn<int> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => column,
  );
}

class $$LocalCategoriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalCategoriesTable,
          CategoryRow,
          $$LocalCategoriesTableFilterComposer,
          $$LocalCategoriesTableOrderingComposer,
          $$LocalCategoriesTableAnnotationComposer,
          $$LocalCategoriesTableCreateCompanionBuilder,
          $$LocalCategoriesTableUpdateCompanionBuilder,
          (
            CategoryRow,
            BaseReferences<_$AppDatabase, $LocalCategoriesTable, CategoryRow>,
          ),
          CategoryRow,
          PrefetchHooks Function()
        > {
  $$LocalCategoriesTableTableManager(
    _$AppDatabase db,
    $LocalCategoriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalCategoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalCategoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalCategoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> nameNorm = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<int> depth = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String?> iconKey = const Value.absent(),
                Value<String?> imageSha = const Value.absent(),
                Value<int> productCount = const Value.absent(),
                Value<bool> isVisible = const Value.absent(),
                Value<bool> deletionMark = const Value.absent(),
                Value<int> serverUpdatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalCategoriesCompanion(
                id: id,
                parentId: parentId,
                name: name,
                nameNorm: nameNorm,
                path: path,
                depth: depth,
                sortOrder: sortOrder,
                iconKey: iconKey,
                imageSha: imageSha,
                productCount: productCount,
                isVisible: isVisible,
                deletionMark: deletionMark,
                serverUpdatedAt: serverUpdatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> parentId = const Value.absent(),
                required String name,
                required String nameNorm,
                required String path,
                required int depth,
                Value<int> sortOrder = const Value.absent(),
                Value<String?> iconKey = const Value.absent(),
                Value<String?> imageSha = const Value.absent(),
                Value<int> productCount = const Value.absent(),
                Value<bool> isVisible = const Value.absent(),
                Value<bool> deletionMark = const Value.absent(),
                required int serverUpdatedAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalCategoriesCompanion.insert(
                id: id,
                parentId: parentId,
                name: name,
                nameNorm: nameNorm,
                path: path,
                depth: depth,
                sortOrder: sortOrder,
                iconKey: iconKey,
                imageSha: imageSha,
                productCount: productCount,
                isVisible: isVisible,
                deletionMark: deletionMark,
                serverUpdatedAt: serverUpdatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalCategoriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalCategoriesTable,
      CategoryRow,
      $$LocalCategoriesTableFilterComposer,
      $$LocalCategoriesTableOrderingComposer,
      $$LocalCategoriesTableAnnotationComposer,
      $$LocalCategoriesTableCreateCompanionBuilder,
      $$LocalCategoriesTableUpdateCompanionBuilder,
      (
        CategoryRow,
        BaseReferences<_$AppDatabase, $LocalCategoriesTable, CategoryRow>,
      ),
      CategoryRow,
      PrefetchHooks Function()
    >;
typedef $$LocalProductsTableCreateCompanionBuilder =
    LocalProductsCompanion Function({
      required String id,
      required String sku,
      required String skuNorm,
      required String name,
      required String nameNorm,
      Value<String?> brand,
      Value<String?> categoryId,
      required String baseUnitCode,
      required int qtyPrecision,
      Value<bool> hasVariants,
      Value<bool> isSellable,
      Value<int?> multiplicityMilli,
      Value<int?> minQtyMilli,
      Value<String?> primaryImageSha,
      Value<String?> attributesJson,
      Value<bool> deletionMark,
      required int serverUpdatedAt,
      Value<String?> defaultVariantId,
      Value<String?> baseUnitId,
      Value<String?> description,
      Value<int> rowid,
    });
typedef $$LocalProductsTableUpdateCompanionBuilder =
    LocalProductsCompanion Function({
      Value<String> id,
      Value<String> sku,
      Value<String> skuNorm,
      Value<String> name,
      Value<String> nameNorm,
      Value<String?> brand,
      Value<String?> categoryId,
      Value<String> baseUnitCode,
      Value<int> qtyPrecision,
      Value<bool> hasVariants,
      Value<bool> isSellable,
      Value<int?> multiplicityMilli,
      Value<int?> minQtyMilli,
      Value<String?> primaryImageSha,
      Value<String?> attributesJson,
      Value<bool> deletionMark,
      Value<int> serverUpdatedAt,
      Value<String?> defaultVariantId,
      Value<String?> baseUnitId,
      Value<String?> description,
      Value<int> rowid,
    });

class $$LocalProductsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalProductsTable> {
  $$LocalProductsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sku => $composableBuilder(
    column: $table.sku,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get skuNorm => $composableBuilder(
    column: $table.skuNorm,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nameNorm => $composableBuilder(
    column: $table.nameNorm,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get brand => $composableBuilder(
    column: $table.brand,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get categoryId => $composableBuilder(
    column: $table.categoryId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseUnitCode => $composableBuilder(
    column: $table.baseUnitCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get qtyPrecision => $composableBuilder(
    column: $table.qtyPrecision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasVariants => $composableBuilder(
    column: $table.hasVariants,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isSellable => $composableBuilder(
    column: $table.isSellable,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get multiplicityMilli => $composableBuilder(
    column: $table.multiplicityMilli,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get minQtyMilli => $composableBuilder(
    column: $table.minQtyMilli,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get primaryImageSha => $composableBuilder(
    column: $table.primaryImageSha,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attributesJson => $composableBuilder(
    column: $table.attributesJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deletionMark => $composableBuilder(
    column: $table.deletionMark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get defaultVariantId => $composableBuilder(
    column: $table.defaultVariantId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseUnitId => $composableBuilder(
    column: $table.baseUnitId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalProductsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalProductsTable> {
  $$LocalProductsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sku => $composableBuilder(
    column: $table.sku,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get skuNorm => $composableBuilder(
    column: $table.skuNorm,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nameNorm => $composableBuilder(
    column: $table.nameNorm,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get brand => $composableBuilder(
    column: $table.brand,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get categoryId => $composableBuilder(
    column: $table.categoryId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseUnitCode => $composableBuilder(
    column: $table.baseUnitCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get qtyPrecision => $composableBuilder(
    column: $table.qtyPrecision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasVariants => $composableBuilder(
    column: $table.hasVariants,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isSellable => $composableBuilder(
    column: $table.isSellable,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get multiplicityMilli => $composableBuilder(
    column: $table.multiplicityMilli,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get minQtyMilli => $composableBuilder(
    column: $table.minQtyMilli,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get primaryImageSha => $composableBuilder(
    column: $table.primaryImageSha,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attributesJson => $composableBuilder(
    column: $table.attributesJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deletionMark => $composableBuilder(
    column: $table.deletionMark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get defaultVariantId => $composableBuilder(
    column: $table.defaultVariantId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseUnitId => $composableBuilder(
    column: $table.baseUnitId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalProductsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalProductsTable> {
  $$LocalProductsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sku =>
      $composableBuilder(column: $table.sku, builder: (column) => column);

  GeneratedColumn<String> get skuNorm =>
      $composableBuilder(column: $table.skuNorm, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get nameNorm =>
      $composableBuilder(column: $table.nameNorm, builder: (column) => column);

  GeneratedColumn<String> get brand =>
      $composableBuilder(column: $table.brand, builder: (column) => column);

  GeneratedColumn<String> get categoryId => $composableBuilder(
    column: $table.categoryId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseUnitCode => $composableBuilder(
    column: $table.baseUnitCode,
    builder: (column) => column,
  );

  GeneratedColumn<int> get qtyPrecision => $composableBuilder(
    column: $table.qtyPrecision,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get hasVariants => $composableBuilder(
    column: $table.hasVariants,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isSellable => $composableBuilder(
    column: $table.isSellable,
    builder: (column) => column,
  );

  GeneratedColumn<int> get multiplicityMilli => $composableBuilder(
    column: $table.multiplicityMilli,
    builder: (column) => column,
  );

  GeneratedColumn<int> get minQtyMilli => $composableBuilder(
    column: $table.minQtyMilli,
    builder: (column) => column,
  );

  GeneratedColumn<String> get primaryImageSha => $composableBuilder(
    column: $table.primaryImageSha,
    builder: (column) => column,
  );

  GeneratedColumn<String> get attributesJson => $composableBuilder(
    column: $table.attributesJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deletionMark => $composableBuilder(
    column: $table.deletionMark,
    builder: (column) => column,
  );

  GeneratedColumn<int> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get defaultVariantId => $composableBuilder(
    column: $table.defaultVariantId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseUnitId => $composableBuilder(
    column: $table.baseUnitId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );
}

class $$LocalProductsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalProductsTable,
          ProductRow,
          $$LocalProductsTableFilterComposer,
          $$LocalProductsTableOrderingComposer,
          $$LocalProductsTableAnnotationComposer,
          $$LocalProductsTableCreateCompanionBuilder,
          $$LocalProductsTableUpdateCompanionBuilder,
          (
            ProductRow,
            BaseReferences<_$AppDatabase, $LocalProductsTable, ProductRow>,
          ),
          ProductRow,
          PrefetchHooks Function()
        > {
  $$LocalProductsTableTableManager(_$AppDatabase db, $LocalProductsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalProductsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalProductsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalProductsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> sku = const Value.absent(),
                Value<String> skuNorm = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> nameNorm = const Value.absent(),
                Value<String?> brand = const Value.absent(),
                Value<String?> categoryId = const Value.absent(),
                Value<String> baseUnitCode = const Value.absent(),
                Value<int> qtyPrecision = const Value.absent(),
                Value<bool> hasVariants = const Value.absent(),
                Value<bool> isSellable = const Value.absent(),
                Value<int?> multiplicityMilli = const Value.absent(),
                Value<int?> minQtyMilli = const Value.absent(),
                Value<String?> primaryImageSha = const Value.absent(),
                Value<String?> attributesJson = const Value.absent(),
                Value<bool> deletionMark = const Value.absent(),
                Value<int> serverUpdatedAt = const Value.absent(),
                Value<String?> defaultVariantId = const Value.absent(),
                Value<String?> baseUnitId = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalProductsCompanion(
                id: id,
                sku: sku,
                skuNorm: skuNorm,
                name: name,
                nameNorm: nameNorm,
                brand: brand,
                categoryId: categoryId,
                baseUnitCode: baseUnitCode,
                qtyPrecision: qtyPrecision,
                hasVariants: hasVariants,
                isSellable: isSellable,
                multiplicityMilli: multiplicityMilli,
                minQtyMilli: minQtyMilli,
                primaryImageSha: primaryImageSha,
                attributesJson: attributesJson,
                deletionMark: deletionMark,
                serverUpdatedAt: serverUpdatedAt,
                defaultVariantId: defaultVariantId,
                baseUnitId: baseUnitId,
                description: description,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String sku,
                required String skuNorm,
                required String name,
                required String nameNorm,
                Value<String?> brand = const Value.absent(),
                Value<String?> categoryId = const Value.absent(),
                required String baseUnitCode,
                required int qtyPrecision,
                Value<bool> hasVariants = const Value.absent(),
                Value<bool> isSellable = const Value.absent(),
                Value<int?> multiplicityMilli = const Value.absent(),
                Value<int?> minQtyMilli = const Value.absent(),
                Value<String?> primaryImageSha = const Value.absent(),
                Value<String?> attributesJson = const Value.absent(),
                Value<bool> deletionMark = const Value.absent(),
                required int serverUpdatedAt,
                Value<String?> defaultVariantId = const Value.absent(),
                Value<String?> baseUnitId = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalProductsCompanion.insert(
                id: id,
                sku: sku,
                skuNorm: skuNorm,
                name: name,
                nameNorm: nameNorm,
                brand: brand,
                categoryId: categoryId,
                baseUnitCode: baseUnitCode,
                qtyPrecision: qtyPrecision,
                hasVariants: hasVariants,
                isSellable: isSellable,
                multiplicityMilli: multiplicityMilli,
                minQtyMilli: minQtyMilli,
                primaryImageSha: primaryImageSha,
                attributesJson: attributesJson,
                deletionMark: deletionMark,
                serverUpdatedAt: serverUpdatedAt,
                defaultVariantId: defaultVariantId,
                baseUnitId: baseUnitId,
                description: description,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalProductsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalProductsTable,
      ProductRow,
      $$LocalProductsTableFilterComposer,
      $$LocalProductsTableOrderingComposer,
      $$LocalProductsTableAnnotationComposer,
      $$LocalProductsTableCreateCompanionBuilder,
      $$LocalProductsTableUpdateCompanionBuilder,
      (
        ProductRow,
        BaseReferences<_$AppDatabase, $LocalProductsTable, ProductRow>,
      ),
      ProductRow,
      PrefetchHooks Function()
    >;
typedef $$LocalProductVariantsTableCreateCompanionBuilder =
    LocalProductVariantsCompanion Function({
      required String id,
      required String productId,
      Value<bool> isDefault,
      required String name,
      Value<String?> sku,
      Value<String?> skuNorm,
      Value<String?> attributesJson,
      Value<int> sortOrder,
      Value<String?> imageSha,
      Value<bool> deletionMark,
      required int serverUpdatedAt,
      Value<int?> multiplicityMilli,
      Value<String?> unitId,
      Value<int> rowid,
    });
typedef $$LocalProductVariantsTableUpdateCompanionBuilder =
    LocalProductVariantsCompanion Function({
      Value<String> id,
      Value<String> productId,
      Value<bool> isDefault,
      Value<String> name,
      Value<String?> sku,
      Value<String?> skuNorm,
      Value<String?> attributesJson,
      Value<int> sortOrder,
      Value<String?> imageSha,
      Value<bool> deletionMark,
      Value<int> serverUpdatedAt,
      Value<int?> multiplicityMilli,
      Value<String?> unitId,
      Value<int> rowid,
    });

class $$LocalProductVariantsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalProductVariantsTable> {
  $$LocalProductVariantsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sku => $composableBuilder(
    column: $table.sku,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get skuNorm => $composableBuilder(
    column: $table.skuNorm,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attributesJson => $composableBuilder(
    column: $table.attributesJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imageSha => $composableBuilder(
    column: $table.imageSha,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deletionMark => $composableBuilder(
    column: $table.deletionMark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get multiplicityMilli => $composableBuilder(
    column: $table.multiplicityMilli,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get unitId => $composableBuilder(
    column: $table.unitId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalProductVariantsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalProductVariantsTable> {
  $$LocalProductVariantsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sku => $composableBuilder(
    column: $table.sku,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get skuNorm => $composableBuilder(
    column: $table.skuNorm,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attributesJson => $composableBuilder(
    column: $table.attributesJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imageSha => $composableBuilder(
    column: $table.imageSha,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deletionMark => $composableBuilder(
    column: $table.deletionMark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get multiplicityMilli => $composableBuilder(
    column: $table.multiplicityMilli,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get unitId => $composableBuilder(
    column: $table.unitId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalProductVariantsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalProductVariantsTable> {
  $$LocalProductVariantsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<bool> get isDefault =>
      $composableBuilder(column: $table.isDefault, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get sku =>
      $composableBuilder(column: $table.sku, builder: (column) => column);

  GeneratedColumn<String> get skuNorm =>
      $composableBuilder(column: $table.skuNorm, builder: (column) => column);

  GeneratedColumn<String> get attributesJson => $composableBuilder(
    column: $table.attributesJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<String> get imageSha =>
      $composableBuilder(column: $table.imageSha, builder: (column) => column);

  GeneratedColumn<bool> get deletionMark => $composableBuilder(
    column: $table.deletionMark,
    builder: (column) => column,
  );

  GeneratedColumn<int> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get multiplicityMilli => $composableBuilder(
    column: $table.multiplicityMilli,
    builder: (column) => column,
  );

  GeneratedColumn<String> get unitId =>
      $composableBuilder(column: $table.unitId, builder: (column) => column);
}

class $$LocalProductVariantsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalProductVariantsTable,
          ProductVariantRow,
          $$LocalProductVariantsTableFilterComposer,
          $$LocalProductVariantsTableOrderingComposer,
          $$LocalProductVariantsTableAnnotationComposer,
          $$LocalProductVariantsTableCreateCompanionBuilder,
          $$LocalProductVariantsTableUpdateCompanionBuilder,
          (
            ProductVariantRow,
            BaseReferences<
              _$AppDatabase,
              $LocalProductVariantsTable,
              ProductVariantRow
            >,
          ),
          ProductVariantRow,
          PrefetchHooks Function()
        > {
  $$LocalProductVariantsTableTableManager(
    _$AppDatabase db,
    $LocalProductVariantsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalProductVariantsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalProductVariantsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LocalProductVariantsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> productId = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> sku = const Value.absent(),
                Value<String?> skuNorm = const Value.absent(),
                Value<String?> attributesJson = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String?> imageSha = const Value.absent(),
                Value<bool> deletionMark = const Value.absent(),
                Value<int> serverUpdatedAt = const Value.absent(),
                Value<int?> multiplicityMilli = const Value.absent(),
                Value<String?> unitId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalProductVariantsCompanion(
                id: id,
                productId: productId,
                isDefault: isDefault,
                name: name,
                sku: sku,
                skuNorm: skuNorm,
                attributesJson: attributesJson,
                sortOrder: sortOrder,
                imageSha: imageSha,
                deletionMark: deletionMark,
                serverUpdatedAt: serverUpdatedAt,
                multiplicityMilli: multiplicityMilli,
                unitId: unitId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String productId,
                Value<bool> isDefault = const Value.absent(),
                required String name,
                Value<String?> sku = const Value.absent(),
                Value<String?> skuNorm = const Value.absent(),
                Value<String?> attributesJson = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String?> imageSha = const Value.absent(),
                Value<bool> deletionMark = const Value.absent(),
                required int serverUpdatedAt,
                Value<int?> multiplicityMilli = const Value.absent(),
                Value<String?> unitId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalProductVariantsCompanion.insert(
                id: id,
                productId: productId,
                isDefault: isDefault,
                name: name,
                sku: sku,
                skuNorm: skuNorm,
                attributesJson: attributesJson,
                sortOrder: sortOrder,
                imageSha: imageSha,
                deletionMark: deletionMark,
                serverUpdatedAt: serverUpdatedAt,
                multiplicityMilli: multiplicityMilli,
                unitId: unitId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalProductVariantsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalProductVariantsTable,
      ProductVariantRow,
      $$LocalProductVariantsTableFilterComposer,
      $$LocalProductVariantsTableOrderingComposer,
      $$LocalProductVariantsTableAnnotationComposer,
      $$LocalProductVariantsTableCreateCompanionBuilder,
      $$LocalProductVariantsTableUpdateCompanionBuilder,
      (
        ProductVariantRow,
        BaseReferences<
          _$AppDatabase,
          $LocalProductVariantsTable,
          ProductVariantRow
        >,
      ),
      ProductVariantRow,
      PrefetchHooks Function()
    >;
typedef $$LocalUnitsTableCreateCompanionBuilder =
    LocalUnitsCompanion Function({
      required String code,
      required String name,
      required int qtyPrecision,
      Value<String?> id,
      Value<String?> shortName,
      Value<int> rowid,
    });
typedef $$LocalUnitsTableUpdateCompanionBuilder =
    LocalUnitsCompanion Function({
      Value<String> code,
      Value<String> name,
      Value<int> qtyPrecision,
      Value<String?> id,
      Value<String?> shortName,
      Value<int> rowid,
    });

class $$LocalUnitsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalUnitsTable> {
  $$LocalUnitsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get qtyPrecision => $composableBuilder(
    column: $table.qtyPrecision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get shortName => $composableBuilder(
    column: $table.shortName,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalUnitsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalUnitsTable> {
  $$LocalUnitsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get qtyPrecision => $composableBuilder(
    column: $table.qtyPrecision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get shortName => $composableBuilder(
    column: $table.shortName,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalUnitsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalUnitsTable> {
  $$LocalUnitsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get code =>
      $composableBuilder(column: $table.code, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get qtyPrecision => $composableBuilder(
    column: $table.qtyPrecision,
    builder: (column) => column,
  );

  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get shortName =>
      $composableBuilder(column: $table.shortName, builder: (column) => column);
}

class $$LocalUnitsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalUnitsTable,
          UnitRow,
          $$LocalUnitsTableFilterComposer,
          $$LocalUnitsTableOrderingComposer,
          $$LocalUnitsTableAnnotationComposer,
          $$LocalUnitsTableCreateCompanionBuilder,
          $$LocalUnitsTableUpdateCompanionBuilder,
          (UnitRow, BaseReferences<_$AppDatabase, $LocalUnitsTable, UnitRow>),
          UnitRow,
          PrefetchHooks Function()
        > {
  $$LocalUnitsTableTableManager(_$AppDatabase db, $LocalUnitsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalUnitsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalUnitsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalUnitsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> code = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> qtyPrecision = const Value.absent(),
                Value<String?> id = const Value.absent(),
                Value<String?> shortName = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalUnitsCompanion(
                code: code,
                name: name,
                qtyPrecision: qtyPrecision,
                id: id,
                shortName: shortName,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String code,
                required String name,
                required int qtyPrecision,
                Value<String?> id = const Value.absent(),
                Value<String?> shortName = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalUnitsCompanion.insert(
                code: code,
                name: name,
                qtyPrecision: qtyPrecision,
                id: id,
                shortName: shortName,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalUnitsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalUnitsTable,
      UnitRow,
      $$LocalUnitsTableFilterComposer,
      $$LocalUnitsTableOrderingComposer,
      $$LocalUnitsTableAnnotationComposer,
      $$LocalUnitsTableCreateCompanionBuilder,
      $$LocalUnitsTableUpdateCompanionBuilder,
      (UnitRow, BaseReferences<_$AppDatabase, $LocalUnitsTable, UnitRow>),
      UnitRow,
      PrefetchHooks Function()
    >;
typedef $$LocalPackagingsTableCreateCompanionBuilder =
    LocalPackagingsCompanion Function({
      required String id,
      required String productId,
      required String unitCode,
      required String name,
      required int factorMilli,
      Value<bool> allowFraction,
      Value<bool> isDefault,
      Value<String?> variantId,
      Value<String?> unitId,
      Value<int> rowid,
    });
typedef $$LocalPackagingsTableUpdateCompanionBuilder =
    LocalPackagingsCompanion Function({
      Value<String> id,
      Value<String> productId,
      Value<String> unitCode,
      Value<String> name,
      Value<int> factorMilli,
      Value<bool> allowFraction,
      Value<bool> isDefault,
      Value<String?> variantId,
      Value<String?> unitId,
      Value<int> rowid,
    });

class $$LocalPackagingsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalPackagingsTable> {
  $$LocalPackagingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get unitCode => $composableBuilder(
    column: $table.unitCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get factorMilli => $composableBuilder(
    column: $table.factorMilli,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get allowFraction => $composableBuilder(
    column: $table.allowFraction,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get unitId => $composableBuilder(
    column: $table.unitId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalPackagingsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalPackagingsTable> {
  $$LocalPackagingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get unitCode => $composableBuilder(
    column: $table.unitCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get factorMilli => $composableBuilder(
    column: $table.factorMilli,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get allowFraction => $composableBuilder(
    column: $table.allowFraction,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get unitId => $composableBuilder(
    column: $table.unitId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalPackagingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalPackagingsTable> {
  $$LocalPackagingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<String> get unitCode =>
      $composableBuilder(column: $table.unitCode, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get factorMilli => $composableBuilder(
    column: $table.factorMilli,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get allowFraction => $composableBuilder(
    column: $table.allowFraction,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isDefault =>
      $composableBuilder(column: $table.isDefault, builder: (column) => column);

  GeneratedColumn<String> get variantId =>
      $composableBuilder(column: $table.variantId, builder: (column) => column);

  GeneratedColumn<String> get unitId =>
      $composableBuilder(column: $table.unitId, builder: (column) => column);
}

class $$LocalPackagingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalPackagingsTable,
          PackagingRow,
          $$LocalPackagingsTableFilterComposer,
          $$LocalPackagingsTableOrderingComposer,
          $$LocalPackagingsTableAnnotationComposer,
          $$LocalPackagingsTableCreateCompanionBuilder,
          $$LocalPackagingsTableUpdateCompanionBuilder,
          (
            PackagingRow,
            BaseReferences<_$AppDatabase, $LocalPackagingsTable, PackagingRow>,
          ),
          PackagingRow,
          PrefetchHooks Function()
        > {
  $$LocalPackagingsTableTableManager(
    _$AppDatabase db,
    $LocalPackagingsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalPackagingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalPackagingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalPackagingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> productId = const Value.absent(),
                Value<String> unitCode = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> factorMilli = const Value.absent(),
                Value<bool> allowFraction = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<String?> variantId = const Value.absent(),
                Value<String?> unitId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalPackagingsCompanion(
                id: id,
                productId: productId,
                unitCode: unitCode,
                name: name,
                factorMilli: factorMilli,
                allowFraction: allowFraction,
                isDefault: isDefault,
                variantId: variantId,
                unitId: unitId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String productId,
                required String unitCode,
                required String name,
                required int factorMilli,
                Value<bool> allowFraction = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<String?> variantId = const Value.absent(),
                Value<String?> unitId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalPackagingsCompanion.insert(
                id: id,
                productId: productId,
                unitCode: unitCode,
                name: name,
                factorMilli: factorMilli,
                allowFraction: allowFraction,
                isDefault: isDefault,
                variantId: variantId,
                unitId: unitId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalPackagingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalPackagingsTable,
      PackagingRow,
      $$LocalPackagingsTableFilterComposer,
      $$LocalPackagingsTableOrderingComposer,
      $$LocalPackagingsTableAnnotationComposer,
      $$LocalPackagingsTableCreateCompanionBuilder,
      $$LocalPackagingsTableUpdateCompanionBuilder,
      (
        PackagingRow,
        BaseReferences<_$AppDatabase, $LocalPackagingsTable, PackagingRow>,
      ),
      PackagingRow,
      PrefetchHooks Function()
    >;
typedef $$LocalBarcodesTableCreateCompanionBuilder =
    LocalBarcodesCompanion Function({
      required String value,
      required String productId,
      Value<String?> variantId,
      Value<String?> packagingId,
      Value<String?> barcodeType,
      Value<String?> serverId,
      Value<int> rowid,
    });
typedef $$LocalBarcodesTableUpdateCompanionBuilder =
    LocalBarcodesCompanion Function({
      Value<String> value,
      Value<String> productId,
      Value<String?> variantId,
      Value<String?> packagingId,
      Value<String?> barcodeType,
      Value<String?> serverId,
      Value<int> rowid,
    });

class $$LocalBarcodesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalBarcodesTable> {
  $$LocalBarcodesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get packagingId => $composableBuilder(
    column: $table.packagingId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get barcodeType => $composableBuilder(
    column: $table.barcodeType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalBarcodesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalBarcodesTable> {
  $$LocalBarcodesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get packagingId => $composableBuilder(
    column: $table.packagingId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get barcodeType => $composableBuilder(
    column: $table.barcodeType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalBarcodesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalBarcodesTable> {
  $$LocalBarcodesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<String> get variantId =>
      $composableBuilder(column: $table.variantId, builder: (column) => column);

  GeneratedColumn<String> get packagingId => $composableBuilder(
    column: $table.packagingId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get barcodeType => $composableBuilder(
    column: $table.barcodeType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);
}

class $$LocalBarcodesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalBarcodesTable,
          BarcodeRow,
          $$LocalBarcodesTableFilterComposer,
          $$LocalBarcodesTableOrderingComposer,
          $$LocalBarcodesTableAnnotationComposer,
          $$LocalBarcodesTableCreateCompanionBuilder,
          $$LocalBarcodesTableUpdateCompanionBuilder,
          (
            BarcodeRow,
            BaseReferences<_$AppDatabase, $LocalBarcodesTable, BarcodeRow>,
          ),
          BarcodeRow,
          PrefetchHooks Function()
        > {
  $$LocalBarcodesTableTableManager(_$AppDatabase db, $LocalBarcodesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalBarcodesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalBarcodesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalBarcodesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> value = const Value.absent(),
                Value<String> productId = const Value.absent(),
                Value<String?> variantId = const Value.absent(),
                Value<String?> packagingId = const Value.absent(),
                Value<String?> barcodeType = const Value.absent(),
                Value<String?> serverId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalBarcodesCompanion(
                value: value,
                productId: productId,
                variantId: variantId,
                packagingId: packagingId,
                barcodeType: barcodeType,
                serverId: serverId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String value,
                required String productId,
                Value<String?> variantId = const Value.absent(),
                Value<String?> packagingId = const Value.absent(),
                Value<String?> barcodeType = const Value.absent(),
                Value<String?> serverId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalBarcodesCompanion.insert(
                value: value,
                productId: productId,
                variantId: variantId,
                packagingId: packagingId,
                barcodeType: barcodeType,
                serverId: serverId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalBarcodesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalBarcodesTable,
      BarcodeRow,
      $$LocalBarcodesTableFilterComposer,
      $$LocalBarcodesTableOrderingComposer,
      $$LocalBarcodesTableAnnotationComposer,
      $$LocalBarcodesTableCreateCompanionBuilder,
      $$LocalBarcodesTableUpdateCompanionBuilder,
      (
        BarcodeRow,
        BaseReferences<_$AppDatabase, $LocalBarcodesTable, BarcodeRow>,
      ),
      BarcodeRow,
      PrefetchHooks Function()
    >;
typedef $$LocalWarehousesTableCreateCompanionBuilder =
    LocalWarehousesCompanion Function({
      required String id,
      required String name,
      Value<String?> shortName,
      Value<bool> isDefault,
      Value<bool> isActive,
      Value<int> rowid,
    });
typedef $$LocalWarehousesTableUpdateCompanionBuilder =
    LocalWarehousesCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String?> shortName,
      Value<bool> isDefault,
      Value<bool> isActive,
      Value<int> rowid,
    });

class $$LocalWarehousesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalWarehousesTable> {
  $$LocalWarehousesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get shortName => $composableBuilder(
    column: $table.shortName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalWarehousesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalWarehousesTable> {
  $$LocalWarehousesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get shortName => $composableBuilder(
    column: $table.shortName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalWarehousesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalWarehousesTable> {
  $$LocalWarehousesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get shortName =>
      $composableBuilder(column: $table.shortName, builder: (column) => column);

  GeneratedColumn<bool> get isDefault =>
      $composableBuilder(column: $table.isDefault, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);
}

class $$LocalWarehousesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalWarehousesTable,
          WarehouseRow,
          $$LocalWarehousesTableFilterComposer,
          $$LocalWarehousesTableOrderingComposer,
          $$LocalWarehousesTableAnnotationComposer,
          $$LocalWarehousesTableCreateCompanionBuilder,
          $$LocalWarehousesTableUpdateCompanionBuilder,
          (
            WarehouseRow,
            BaseReferences<_$AppDatabase, $LocalWarehousesTable, WarehouseRow>,
          ),
          WarehouseRow,
          PrefetchHooks Function()
        > {
  $$LocalWarehousesTableTableManager(
    _$AppDatabase db,
    $LocalWarehousesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalWarehousesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalWarehousesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalWarehousesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> shortName = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalWarehousesCompanion(
                id: id,
                name: name,
                shortName: shortName,
                isDefault: isDefault,
                isActive: isActive,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<String?> shortName = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalWarehousesCompanion.insert(
                id: id,
                name: name,
                shortName: shortName,
                isDefault: isDefault,
                isActive: isActive,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalWarehousesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalWarehousesTable,
      WarehouseRow,
      $$LocalWarehousesTableFilterComposer,
      $$LocalWarehousesTableOrderingComposer,
      $$LocalWarehousesTableAnnotationComposer,
      $$LocalWarehousesTableCreateCompanionBuilder,
      $$LocalWarehousesTableUpdateCompanionBuilder,
      (
        WarehouseRow,
        BaseReferences<_$AppDatabase, $LocalWarehousesTable, WarehouseRow>,
      ),
      WarehouseRow,
      PrefetchHooks Function()
    >;
typedef $$LocalPriceListsTableCreateCompanionBuilder =
    LocalPriceListsCompanion Function({
      required String id,
      required String name,
      Value<bool> isDefault,
      Value<bool> visible,
      Value<int> rowid,
    });
typedef $$LocalPriceListsTableUpdateCompanionBuilder =
    LocalPriceListsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<bool> isDefault,
      Value<bool> visible,
      Value<int> rowid,
    });

class $$LocalPriceListsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalPriceListsTable> {
  $$LocalPriceListsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get visible => $composableBuilder(
    column: $table.visible,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalPriceListsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalPriceListsTable> {
  $$LocalPriceListsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get visible => $composableBuilder(
    column: $table.visible,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalPriceListsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalPriceListsTable> {
  $$LocalPriceListsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<bool> get isDefault =>
      $composableBuilder(column: $table.isDefault, builder: (column) => column);

  GeneratedColumn<bool> get visible =>
      $composableBuilder(column: $table.visible, builder: (column) => column);
}

class $$LocalPriceListsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalPriceListsTable,
          PriceListRow,
          $$LocalPriceListsTableFilterComposer,
          $$LocalPriceListsTableOrderingComposer,
          $$LocalPriceListsTableAnnotationComposer,
          $$LocalPriceListsTableCreateCompanionBuilder,
          $$LocalPriceListsTableUpdateCompanionBuilder,
          (
            PriceListRow,
            BaseReferences<_$AppDatabase, $LocalPriceListsTable, PriceListRow>,
          ),
          PriceListRow,
          PrefetchHooks Function()
        > {
  $$LocalPriceListsTableTableManager(
    _$AppDatabase db,
    $LocalPriceListsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalPriceListsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalPriceListsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalPriceListsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<bool> visible = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalPriceListsCompanion(
                id: id,
                name: name,
                isDefault: isDefault,
                visible: visible,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<bool> isDefault = const Value.absent(),
                Value<bool> visible = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalPriceListsCompanion.insert(
                id: id,
                name: name,
                isDefault: isDefault,
                visible: visible,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalPriceListsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalPriceListsTable,
      PriceListRow,
      $$LocalPriceListsTableFilterComposer,
      $$LocalPriceListsTableOrderingComposer,
      $$LocalPriceListsTableAnnotationComposer,
      $$LocalPriceListsTableCreateCompanionBuilder,
      $$LocalPriceListsTableUpdateCompanionBuilder,
      (
        PriceListRow,
        BaseReferences<_$AppDatabase, $LocalPriceListsTable, PriceListRow>,
      ),
      PriceListRow,
      PrefetchHooks Function()
    >;
typedef $$LocalPricesTableCreateCompanionBuilder =
    LocalPricesCompanion Function({
      required String variantId,
      required String priceListId,
      Value<String?> packagingId,
      required int priceTyiyn,
      required int serverSyncedAt,
      Value<String?> serverId,
      Value<int> rowid,
    });
typedef $$LocalPricesTableUpdateCompanionBuilder =
    LocalPricesCompanion Function({
      Value<String> variantId,
      Value<String> priceListId,
      Value<String?> packagingId,
      Value<int> priceTyiyn,
      Value<int> serverSyncedAt,
      Value<String?> serverId,
      Value<int> rowid,
    });

class $$LocalPricesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalPricesTable> {
  $$LocalPricesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get priceListId => $composableBuilder(
    column: $table.priceListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get packagingId => $composableBuilder(
    column: $table.packagingId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get priceTyiyn => $composableBuilder(
    column: $table.priceTyiyn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverSyncedAt => $composableBuilder(
    column: $table.serverSyncedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalPricesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalPricesTable> {
  $$LocalPricesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get priceListId => $composableBuilder(
    column: $table.priceListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get packagingId => $composableBuilder(
    column: $table.packagingId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get priceTyiyn => $composableBuilder(
    column: $table.priceTyiyn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverSyncedAt => $composableBuilder(
    column: $table.serverSyncedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalPricesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalPricesTable> {
  $$LocalPricesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get variantId =>
      $composableBuilder(column: $table.variantId, builder: (column) => column);

  GeneratedColumn<String> get priceListId => $composableBuilder(
    column: $table.priceListId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get packagingId => $composableBuilder(
    column: $table.packagingId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get priceTyiyn => $composableBuilder(
    column: $table.priceTyiyn,
    builder: (column) => column,
  );

  GeneratedColumn<int> get serverSyncedAt => $composableBuilder(
    column: $table.serverSyncedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);
}

class $$LocalPricesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalPricesTable,
          PriceRow,
          $$LocalPricesTableFilterComposer,
          $$LocalPricesTableOrderingComposer,
          $$LocalPricesTableAnnotationComposer,
          $$LocalPricesTableCreateCompanionBuilder,
          $$LocalPricesTableUpdateCompanionBuilder,
          (
            PriceRow,
            BaseReferences<_$AppDatabase, $LocalPricesTable, PriceRow>,
          ),
          PriceRow,
          PrefetchHooks Function()
        > {
  $$LocalPricesTableTableManager(_$AppDatabase db, $LocalPricesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalPricesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalPricesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalPricesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> variantId = const Value.absent(),
                Value<String> priceListId = const Value.absent(),
                Value<String?> packagingId = const Value.absent(),
                Value<int> priceTyiyn = const Value.absent(),
                Value<int> serverSyncedAt = const Value.absent(),
                Value<String?> serverId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalPricesCompanion(
                variantId: variantId,
                priceListId: priceListId,
                packagingId: packagingId,
                priceTyiyn: priceTyiyn,
                serverSyncedAt: serverSyncedAt,
                serverId: serverId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String variantId,
                required String priceListId,
                Value<String?> packagingId = const Value.absent(),
                required int priceTyiyn,
                required int serverSyncedAt,
                Value<String?> serverId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalPricesCompanion.insert(
                variantId: variantId,
                priceListId: priceListId,
                packagingId: packagingId,
                priceTyiyn: priceTyiyn,
                serverSyncedAt: serverSyncedAt,
                serverId: serverId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalPricesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalPricesTable,
      PriceRow,
      $$LocalPricesTableFilterComposer,
      $$LocalPricesTableOrderingComposer,
      $$LocalPricesTableAnnotationComposer,
      $$LocalPricesTableCreateCompanionBuilder,
      $$LocalPricesTableUpdateCompanionBuilder,
      (PriceRow, BaseReferences<_$AppDatabase, $LocalPricesTable, PriceRow>),
      PriceRow,
      PrefetchHooks Function()
    >;
typedef $$LocalStockBalancesTableCreateCompanionBuilder =
    LocalStockBalancesCompanion Function({
      required String variantId,
      required String warehouseId,
      Value<int?> quantityMilli,
      Value<int?> reservedMilli,
      Value<int?> availableMilli,
      Value<String> stockLevel,
      required int snapshotAt,
      Value<int> rowid,
    });
typedef $$LocalStockBalancesTableUpdateCompanionBuilder =
    LocalStockBalancesCompanion Function({
      Value<String> variantId,
      Value<String> warehouseId,
      Value<int?> quantityMilli,
      Value<int?> reservedMilli,
      Value<int?> availableMilli,
      Value<String> stockLevel,
      Value<int> snapshotAt,
      Value<int> rowid,
    });

class $$LocalStockBalancesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalStockBalancesTable> {
  $$LocalStockBalancesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get quantityMilli => $composableBuilder(
    column: $table.quantityMilli,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reservedMilli => $composableBuilder(
    column: $table.reservedMilli,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get availableMilli => $composableBuilder(
    column: $table.availableMilli,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stockLevel => $composableBuilder(
    column: $table.stockLevel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get snapshotAt => $composableBuilder(
    column: $table.snapshotAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalStockBalancesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalStockBalancesTable> {
  $$LocalStockBalancesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get quantityMilli => $composableBuilder(
    column: $table.quantityMilli,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reservedMilli => $composableBuilder(
    column: $table.reservedMilli,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get availableMilli => $composableBuilder(
    column: $table.availableMilli,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stockLevel => $composableBuilder(
    column: $table.stockLevel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get snapshotAt => $composableBuilder(
    column: $table.snapshotAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalStockBalancesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalStockBalancesTable> {
  $$LocalStockBalancesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get variantId =>
      $composableBuilder(column: $table.variantId, builder: (column) => column);

  GeneratedColumn<String> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get quantityMilli => $composableBuilder(
    column: $table.quantityMilli,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reservedMilli => $composableBuilder(
    column: $table.reservedMilli,
    builder: (column) => column,
  );

  GeneratedColumn<int> get availableMilli => $composableBuilder(
    column: $table.availableMilli,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stockLevel => $composableBuilder(
    column: $table.stockLevel,
    builder: (column) => column,
  );

  GeneratedColumn<int> get snapshotAt => $composableBuilder(
    column: $table.snapshotAt,
    builder: (column) => column,
  );
}

class $$LocalStockBalancesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalStockBalancesTable,
          StockBalanceRow,
          $$LocalStockBalancesTableFilterComposer,
          $$LocalStockBalancesTableOrderingComposer,
          $$LocalStockBalancesTableAnnotationComposer,
          $$LocalStockBalancesTableCreateCompanionBuilder,
          $$LocalStockBalancesTableUpdateCompanionBuilder,
          (
            StockBalanceRow,
            BaseReferences<
              _$AppDatabase,
              $LocalStockBalancesTable,
              StockBalanceRow
            >,
          ),
          StockBalanceRow,
          PrefetchHooks Function()
        > {
  $$LocalStockBalancesTableTableManager(
    _$AppDatabase db,
    $LocalStockBalancesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalStockBalancesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalStockBalancesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalStockBalancesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> variantId = const Value.absent(),
                Value<String> warehouseId = const Value.absent(),
                Value<int?> quantityMilli = const Value.absent(),
                Value<int?> reservedMilli = const Value.absent(),
                Value<int?> availableMilli = const Value.absent(),
                Value<String> stockLevel = const Value.absent(),
                Value<int> snapshotAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalStockBalancesCompanion(
                variantId: variantId,
                warehouseId: warehouseId,
                quantityMilli: quantityMilli,
                reservedMilli: reservedMilli,
                availableMilli: availableMilli,
                stockLevel: stockLevel,
                snapshotAt: snapshotAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String variantId,
                required String warehouseId,
                Value<int?> quantityMilli = const Value.absent(),
                Value<int?> reservedMilli = const Value.absent(),
                Value<int?> availableMilli = const Value.absent(),
                Value<String> stockLevel = const Value.absent(),
                required int snapshotAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalStockBalancesCompanion.insert(
                variantId: variantId,
                warehouseId: warehouseId,
                quantityMilli: quantityMilli,
                reservedMilli: reservedMilli,
                availableMilli: availableMilli,
                stockLevel: stockLevel,
                snapshotAt: snapshotAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalStockBalancesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalStockBalancesTable,
      StockBalanceRow,
      $$LocalStockBalancesTableFilterComposer,
      $$LocalStockBalancesTableOrderingComposer,
      $$LocalStockBalancesTableAnnotationComposer,
      $$LocalStockBalancesTableCreateCompanionBuilder,
      $$LocalStockBalancesTableUpdateCompanionBuilder,
      (
        StockBalanceRow,
        BaseReferences<
          _$AppDatabase,
          $LocalStockBalancesTable,
          StockBalanceRow
        >,
      ),
      StockBalanceRow,
      PrefetchHooks Function()
    >;
typedef $$LocalProductImagesMetaTableCreateCompanionBuilder =
    LocalProductImagesMetaCompanion Function({
      required String productId,
      Value<String?> variantId,
      required String sha,
      Value<int> sortOrder,
      Value<bool> isPrimary,
      Value<String?> sizesJson,
      Value<String?> serverId,
      Value<int> rowid,
    });
typedef $$LocalProductImagesMetaTableUpdateCompanionBuilder =
    LocalProductImagesMetaCompanion Function({
      Value<String> productId,
      Value<String?> variantId,
      Value<String> sha,
      Value<int> sortOrder,
      Value<bool> isPrimary,
      Value<String?> sizesJson,
      Value<String?> serverId,
      Value<int> rowid,
    });

class $$LocalProductImagesMetaTableFilterComposer
    extends Composer<_$AppDatabase, $LocalProductImagesMetaTable> {
  $$LocalProductImagesMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha => $composableBuilder(
    column: $table.sha,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isPrimary => $composableBuilder(
    column: $table.isPrimary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sizesJson => $composableBuilder(
    column: $table.sizesJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalProductImagesMetaTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalProductImagesMetaTable> {
  $$LocalProductImagesMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha => $composableBuilder(
    column: $table.sha,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isPrimary => $composableBuilder(
    column: $table.isPrimary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sizesJson => $composableBuilder(
    column: $table.sizesJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalProductImagesMetaTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalProductImagesMetaTable> {
  $$LocalProductImagesMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<String> get variantId =>
      $composableBuilder(column: $table.variantId, builder: (column) => column);

  GeneratedColumn<String> get sha =>
      $composableBuilder(column: $table.sha, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<bool> get isPrimary =>
      $composableBuilder(column: $table.isPrimary, builder: (column) => column);

  GeneratedColumn<String> get sizesJson =>
      $composableBuilder(column: $table.sizesJson, builder: (column) => column);

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);
}

class $$LocalProductImagesMetaTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalProductImagesMetaTable,
          ProductImageMetaRow,
          $$LocalProductImagesMetaTableFilterComposer,
          $$LocalProductImagesMetaTableOrderingComposer,
          $$LocalProductImagesMetaTableAnnotationComposer,
          $$LocalProductImagesMetaTableCreateCompanionBuilder,
          $$LocalProductImagesMetaTableUpdateCompanionBuilder,
          (
            ProductImageMetaRow,
            BaseReferences<
              _$AppDatabase,
              $LocalProductImagesMetaTable,
              ProductImageMetaRow
            >,
          ),
          ProductImageMetaRow,
          PrefetchHooks Function()
        > {
  $$LocalProductImagesMetaTableTableManager(
    _$AppDatabase db,
    $LocalProductImagesMetaTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalProductImagesMetaTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$LocalProductImagesMetaTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LocalProductImagesMetaTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> productId = const Value.absent(),
                Value<String?> variantId = const Value.absent(),
                Value<String> sha = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<bool> isPrimary = const Value.absent(),
                Value<String?> sizesJson = const Value.absent(),
                Value<String?> serverId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalProductImagesMetaCompanion(
                productId: productId,
                variantId: variantId,
                sha: sha,
                sortOrder: sortOrder,
                isPrimary: isPrimary,
                sizesJson: sizesJson,
                serverId: serverId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String productId,
                Value<String?> variantId = const Value.absent(),
                required String sha,
                Value<int> sortOrder = const Value.absent(),
                Value<bool> isPrimary = const Value.absent(),
                Value<String?> sizesJson = const Value.absent(),
                Value<String?> serverId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalProductImagesMetaCompanion.insert(
                productId: productId,
                variantId: variantId,
                sha: sha,
                sortOrder: sortOrder,
                isPrimary: isPrimary,
                sizesJson: sizesJson,
                serverId: serverId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalProductImagesMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalProductImagesMetaTable,
      ProductImageMetaRow,
      $$LocalProductImagesMetaTableFilterComposer,
      $$LocalProductImagesMetaTableOrderingComposer,
      $$LocalProductImagesMetaTableAnnotationComposer,
      $$LocalProductImagesMetaTableCreateCompanionBuilder,
      $$LocalProductImagesMetaTableUpdateCompanionBuilder,
      (
        ProductImageMetaRow,
        BaseReferences<
          _$AppDatabase,
          $LocalProductImagesMetaTable,
          ProductImageMetaRow
        >,
      ),
      ProductImageMetaRow,
      PrefetchHooks Function()
    >;
typedef $$LocalFavoritesProductsTableCreateCompanionBuilder =
    LocalFavoritesProductsCompanion Function({
      required String productId,
      required int createdAt,
      Value<String?> pendingOp,
      Value<int> rowid,
    });
typedef $$LocalFavoritesProductsTableUpdateCompanionBuilder =
    LocalFavoritesProductsCompanion Function({
      Value<String> productId,
      Value<int> createdAt,
      Value<String?> pendingOp,
      Value<int> rowid,
    });

class $$LocalFavoritesProductsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalFavoritesProductsTable> {
  $$LocalFavoritesProductsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pendingOp => $composableBuilder(
    column: $table.pendingOp,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalFavoritesProductsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalFavoritesProductsTable> {
  $$LocalFavoritesProductsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pendingOp => $composableBuilder(
    column: $table.pendingOp,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalFavoritesProductsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalFavoritesProductsTable> {
  $$LocalFavoritesProductsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get pendingOp =>
      $composableBuilder(column: $table.pendingOp, builder: (column) => column);
}

class $$LocalFavoritesProductsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalFavoritesProductsTable,
          FavoriteProductRow,
          $$LocalFavoritesProductsTableFilterComposer,
          $$LocalFavoritesProductsTableOrderingComposer,
          $$LocalFavoritesProductsTableAnnotationComposer,
          $$LocalFavoritesProductsTableCreateCompanionBuilder,
          $$LocalFavoritesProductsTableUpdateCompanionBuilder,
          (
            FavoriteProductRow,
            BaseReferences<
              _$AppDatabase,
              $LocalFavoritesProductsTable,
              FavoriteProductRow
            >,
          ),
          FavoriteProductRow,
          PrefetchHooks Function()
        > {
  $$LocalFavoritesProductsTableTableManager(
    _$AppDatabase db,
    $LocalFavoritesProductsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalFavoritesProductsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$LocalFavoritesProductsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LocalFavoritesProductsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> productId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String?> pendingOp = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalFavoritesProductsCompanion(
                productId: productId,
                createdAt: createdAt,
                pendingOp: pendingOp,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String productId,
                required int createdAt,
                Value<String?> pendingOp = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalFavoritesProductsCompanion.insert(
                productId: productId,
                createdAt: createdAt,
                pendingOp: pendingOp,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalFavoritesProductsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalFavoritesProductsTable,
      FavoriteProductRow,
      $$LocalFavoritesProductsTableFilterComposer,
      $$LocalFavoritesProductsTableOrderingComposer,
      $$LocalFavoritesProductsTableAnnotationComposer,
      $$LocalFavoritesProductsTableCreateCompanionBuilder,
      $$LocalFavoritesProductsTableUpdateCompanionBuilder,
      (
        FavoriteProductRow,
        BaseReferences<
          _$AppDatabase,
          $LocalFavoritesProductsTable,
          FavoriteProductRow
        >,
      ),
      FavoriteProductRow,
      PrefetchHooks Function()
    >;
typedef $$LocalFavoritesCustomersTableCreateCompanionBuilder =
    LocalFavoritesCustomersCompanion Function({
      required String customerId,
      required int createdAt,
      Value<String?> pendingOp,
      Value<int> rowid,
    });
typedef $$LocalFavoritesCustomersTableUpdateCompanionBuilder =
    LocalFavoritesCustomersCompanion Function({
      Value<String> customerId,
      Value<int> createdAt,
      Value<String?> pendingOp,
      Value<int> rowid,
    });

class $$LocalFavoritesCustomersTableFilterComposer
    extends Composer<_$AppDatabase, $LocalFavoritesCustomersTable> {
  $$LocalFavoritesCustomersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pendingOp => $composableBuilder(
    column: $table.pendingOp,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalFavoritesCustomersTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalFavoritesCustomersTable> {
  $$LocalFavoritesCustomersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pendingOp => $composableBuilder(
    column: $table.pendingOp,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalFavoritesCustomersTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalFavoritesCustomersTable> {
  $$LocalFavoritesCustomersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get pendingOp =>
      $composableBuilder(column: $table.pendingOp, builder: (column) => column);
}

class $$LocalFavoritesCustomersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalFavoritesCustomersTable,
          FavoriteCustomerRow,
          $$LocalFavoritesCustomersTableFilterComposer,
          $$LocalFavoritesCustomersTableOrderingComposer,
          $$LocalFavoritesCustomersTableAnnotationComposer,
          $$LocalFavoritesCustomersTableCreateCompanionBuilder,
          $$LocalFavoritesCustomersTableUpdateCompanionBuilder,
          (
            FavoriteCustomerRow,
            BaseReferences<
              _$AppDatabase,
              $LocalFavoritesCustomersTable,
              FavoriteCustomerRow
            >,
          ),
          FavoriteCustomerRow,
          PrefetchHooks Function()
        > {
  $$LocalFavoritesCustomersTableTableManager(
    _$AppDatabase db,
    $LocalFavoritesCustomersTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalFavoritesCustomersTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$LocalFavoritesCustomersTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LocalFavoritesCustomersTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> customerId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String?> pendingOp = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalFavoritesCustomersCompanion(
                customerId: customerId,
                createdAt: createdAt,
                pendingOp: pendingOp,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String customerId,
                required int createdAt,
                Value<String?> pendingOp = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalFavoritesCustomersCompanion.insert(
                customerId: customerId,
                createdAt: createdAt,
                pendingOp: pendingOp,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalFavoritesCustomersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalFavoritesCustomersTable,
      FavoriteCustomerRow,
      $$LocalFavoritesCustomersTableFilterComposer,
      $$LocalFavoritesCustomersTableOrderingComposer,
      $$LocalFavoritesCustomersTableAnnotationComposer,
      $$LocalFavoritesCustomersTableCreateCompanionBuilder,
      $$LocalFavoritesCustomersTableUpdateCompanionBuilder,
      (
        FavoriteCustomerRow,
        BaseReferences<
          _$AppDatabase,
          $LocalFavoritesCustomersTable,
          FavoriteCustomerRow
        >,
      ),
      FavoriteCustomerRow,
      PrefetchHooks Function()
    >;
typedef $$CartDraftTableCreateCompanionBuilder =
    CartDraftCompanion Function({
      required String localId,
      Value<String?> serverId,
      required String status,
      Value<String?> name,
      Value<String?> customerId,
      Value<String?> warehouseId,
      Value<String?> priceListId,
      Value<int> discountPercentHundredths,
      Value<int?> baseRowVersion,
      Value<bool> dirty,
      required String ownerUserId,
      required int updatedAt,
      Value<int?> serverSyncedAt,
      Value<int> rowid,
    });
typedef $$CartDraftTableUpdateCompanionBuilder =
    CartDraftCompanion Function({
      Value<String> localId,
      Value<String?> serverId,
      Value<String> status,
      Value<String?> name,
      Value<String?> customerId,
      Value<String?> warehouseId,
      Value<String?> priceListId,
      Value<int> discountPercentHundredths,
      Value<int?> baseRowVersion,
      Value<bool> dirty,
      Value<String> ownerUserId,
      Value<int> updatedAt,
      Value<int?> serverSyncedAt,
      Value<int> rowid,
    });

class $$CartDraftTableFilterComposer
    extends Composer<_$AppDatabase, $CartDraftTable> {
  $$CartDraftTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get priceListId => $composableBuilder(
    column: $table.priceListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get discountPercentHundredths => $composableBuilder(
    column: $table.discountPercentHundredths,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get baseRowVersion => $composableBuilder(
    column: $table.baseRowVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverSyncedAt => $composableBuilder(
    column: $table.serverSyncedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CartDraftTableOrderingComposer
    extends Composer<_$AppDatabase, $CartDraftTable> {
  $$CartDraftTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get priceListId => $composableBuilder(
    column: $table.priceListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get discountPercentHundredths => $composableBuilder(
    column: $table.discountPercentHundredths,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get baseRowVersion => $composableBuilder(
    column: $table.baseRowVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverSyncedAt => $composableBuilder(
    column: $table.serverSyncedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CartDraftTableAnnotationComposer
    extends Composer<_$AppDatabase, $CartDraftTable> {
  $$CartDraftTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get localId =>
      $composableBuilder(column: $table.localId, builder: (column) => column);

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get warehouseId => $composableBuilder(
    column: $table.warehouseId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get priceListId => $composableBuilder(
    column: $table.priceListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get discountPercentHundredths => $composableBuilder(
    column: $table.discountPercentHundredths,
    builder: (column) => column,
  );

  GeneratedColumn<int> get baseRowVersion => $composableBuilder(
    column: $table.baseRowVersion,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get serverSyncedAt => $composableBuilder(
    column: $table.serverSyncedAt,
    builder: (column) => column,
  );
}

class $$CartDraftTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CartDraftTable,
          CartDraftRow,
          $$CartDraftTableFilterComposer,
          $$CartDraftTableOrderingComposer,
          $$CartDraftTableAnnotationComposer,
          $$CartDraftTableCreateCompanionBuilder,
          $$CartDraftTableUpdateCompanionBuilder,
          (
            CartDraftRow,
            BaseReferences<_$AppDatabase, $CartDraftTable, CartDraftRow>,
          ),
          CartDraftRow,
          PrefetchHooks Function()
        > {
  $$CartDraftTableTableManager(_$AppDatabase db, $CartDraftTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CartDraftTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CartDraftTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CartDraftTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> localId = const Value.absent(),
                Value<String?> serverId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> name = const Value.absent(),
                Value<String?> customerId = const Value.absent(),
                Value<String?> warehouseId = const Value.absent(),
                Value<String?> priceListId = const Value.absent(),
                Value<int> discountPercentHundredths = const Value.absent(),
                Value<int?> baseRowVersion = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<String> ownerUserId = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> serverSyncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CartDraftCompanion(
                localId: localId,
                serverId: serverId,
                status: status,
                name: name,
                customerId: customerId,
                warehouseId: warehouseId,
                priceListId: priceListId,
                discountPercentHundredths: discountPercentHundredths,
                baseRowVersion: baseRowVersion,
                dirty: dirty,
                ownerUserId: ownerUserId,
                updatedAt: updatedAt,
                serverSyncedAt: serverSyncedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String localId,
                Value<String?> serverId = const Value.absent(),
                required String status,
                Value<String?> name = const Value.absent(),
                Value<String?> customerId = const Value.absent(),
                Value<String?> warehouseId = const Value.absent(),
                Value<String?> priceListId = const Value.absent(),
                Value<int> discountPercentHundredths = const Value.absent(),
                Value<int?> baseRowVersion = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                required String ownerUserId,
                required int updatedAt,
                Value<int?> serverSyncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CartDraftCompanion.insert(
                localId: localId,
                serverId: serverId,
                status: status,
                name: name,
                customerId: customerId,
                warehouseId: warehouseId,
                priceListId: priceListId,
                discountPercentHundredths: discountPercentHundredths,
                baseRowVersion: baseRowVersion,
                dirty: dirty,
                ownerUserId: ownerUserId,
                updatedAt: updatedAt,
                serverSyncedAt: serverSyncedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CartDraftTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CartDraftTable,
      CartDraftRow,
      $$CartDraftTableFilterComposer,
      $$CartDraftTableOrderingComposer,
      $$CartDraftTableAnnotationComposer,
      $$CartDraftTableCreateCompanionBuilder,
      $$CartDraftTableUpdateCompanionBuilder,
      (
        CartDraftRow,
        BaseReferences<_$AppDatabase, $CartDraftTable, CartDraftRow>,
      ),
      CartDraftRow,
      PrefetchHooks Function()
    >;
typedef $$CartItemsDraftTableCreateCompanionBuilder =
    CartItemsDraftCompanion Function({
      required String localItemId,
      required String localCartId,
      Value<String?> serverItemId,
      required String variantId,
      Value<String?> packagingId,
      required int quantityMilli,
      Value<String?> unitId,
      Value<int?> priceSnapshotTyiyn,
      Value<int?> stockSnapshotMilli,
      Value<bool> priceChanged,
      Value<bool> stockInsufficient,
      required int lineNo,
      required String ownerUserId,
      Value<String> syncState,
      Value<int> rowid,
    });
typedef $$CartItemsDraftTableUpdateCompanionBuilder =
    CartItemsDraftCompanion Function({
      Value<String> localItemId,
      Value<String> localCartId,
      Value<String?> serverItemId,
      Value<String> variantId,
      Value<String?> packagingId,
      Value<int> quantityMilli,
      Value<String?> unitId,
      Value<int?> priceSnapshotTyiyn,
      Value<int?> stockSnapshotMilli,
      Value<bool> priceChanged,
      Value<bool> stockInsufficient,
      Value<int> lineNo,
      Value<String> ownerUserId,
      Value<String> syncState,
      Value<int> rowid,
    });

class $$CartItemsDraftTableFilterComposer
    extends Composer<_$AppDatabase, $CartItemsDraftTable> {
  $$CartItemsDraftTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get localItemId => $composableBuilder(
    column: $table.localItemId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localCartId => $composableBuilder(
    column: $table.localCartId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverItemId => $composableBuilder(
    column: $table.serverItemId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get packagingId => $composableBuilder(
    column: $table.packagingId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get quantityMilli => $composableBuilder(
    column: $table.quantityMilli,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get unitId => $composableBuilder(
    column: $table.unitId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get priceSnapshotTyiyn => $composableBuilder(
    column: $table.priceSnapshotTyiyn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get stockSnapshotMilli => $composableBuilder(
    column: $table.stockSnapshotMilli,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get priceChanged => $composableBuilder(
    column: $table.priceChanged,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get stockInsufficient => $composableBuilder(
    column: $table.stockInsufficient,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lineNo => $composableBuilder(
    column: $table.lineNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CartItemsDraftTableOrderingComposer
    extends Composer<_$AppDatabase, $CartItemsDraftTable> {
  $$CartItemsDraftTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get localItemId => $composableBuilder(
    column: $table.localItemId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localCartId => $composableBuilder(
    column: $table.localCartId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverItemId => $composableBuilder(
    column: $table.serverItemId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get packagingId => $composableBuilder(
    column: $table.packagingId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get quantityMilli => $composableBuilder(
    column: $table.quantityMilli,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get unitId => $composableBuilder(
    column: $table.unitId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get priceSnapshotTyiyn => $composableBuilder(
    column: $table.priceSnapshotTyiyn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get stockSnapshotMilli => $composableBuilder(
    column: $table.stockSnapshotMilli,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get priceChanged => $composableBuilder(
    column: $table.priceChanged,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get stockInsufficient => $composableBuilder(
    column: $table.stockInsufficient,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lineNo => $composableBuilder(
    column: $table.lineNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CartItemsDraftTableAnnotationComposer
    extends Composer<_$AppDatabase, $CartItemsDraftTable> {
  $$CartItemsDraftTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get localItemId => $composableBuilder(
    column: $table.localItemId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get localCartId => $composableBuilder(
    column: $table.localCartId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverItemId => $composableBuilder(
    column: $table.serverItemId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get variantId =>
      $composableBuilder(column: $table.variantId, builder: (column) => column);

  GeneratedColumn<String> get packagingId => $composableBuilder(
    column: $table.packagingId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get quantityMilli => $composableBuilder(
    column: $table.quantityMilli,
    builder: (column) => column,
  );

  GeneratedColumn<String> get unitId =>
      $composableBuilder(column: $table.unitId, builder: (column) => column);

  GeneratedColumn<int> get priceSnapshotTyiyn => $composableBuilder(
    column: $table.priceSnapshotTyiyn,
    builder: (column) => column,
  );

  GeneratedColumn<int> get stockSnapshotMilli => $composableBuilder(
    column: $table.stockSnapshotMilli,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get priceChanged => $composableBuilder(
    column: $table.priceChanged,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get stockInsufficient => $composableBuilder(
    column: $table.stockInsufficient,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lineNo =>
      $composableBuilder(column: $table.lineNo, builder: (column) => column);

  GeneratedColumn<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get syncState =>
      $composableBuilder(column: $table.syncState, builder: (column) => column);
}

class $$CartItemsDraftTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CartItemsDraftTable,
          CartItemDraftRow,
          $$CartItemsDraftTableFilterComposer,
          $$CartItemsDraftTableOrderingComposer,
          $$CartItemsDraftTableAnnotationComposer,
          $$CartItemsDraftTableCreateCompanionBuilder,
          $$CartItemsDraftTableUpdateCompanionBuilder,
          (
            CartItemDraftRow,
            BaseReferences<
              _$AppDatabase,
              $CartItemsDraftTable,
              CartItemDraftRow
            >,
          ),
          CartItemDraftRow,
          PrefetchHooks Function()
        > {
  $$CartItemsDraftTableTableManager(
    _$AppDatabase db,
    $CartItemsDraftTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CartItemsDraftTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CartItemsDraftTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CartItemsDraftTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> localItemId = const Value.absent(),
                Value<String> localCartId = const Value.absent(),
                Value<String?> serverItemId = const Value.absent(),
                Value<String> variantId = const Value.absent(),
                Value<String?> packagingId = const Value.absent(),
                Value<int> quantityMilli = const Value.absent(),
                Value<String?> unitId = const Value.absent(),
                Value<int?> priceSnapshotTyiyn = const Value.absent(),
                Value<int?> stockSnapshotMilli = const Value.absent(),
                Value<bool> priceChanged = const Value.absent(),
                Value<bool> stockInsufficient = const Value.absent(),
                Value<int> lineNo = const Value.absent(),
                Value<String> ownerUserId = const Value.absent(),
                Value<String> syncState = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CartItemsDraftCompanion(
                localItemId: localItemId,
                localCartId: localCartId,
                serverItemId: serverItemId,
                variantId: variantId,
                packagingId: packagingId,
                quantityMilli: quantityMilli,
                unitId: unitId,
                priceSnapshotTyiyn: priceSnapshotTyiyn,
                stockSnapshotMilli: stockSnapshotMilli,
                priceChanged: priceChanged,
                stockInsufficient: stockInsufficient,
                lineNo: lineNo,
                ownerUserId: ownerUserId,
                syncState: syncState,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String localItemId,
                required String localCartId,
                Value<String?> serverItemId = const Value.absent(),
                required String variantId,
                Value<String?> packagingId = const Value.absent(),
                required int quantityMilli,
                Value<String?> unitId = const Value.absent(),
                Value<int?> priceSnapshotTyiyn = const Value.absent(),
                Value<int?> stockSnapshotMilli = const Value.absent(),
                Value<bool> priceChanged = const Value.absent(),
                Value<bool> stockInsufficient = const Value.absent(),
                required int lineNo,
                required String ownerUserId,
                Value<String> syncState = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CartItemsDraftCompanion.insert(
                localItemId: localItemId,
                localCartId: localCartId,
                serverItemId: serverItemId,
                variantId: variantId,
                packagingId: packagingId,
                quantityMilli: quantityMilli,
                unitId: unitId,
                priceSnapshotTyiyn: priceSnapshotTyiyn,
                stockSnapshotMilli: stockSnapshotMilli,
                priceChanged: priceChanged,
                stockInsufficient: stockInsufficient,
                lineNo: lineNo,
                ownerUserId: ownerUserId,
                syncState: syncState,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CartItemsDraftTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CartItemsDraftTable,
      CartItemDraftRow,
      $$CartItemsDraftTableFilterComposer,
      $$CartItemsDraftTableOrderingComposer,
      $$CartItemsDraftTableAnnotationComposer,
      $$CartItemsDraftTableCreateCompanionBuilder,
      $$CartItemsDraftTableUpdateCompanionBuilder,
      (
        CartItemDraftRow,
        BaseReferences<_$AppDatabase, $CartItemsDraftTable, CartItemDraftRow>,
      ),
      CartItemDraftRow,
      PrefetchHooks Function()
    >;
typedef $$OutboxActionsTableCreateCompanionBuilder =
    OutboxActionsCompanion Function({
      Value<int> id,
      required String type,
      required String payloadJson,
      required String idempotencyKey,
      required String ownerUserId,
      Value<String> status,
      Value<int> attempts,
      Value<String?> lastError,
      required int createdAt,
      Value<int?> nextAttemptAt,
    });
typedef $$OutboxActionsTableUpdateCompanionBuilder =
    OutboxActionsCompanion Function({
      Value<int> id,
      Value<String> type,
      Value<String> payloadJson,
      Value<String> idempotencyKey,
      Value<String> ownerUserId,
      Value<String> status,
      Value<int> attempts,
      Value<String?> lastError,
      Value<int> createdAt,
      Value<int?> nextAttemptAt,
    });

class $$OutboxActionsTableFilterComposer
    extends Composer<_$AppDatabase, $OutboxActionsTable> {
  $$OutboxActionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OutboxActionsTableOrderingComposer
    extends Composer<_$AppDatabase, $OutboxActionsTable> {
  $$OutboxActionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OutboxActionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $OutboxActionsTable> {
  $$OutboxActionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );
}

class $$OutboxActionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $OutboxActionsTable,
          OutboxActionRow,
          $$OutboxActionsTableFilterComposer,
          $$OutboxActionsTableOrderingComposer,
          $$OutboxActionsTableAnnotationComposer,
          $$OutboxActionsTableCreateCompanionBuilder,
          $$OutboxActionsTableUpdateCompanionBuilder,
          (
            OutboxActionRow,
            BaseReferences<_$AppDatabase, $OutboxActionsTable, OutboxActionRow>,
          ),
          OutboxActionRow,
          PrefetchHooks Function()
        > {
  $$OutboxActionsTableTableManager(_$AppDatabase db, $OutboxActionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OutboxActionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OutboxActionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OutboxActionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<String> idempotencyKey = const Value.absent(),
                Value<String> ownerUserId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int?> nextAttemptAt = const Value.absent(),
              }) => OutboxActionsCompanion(
                id: id,
                type: type,
                payloadJson: payloadJson,
                idempotencyKey: idempotencyKey,
                ownerUserId: ownerUserId,
                status: status,
                attempts: attempts,
                lastError: lastError,
                createdAt: createdAt,
                nextAttemptAt: nextAttemptAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String type,
                required String payloadJson,
                required String idempotencyKey,
                required String ownerUserId,
                Value<String> status = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                required int createdAt,
                Value<int?> nextAttemptAt = const Value.absent(),
              }) => OutboxActionsCompanion.insert(
                id: id,
                type: type,
                payloadJson: payloadJson,
                idempotencyKey: idempotencyKey,
                ownerUserId: ownerUserId,
                status: status,
                attempts: attempts,
                lastError: lastError,
                createdAt: createdAt,
                nextAttemptAt: nextAttemptAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OutboxActionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $OutboxActionsTable,
      OutboxActionRow,
      $$OutboxActionsTableFilterComposer,
      $$OutboxActionsTableOrderingComposer,
      $$OutboxActionsTableAnnotationComposer,
      $$OutboxActionsTableCreateCompanionBuilder,
      $$OutboxActionsTableUpdateCompanionBuilder,
      (
        OutboxActionRow,
        BaseReferences<_$AppDatabase, $OutboxActionsTable, OutboxActionRow>,
      ),
      OutboxActionRow,
      PrefetchHooks Function()
    >;
typedef $$LocalRecentProductsTableCreateCompanionBuilder =
    LocalRecentProductsCompanion Function({
      required String productId,
      required int lastViewedAt,
      Value<int> viewCount,
      Value<int> rowid,
    });
typedef $$LocalRecentProductsTableUpdateCompanionBuilder =
    LocalRecentProductsCompanion Function({
      Value<String> productId,
      Value<int> lastViewedAt,
      Value<int> viewCount,
      Value<int> rowid,
    });

class $$LocalRecentProductsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalRecentProductsTable> {
  $$LocalRecentProductsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastViewedAt => $composableBuilder(
    column: $table.lastViewedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get viewCount => $composableBuilder(
    column: $table.viewCount,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalRecentProductsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalRecentProductsTable> {
  $$LocalRecentProductsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastViewedAt => $composableBuilder(
    column: $table.lastViewedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get viewCount => $composableBuilder(
    column: $table.viewCount,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalRecentProductsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalRecentProductsTable> {
  $$LocalRecentProductsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<int> get lastViewedAt => $composableBuilder(
    column: $table.lastViewedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get viewCount =>
      $composableBuilder(column: $table.viewCount, builder: (column) => column);
}

class $$LocalRecentProductsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalRecentProductsTable,
          RecentProductRow,
          $$LocalRecentProductsTableFilterComposer,
          $$LocalRecentProductsTableOrderingComposer,
          $$LocalRecentProductsTableAnnotationComposer,
          $$LocalRecentProductsTableCreateCompanionBuilder,
          $$LocalRecentProductsTableUpdateCompanionBuilder,
          (
            RecentProductRow,
            BaseReferences<
              _$AppDatabase,
              $LocalRecentProductsTable,
              RecentProductRow
            >,
          ),
          RecentProductRow,
          PrefetchHooks Function()
        > {
  $$LocalRecentProductsTableTableManager(
    _$AppDatabase db,
    $LocalRecentProductsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalRecentProductsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalRecentProductsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LocalRecentProductsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> productId = const Value.absent(),
                Value<int> lastViewedAt = const Value.absent(),
                Value<int> viewCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalRecentProductsCompanion(
                productId: productId,
                lastViewedAt: lastViewedAt,
                viewCount: viewCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String productId,
                required int lastViewedAt,
                Value<int> viewCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalRecentProductsCompanion.insert(
                productId: productId,
                lastViewedAt: lastViewedAt,
                viewCount: viewCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalRecentProductsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalRecentProductsTable,
      RecentProductRow,
      $$LocalRecentProductsTableFilterComposer,
      $$LocalRecentProductsTableOrderingComposer,
      $$LocalRecentProductsTableAnnotationComposer,
      $$LocalRecentProductsTableCreateCompanionBuilder,
      $$LocalRecentProductsTableUpdateCompanionBuilder,
      (
        RecentProductRow,
        BaseReferences<
          _$AppDatabase,
          $LocalRecentProductsTable,
          RecentProductRow
        >,
      ),
      RecentProductRow,
      PrefetchHooks Function()
    >;
typedef $$NotificationsCacheTableCreateCompanionBuilder =
    NotificationsCacheCompanion Function({
      required String id,
      required String kind,
      required String severity,
      required String title,
      Value<String?> body,
      Value<String?> payloadJson,
      required int createdAt,
      Value<int?> readAt,
      Value<int> rowid,
    });
typedef $$NotificationsCacheTableUpdateCompanionBuilder =
    NotificationsCacheCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<String> severity,
      Value<String> title,
      Value<String?> body,
      Value<String?> payloadJson,
      Value<int> createdAt,
      Value<int?> readAt,
      Value<int> rowid,
    });

class $$NotificationsCacheTableFilterComposer
    extends Composer<_$AppDatabase, $NotificationsCacheTable> {
  $$NotificationsCacheTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get readAt => $composableBuilder(
    column: $table.readAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotificationsCacheTableOrderingComposer
    extends Composer<_$AppDatabase, $NotificationsCacheTable> {
  $$NotificationsCacheTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get severity => $composableBuilder(
    column: $table.severity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get readAt => $composableBuilder(
    column: $table.readAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotificationsCacheTableAnnotationComposer
    extends Composer<_$AppDatabase, $NotificationsCacheTable> {
  $$NotificationsCacheTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get severity =>
      $composableBuilder(column: $table.severity, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get readAt =>
      $composableBuilder(column: $table.readAt, builder: (column) => column);
}

class $$NotificationsCacheTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $NotificationsCacheTable,
          NotificationCacheRow,
          $$NotificationsCacheTableFilterComposer,
          $$NotificationsCacheTableOrderingComposer,
          $$NotificationsCacheTableAnnotationComposer,
          $$NotificationsCacheTableCreateCompanionBuilder,
          $$NotificationsCacheTableUpdateCompanionBuilder,
          (
            NotificationCacheRow,
            BaseReferences<
              _$AppDatabase,
              $NotificationsCacheTable,
              NotificationCacheRow
            >,
          ),
          NotificationCacheRow,
          PrefetchHooks Function()
        > {
  $$NotificationsCacheTableTableManager(
    _$AppDatabase db,
    $NotificationsCacheTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotificationsCacheTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotificationsCacheTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotificationsCacheTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> severity = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> body = const Value.absent(),
                Value<String?> payloadJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int?> readAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotificationsCacheCompanion(
                id: id,
                kind: kind,
                severity: severity,
                title: title,
                body: body,
                payloadJson: payloadJson,
                createdAt: createdAt,
                readAt: readAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                required String severity,
                required String title,
                Value<String?> body = const Value.absent(),
                Value<String?> payloadJson = const Value.absent(),
                required int createdAt,
                Value<int?> readAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotificationsCacheCompanion.insert(
                id: id,
                kind: kind,
                severity: severity,
                title: title,
                body: body,
                payloadJson: payloadJson,
                createdAt: createdAt,
                readAt: readAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotificationsCacheTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $NotificationsCacheTable,
      NotificationCacheRow,
      $$NotificationsCacheTableFilterComposer,
      $$NotificationsCacheTableOrderingComposer,
      $$NotificationsCacheTableAnnotationComposer,
      $$NotificationsCacheTableCreateCompanionBuilder,
      $$NotificationsCacheTableUpdateCompanionBuilder,
      (
        NotificationCacheRow,
        BaseReferences<
          _$AppDatabase,
          $NotificationsCacheTable,
          NotificationCacheRow
        >,
      ),
      NotificationCacheRow,
      PrefetchHooks Function()
    >;
typedef $$LocalSettingsTableCreateCompanionBuilder =
    LocalSettingsCompanion Function({
      required String key,
      required String valueJson,
      required String scope,
      required int updatedAt,
      Value<bool> dirty,
      Value<int> rowid,
    });
typedef $$LocalSettingsTableUpdateCompanionBuilder =
    LocalSettingsCompanion Function({
      Value<String> key,
      Value<String> valueJson,
      Value<String> scope,
      Value<int> updatedAt,
      Value<bool> dirty,
      Value<int> rowid,
    });

class $$LocalSettingsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalSettingsTable> {
  $$LocalSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scope => $composableBuilder(
    column: $table.scope,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalSettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalSettingsTable> {
  $$LocalSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scope => $composableBuilder(
    column: $table.scope,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalSettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalSettingsTable> {
  $$LocalSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get valueJson =>
      $composableBuilder(column: $table.valueJson, builder: (column) => column);

  GeneratedColumn<String> get scope =>
      $composableBuilder(column: $table.scope, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);
}

class $$LocalSettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalSettingsTable,
          SettingRow,
          $$LocalSettingsTableFilterComposer,
          $$LocalSettingsTableOrderingComposer,
          $$LocalSettingsTableAnnotationComposer,
          $$LocalSettingsTableCreateCompanionBuilder,
          $$LocalSettingsTableUpdateCompanionBuilder,
          (
            SettingRow,
            BaseReferences<_$AppDatabase, $LocalSettingsTable, SettingRow>,
          ),
          SettingRow,
          PrefetchHooks Function()
        > {
  $$LocalSettingsTableTableManager(_$AppDatabase db, $LocalSettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> valueJson = const Value.absent(),
                Value<String> scope = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalSettingsCompanion(
                key: key,
                valueJson: valueJson,
                scope: scope,
                updatedAt: updatedAt,
                dirty: dirty,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String valueJson,
                required String scope,
                required int updatedAt,
                Value<bool> dirty = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalSettingsCompanion.insert(
                key: key,
                valueJson: valueJson,
                scope: scope,
                updatedAt: updatedAt,
                dirty: dirty,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalSettingsTable,
      SettingRow,
      $$LocalSettingsTableFilterComposer,
      $$LocalSettingsTableOrderingComposer,
      $$LocalSettingsTableAnnotationComposer,
      $$LocalSettingsTableCreateCompanionBuilder,
      $$LocalSettingsTableUpdateCompanionBuilder,
      (
        SettingRow,
        BaseReferences<_$AppDatabase, $LocalSettingsTable, SettingRow>,
      ),
      SettingRow,
      PrefetchHooks Function()
    >;
typedef $$RegistrationDraftTableCreateCompanionBuilder =
    RegistrationDraftCompanion Function({
      required String key,
      required String valueJson,
      Value<int> rowid,
    });
typedef $$RegistrationDraftTableUpdateCompanionBuilder =
    RegistrationDraftCompanion Function({
      Value<String> key,
      Value<String> valueJson,
      Value<int> rowid,
    });

class $$RegistrationDraftTableFilterComposer
    extends Composer<_$AppDatabase, $RegistrationDraftTable> {
  $$RegistrationDraftTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RegistrationDraftTableOrderingComposer
    extends Composer<_$AppDatabase, $RegistrationDraftTable> {
  $$RegistrationDraftTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RegistrationDraftTableAnnotationComposer
    extends Composer<_$AppDatabase, $RegistrationDraftTable> {
  $$RegistrationDraftTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get valueJson =>
      $composableBuilder(column: $table.valueJson, builder: (column) => column);
}

class $$RegistrationDraftTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RegistrationDraftTable,
          RegistrationDraftRow,
          $$RegistrationDraftTableFilterComposer,
          $$RegistrationDraftTableOrderingComposer,
          $$RegistrationDraftTableAnnotationComposer,
          $$RegistrationDraftTableCreateCompanionBuilder,
          $$RegistrationDraftTableUpdateCompanionBuilder,
          (
            RegistrationDraftRow,
            BaseReferences<
              _$AppDatabase,
              $RegistrationDraftTable,
              RegistrationDraftRow
            >,
          ),
          RegistrationDraftRow,
          PrefetchHooks Function()
        > {
  $$RegistrationDraftTableTableManager(
    _$AppDatabase db,
    $RegistrationDraftTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RegistrationDraftTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RegistrationDraftTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RegistrationDraftTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> valueJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RegistrationDraftCompanion(
                key: key,
                valueJson: valueJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String valueJson,
                Value<int> rowid = const Value.absent(),
              }) => RegistrationDraftCompanion.insert(
                key: key,
                valueJson: valueJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RegistrationDraftTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RegistrationDraftTable,
      RegistrationDraftRow,
      $$RegistrationDraftTableFilterComposer,
      $$RegistrationDraftTableOrderingComposer,
      $$RegistrationDraftTableAnnotationComposer,
      $$RegistrationDraftTableCreateCompanionBuilder,
      $$RegistrationDraftTableUpdateCompanionBuilder,
      (
        RegistrationDraftRow,
        BaseReferences<
          _$AppDatabase,
          $RegistrationDraftTable,
          RegistrationDraftRow
        >,
      ),
      RegistrationDraftRow,
      PrefetchHooks Function()
    >;
typedef $$CheckoutDraftTableCreateCompanionBuilder =
    CheckoutDraftCompanion Function({
      required String localCartId,
      required String step,
      Value<String?> customerId,
      Value<String?> deliveryMethod,
      Value<String?> receiverKind,
      Value<String?> paymentMethod,
      Value<String?> orderIdempotencyKey,
      Value<int?> submittedAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$CheckoutDraftTableUpdateCompanionBuilder =
    CheckoutDraftCompanion Function({
      Value<String> localCartId,
      Value<String> step,
      Value<String?> customerId,
      Value<String?> deliveryMethod,
      Value<String?> receiverKind,
      Value<String?> paymentMethod,
      Value<String?> orderIdempotencyKey,
      Value<int?> submittedAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$CheckoutDraftTableFilterComposer
    extends Composer<_$AppDatabase, $CheckoutDraftTable> {
  $$CheckoutDraftTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get localCartId => $composableBuilder(
    column: $table.localCartId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get step => $composableBuilder(
    column: $table.step,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deliveryMethod => $composableBuilder(
    column: $table.deliveryMethod,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receiverKind => $composableBuilder(
    column: $table.receiverKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get paymentMethod => $composableBuilder(
    column: $table.paymentMethod,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get orderIdempotencyKey => $composableBuilder(
    column: $table.orderIdempotencyKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get submittedAt => $composableBuilder(
    column: $table.submittedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CheckoutDraftTableOrderingComposer
    extends Composer<_$AppDatabase, $CheckoutDraftTable> {
  $$CheckoutDraftTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get localCartId => $composableBuilder(
    column: $table.localCartId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get step => $composableBuilder(
    column: $table.step,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deliveryMethod => $composableBuilder(
    column: $table.deliveryMethod,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receiverKind => $composableBuilder(
    column: $table.receiverKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get paymentMethod => $composableBuilder(
    column: $table.paymentMethod,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get orderIdempotencyKey => $composableBuilder(
    column: $table.orderIdempotencyKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get submittedAt => $composableBuilder(
    column: $table.submittedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CheckoutDraftTableAnnotationComposer
    extends Composer<_$AppDatabase, $CheckoutDraftTable> {
  $$CheckoutDraftTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get localCartId => $composableBuilder(
    column: $table.localCartId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get step =>
      $composableBuilder(column: $table.step, builder: (column) => column);

  GeneratedColumn<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deliveryMethod => $composableBuilder(
    column: $table.deliveryMethod,
    builder: (column) => column,
  );

  GeneratedColumn<String> get receiverKind => $composableBuilder(
    column: $table.receiverKind,
    builder: (column) => column,
  );

  GeneratedColumn<String> get paymentMethod => $composableBuilder(
    column: $table.paymentMethod,
    builder: (column) => column,
  );

  GeneratedColumn<String> get orderIdempotencyKey => $composableBuilder(
    column: $table.orderIdempotencyKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get submittedAt => $composableBuilder(
    column: $table.submittedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$CheckoutDraftTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CheckoutDraftTable,
          CheckoutDraftRow,
          $$CheckoutDraftTableFilterComposer,
          $$CheckoutDraftTableOrderingComposer,
          $$CheckoutDraftTableAnnotationComposer,
          $$CheckoutDraftTableCreateCompanionBuilder,
          $$CheckoutDraftTableUpdateCompanionBuilder,
          (
            CheckoutDraftRow,
            BaseReferences<
              _$AppDatabase,
              $CheckoutDraftTable,
              CheckoutDraftRow
            >,
          ),
          CheckoutDraftRow,
          PrefetchHooks Function()
        > {
  $$CheckoutDraftTableTableManager(_$AppDatabase db, $CheckoutDraftTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CheckoutDraftTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CheckoutDraftTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CheckoutDraftTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> localCartId = const Value.absent(),
                Value<String> step = const Value.absent(),
                Value<String?> customerId = const Value.absent(),
                Value<String?> deliveryMethod = const Value.absent(),
                Value<String?> receiverKind = const Value.absent(),
                Value<String?> paymentMethod = const Value.absent(),
                Value<String?> orderIdempotencyKey = const Value.absent(),
                Value<int?> submittedAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CheckoutDraftCompanion(
                localCartId: localCartId,
                step: step,
                customerId: customerId,
                deliveryMethod: deliveryMethod,
                receiverKind: receiverKind,
                paymentMethod: paymentMethod,
                orderIdempotencyKey: orderIdempotencyKey,
                submittedAt: submittedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String localCartId,
                required String step,
                Value<String?> customerId = const Value.absent(),
                Value<String?> deliveryMethod = const Value.absent(),
                Value<String?> receiverKind = const Value.absent(),
                Value<String?> paymentMethod = const Value.absent(),
                Value<String?> orderIdempotencyKey = const Value.absent(),
                Value<int?> submittedAt = const Value.absent(),
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => CheckoutDraftCompanion.insert(
                localCartId: localCartId,
                step: step,
                customerId: customerId,
                deliveryMethod: deliveryMethod,
                receiverKind: receiverKind,
                paymentMethod: paymentMethod,
                orderIdempotencyKey: orderIdempotencyKey,
                submittedAt: submittedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CheckoutDraftTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CheckoutDraftTable,
      CheckoutDraftRow,
      $$CheckoutDraftTableFilterComposer,
      $$CheckoutDraftTableOrderingComposer,
      $$CheckoutDraftTableAnnotationComposer,
      $$CheckoutDraftTableCreateCompanionBuilder,
      $$CheckoutDraftTableUpdateCompanionBuilder,
      (
        CheckoutDraftRow,
        BaseReferences<_$AppDatabase, $CheckoutDraftTable, CheckoutDraftRow>,
      ),
      CheckoutDraftRow,
      PrefetchHooks Function()
    >;
typedef $$SyncMetaTableCreateCompanionBuilder =
    SyncMetaCompanion Function({
      required String entity,
      Value<int?> lastSuccessAt,
      Value<String?> serverCursor,
      Value<String?> lastError,
      Value<int?> asOf,
      Value<int?> staleAfterSec,
      Value<int> rowid,
    });
typedef $$SyncMetaTableUpdateCompanionBuilder =
    SyncMetaCompanion Function({
      Value<String> entity,
      Value<int?> lastSuccessAt,
      Value<String?> serverCursor,
      Value<String?> lastError,
      Value<int?> asOf,
      Value<int?> staleAfterSec,
      Value<int> rowid,
    });

class $$SyncMetaTableFilterComposer
    extends Composer<_$AppDatabase, $SyncMetaTable> {
  $$SyncMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get entity => $composableBuilder(
    column: $table.entity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSuccessAt => $composableBuilder(
    column: $table.lastSuccessAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverCursor => $composableBuilder(
    column: $table.serverCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get asOf => $composableBuilder(
    column: $table.asOf,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get staleAfterSec => $composableBuilder(
    column: $table.staleAfterSec,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncMetaTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncMetaTable> {
  $$SyncMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get entity => $composableBuilder(
    column: $table.entity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSuccessAt => $composableBuilder(
    column: $table.lastSuccessAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverCursor => $composableBuilder(
    column: $table.serverCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get asOf => $composableBuilder(
    column: $table.asOf,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get staleAfterSec => $composableBuilder(
    column: $table.staleAfterSec,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncMetaTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncMetaTable> {
  $$SyncMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get entity =>
      $composableBuilder(column: $table.entity, builder: (column) => column);

  GeneratedColumn<int> get lastSuccessAt => $composableBuilder(
    column: $table.lastSuccessAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverCursor => $composableBuilder(
    column: $table.serverCursor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<int> get asOf =>
      $composableBuilder(column: $table.asOf, builder: (column) => column);

  GeneratedColumn<int> get staleAfterSec => $composableBuilder(
    column: $table.staleAfterSec,
    builder: (column) => column,
  );
}

class $$SyncMetaTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncMetaTable,
          SyncMetaRow,
          $$SyncMetaTableFilterComposer,
          $$SyncMetaTableOrderingComposer,
          $$SyncMetaTableAnnotationComposer,
          $$SyncMetaTableCreateCompanionBuilder,
          $$SyncMetaTableUpdateCompanionBuilder,
          (
            SyncMetaRow,
            BaseReferences<_$AppDatabase, $SyncMetaTable, SyncMetaRow>,
          ),
          SyncMetaRow,
          PrefetchHooks Function()
        > {
  $$SyncMetaTableTableManager(_$AppDatabase db, $SyncMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> entity = const Value.absent(),
                Value<int?> lastSuccessAt = const Value.absent(),
                Value<String?> serverCursor = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int?> asOf = const Value.absent(),
                Value<int?> staleAfterSec = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncMetaCompanion(
                entity: entity,
                lastSuccessAt: lastSuccessAt,
                serverCursor: serverCursor,
                lastError: lastError,
                asOf: asOf,
                staleAfterSec: staleAfterSec,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String entity,
                Value<int?> lastSuccessAt = const Value.absent(),
                Value<String?> serverCursor = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int?> asOf = const Value.absent(),
                Value<int?> staleAfterSec = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncMetaCompanion.insert(
                entity: entity,
                lastSuccessAt: lastSuccessAt,
                serverCursor: serverCursor,
                lastError: lastError,
                asOf: asOf,
                staleAfterSec: staleAfterSec,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncMetaTable,
      SyncMetaRow,
      $$SyncMetaTableFilterComposer,
      $$SyncMetaTableOrderingComposer,
      $$SyncMetaTableAnnotationComposer,
      $$SyncMetaTableCreateCompanionBuilder,
      $$SyncMetaTableUpdateCompanionBuilder,
      (SyncMetaRow, BaseReferences<_$AppDatabase, $SyncMetaTable, SyncMetaRow>),
      SyncMetaRow,
      PrefetchHooks Function()
    >;
typedef $$AppMetaTableCreateCompanionBuilder =
    AppMetaCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$AppMetaTableUpdateCompanionBuilder =
    AppMetaCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AppMetaTableFilterComposer
    extends Composer<_$AppDatabase, $AppMetaTable> {
  $$AppMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppMetaTableOrderingComposer
    extends Composer<_$AppDatabase, $AppMetaTable> {
  $$AppMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppMetaTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppMetaTable> {
  $$AppMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppMetaTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppMetaTable,
          AppMetaRow,
          $$AppMetaTableFilterComposer,
          $$AppMetaTableOrderingComposer,
          $$AppMetaTableAnnotationComposer,
          $$AppMetaTableCreateCompanionBuilder,
          $$AppMetaTableUpdateCompanionBuilder,
          (
            AppMetaRow,
            BaseReferences<_$AppDatabase, $AppMetaTable, AppMetaRow>,
          ),
          AppMetaRow,
          PrefetchHooks Function()
        > {
  $$AppMetaTableTableManager(_$AppDatabase db, $AppMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppMetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) =>
                  AppMetaCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppMetaTable,
      AppMetaRow,
      $$AppMetaTableFilterComposer,
      $$AppMetaTableOrderingComposer,
      $$AppMetaTableAnnotationComposer,
      $$AppMetaTableCreateCompanionBuilder,
      $$AppMetaTableUpdateCompanionBuilder,
      (AppMetaRow, BaseReferences<_$AppDatabase, $AppMetaTable, AppMetaRow>),
      AppMetaRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$LocalCategoriesTableTableManager get localCategories =>
      $$LocalCategoriesTableTableManager(_db, _db.localCategories);
  $$LocalProductsTableTableManager get localProducts =>
      $$LocalProductsTableTableManager(_db, _db.localProducts);
  $$LocalProductVariantsTableTableManager get localProductVariants =>
      $$LocalProductVariantsTableTableManager(_db, _db.localProductVariants);
  $$LocalUnitsTableTableManager get localUnits =>
      $$LocalUnitsTableTableManager(_db, _db.localUnits);
  $$LocalPackagingsTableTableManager get localPackagings =>
      $$LocalPackagingsTableTableManager(_db, _db.localPackagings);
  $$LocalBarcodesTableTableManager get localBarcodes =>
      $$LocalBarcodesTableTableManager(_db, _db.localBarcodes);
  $$LocalWarehousesTableTableManager get localWarehouses =>
      $$LocalWarehousesTableTableManager(_db, _db.localWarehouses);
  $$LocalPriceListsTableTableManager get localPriceLists =>
      $$LocalPriceListsTableTableManager(_db, _db.localPriceLists);
  $$LocalPricesTableTableManager get localPrices =>
      $$LocalPricesTableTableManager(_db, _db.localPrices);
  $$LocalStockBalancesTableTableManager get localStockBalances =>
      $$LocalStockBalancesTableTableManager(_db, _db.localStockBalances);
  $$LocalProductImagesMetaTableTableManager get localProductImagesMeta =>
      $$LocalProductImagesMetaTableTableManager(
        _db,
        _db.localProductImagesMeta,
      );
  $$LocalFavoritesProductsTableTableManager get localFavoritesProducts =>
      $$LocalFavoritesProductsTableTableManager(
        _db,
        _db.localFavoritesProducts,
      );
  $$LocalFavoritesCustomersTableTableManager get localFavoritesCustomers =>
      $$LocalFavoritesCustomersTableTableManager(
        _db,
        _db.localFavoritesCustomers,
      );
  $$CartDraftTableTableManager get cartDraft =>
      $$CartDraftTableTableManager(_db, _db.cartDraft);
  $$CartItemsDraftTableTableManager get cartItemsDraft =>
      $$CartItemsDraftTableTableManager(_db, _db.cartItemsDraft);
  $$OutboxActionsTableTableManager get outboxActions =>
      $$OutboxActionsTableTableManager(_db, _db.outboxActions);
  $$LocalRecentProductsTableTableManager get localRecentProducts =>
      $$LocalRecentProductsTableTableManager(_db, _db.localRecentProducts);
  $$NotificationsCacheTableTableManager get notificationsCache =>
      $$NotificationsCacheTableTableManager(_db, _db.notificationsCache);
  $$LocalSettingsTableTableManager get localSettings =>
      $$LocalSettingsTableTableManager(_db, _db.localSettings);
  $$RegistrationDraftTableTableManager get registrationDraft =>
      $$RegistrationDraftTableTableManager(_db, _db.registrationDraft);
  $$CheckoutDraftTableTableManager get checkoutDraft =>
      $$CheckoutDraftTableTableManager(_db, _db.checkoutDraft);
  $$SyncMetaTableTableManager get syncMeta =>
      $$SyncMetaTableTableManager(_db, _db.syncMeta);
  $$AppMetaTableTableManager get appMeta =>
      $$AppMetaTableTableManager(_db, _db.appMeta);
}

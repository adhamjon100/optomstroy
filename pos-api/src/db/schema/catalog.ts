// СГЕНЕРИРОВАНО test/db/codegen/gen-drizzle-schema.ts из каталога PostgreSQL 17 после migrations/*.sql
// (RM-C-006) — вручную не править: новая миграция → `npx tsx test/db/codegen/gen-drizzle-schema.ts`.
// Сверка с БД — test/db/migrate-seed.db-spec.ts («Drizzle-схема совпадает с БД»).

// Домен catalog (07 §5.B)

import { sql } from 'drizzle-orm';
import {
  boolean,
  char,
  integer,
  jsonb,
  numeric,
  pgTable,
  primaryKey,
  smallint,
  text,
  timestamp,
  uuid,
} from 'drizzle-orm/pg-core';
import { bytea, tsvector } from './types.js';
import { attributeValueTypeEnum, barcodeTypeEnum, imageStatusEnum, roleCodeEnum } from './enums.js';

/** categories — 07 §5.15 */
export const categories = pgTable('categories', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  parentId: uuid('parent_id'),
  name: text('name').notNull(),
  nameNorm: text('name_norm').generatedAlwaysAs(sql`norm_search(name)`),
  path: text('path').notNull(),
  depth: smallint('depth').notNull(),
  sortOrder: integer('sort_order')
    .notNull()
    .default(sql`0`),
  imageId: uuid('image_id'),
  iconKey: text('icon_key'),
  productCountCache: integer('product_count_cache')
    .notNull()
    .default(sql`0`),
  isVisible: boolean('is_visible')
    .notNull()
    .default(sql`true`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** products — 07 §5.16 */
export const products = pgTable('products', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  sku: text('sku'),
  skuNorm: text('sku_norm').generatedAlwaysAs(sql`norm_sku(sku)`),
  name: text('name').notNull(),
  fullName: text('full_name'),
  nameNorm: text('name_norm').generatedAlwaysAs(sql`norm_search(name)`),
  description: text('description'),
  brand: text('brand'),
  categoryId: uuid('category_id'),
  categoryPathText: text('category_path_text'),
  baseUnitId: uuid('base_unit_id').notNull(),
  hasVariants: boolean('has_variants')
    .notNull()
    .default(sql`false`),
  isWeighted: boolean('is_weighted')
    .notNull()
    .default(sql`false`),
  multiplicity: numeric('multiplicity', { precision: 14, scale: 3 }),
  minQty: numeric('min_qty', { precision: 14, scale: 3 }),
  attributes: jsonb('attributes')
    .notNull()
    .default(sql`'{}'::jsonb`),
  searchVector: tsvector('search_vector').generatedAlwaysAs(
    sql`(((setweight(to_tsvector('ru_unaccent'::regconfig, COALESCE(name, ''::text)), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE(sku, ''::text)), 'B'::"char")) || setweight(to_tsvector('ru_unaccent'::regconfig, ((COALESCE(brand, ''::text) || ' '::text) || COALESCE(category_path_text, ''::text))), 'C'::"char")) || setweight(to_tsvector('ru_unaccent'::regconfig, COALESCE(description, ''::text)), 'D'::"char"))`,
  ),
  primaryImageId: uuid('primary_image_id'),
  isSellable: boolean('is_sellable')
    .notNull()
    .default(sql`true`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  onecImageFileRef: uuid('onec_image_file_ref'),
});

/** product_variants — 07 §5.17 */
export const productVariants = pgTable('product_variants', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  productId: uuid('product_id').notNull(),
  isDefault: boolean('is_default')
    .notNull()
    .default(sql`false`),
  name: text('name')
    .notNull()
    .default(sql`''::text`),
  sku: text('sku'),
  skuNorm: text('sku_norm').generatedAlwaysAs(sql`norm_sku(sku)`),
  nameNorm: text('name_norm').generatedAlwaysAs(sql`norm_search(name)`),
  sortOrder: integer('sort_order')
    .notNull()
    .default(sql`0`),
  attributes: jsonb('attributes')
    .notNull()
    .default(sql`'{}'::jsonb`),
  primaryImageId: uuid('primary_image_id'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** product_attributes — 07 §5.18 */
export const productAttributes = pgTable('product_attributes', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  code: text('code').notNull(),
  name: text('name').notNull(),
  valueType: attributeValueTypeEnum('value_type').notNull(),
  unitLabel: text('unit_label'),
  isFilterable: boolean('is_filterable')
    .notNull()
    .default(sql`false`),
  isVariantAxis: boolean('is_variant_axis')
    .notNull()
    .default(sql`false`),
  sortOrder: integer('sort_order')
    .notNull()
    .default(sql`0`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** variant_attribute_values — 07 §5.19 */
export const variantAttributeValues = pgTable('variant_attribute_values', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  variantId: uuid('variant_id').notNull(),
  attributeId: uuid('attribute_id').notNull(),
  valueText: text('value_text'),
  valueTextNorm: text('value_text_norm').generatedAlwaysAs(sql`norm_search(value_text)`),
  valueNumber: numeric('value_number', { precision: 18, scale: 6 }),
  valueBool: boolean('value_bool'),
  onecValueRef: uuid('onec_value_ref'),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** units — 07 §5.20 */
export const units = pgTable('units', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  code: text('code').notNull(),
  name: text('name').notNull(),
  qtyPrecision: smallint('qty_precision').notNull(),
  isIntegerOnly: boolean('is_integer_only').generatedAlwaysAs(sql`(qty_precision = 0)`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** packagings — 07 §5.21 */
export const packagings = pgTable('packagings', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  productId: uuid('product_id'),
  packagingSetRef: uuid('packaging_set_ref'),
  unitId: uuid('unit_id').notNull(),
  name: text('name').notNull(),
  factor: numeric('factor', { precision: 14, scale: 3 }).notNull(),
  allowFraction: boolean('allow_fraction')
    .notNull()
    .default(sql`false`),
  isDefault: boolean('is_default')
    .notNull()
    .default(sql`false`),
  sortOrder: integer('sort_order')
    .notNull()
    .default(sql`0`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** barcodes — 07 §5.22 */
export const barcodes = pgTable('barcodes', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  value: text('value').notNull(),
  productId: uuid('product_id').notNull(),
  variantId: uuid('variant_id').notNull(),
  packagingId: uuid('packaging_id'),
  type: barcodeTypeEnum('type')
    .notNull()
    .default(sql`'other'::barcode_type`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** product_images — 07 §5.23 */
export const productImages = pgTable('product_images', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  productId: uuid('product_id'),
  variantId: uuid('variant_id'),
  categoryId: uuid('category_id'),
  sourceRef: text('source_ref').notNull(),
  sourceVersion: text('source_version'),
  checksumSha256: bytea('checksum_sha256'),
  storageKey: text('storage_key'),
  originalMime: text('original_mime'),
  originalBytes: integer('original_bytes'),
  width: integer('width'),
  height: integer('height'),
  sizes: jsonb('sizes'),
  sortOrder: integer('sort_order')
    .notNull()
    .default(sql`0`),
  isPrimary: boolean('is_primary')
    .notNull()
    .default(sql`false`),
  status: imageStatusEnum('status')
    .notNull()
    .default(sql`'pending'::image_status`),
  error: text('error'),
  attempts: smallint('attempts'),
  nextAttemptAt: timestamp('next_attempt_at', { withTimezone: true }),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  onecIsMain: boolean('onec_is_main'),
});

/** warehouses — 07 §5.24 */
export const warehouses = pgTable('warehouses', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  name: text('name').notNull(),
  shortName: text('short_name'),
  isActive: boolean('is_active')
    .notNull()
    .default(sql`true`),
  isDefaultForPos: boolean('is_default_for_pos')
    .notNull()
    .default(sql`false`),
  allowSales: boolean('allow_sales')
    .notNull()
    .default(sql`true`),
  sortOrder: integer('sort_order')
    .notNull()
    .default(sql`0`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** stock_balances — 07 §5.25 */
export const stockBalances = pgTable(
  'stock_balances',
  {
    variantId: uuid('variant_id').notNull(),
    warehouseId: uuid('warehouse_id').notNull(),
    quantity: numeric('quantity', { precision: 14, scale: 3 })
      .notNull()
      .default(sql`0`),
    reserved: numeric('reserved', { precision: 14, scale: 3 })
      .notNull()
      .default(sql`0`),
    availableOnec: numeric('available_onec', { precision: 14, scale: 3 }),
    available: numeric('available', { precision: 14, scale: 3 }).generatedAlwaysAs(
      sql`COALESCE(available_onec, (quantity - reserved))`,
    ),
    onecSnapshotAt: timestamp('onec_snapshot_at', { withTimezone: true }).notNull(),
    syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
    sourceHash: text('source_hash').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
  },
  (t) => [primaryKey({ name: 'stock_balances_pkey', columns: [t.variantId, t.warehouseId] })],
);

/** price_lists — 07 §5.26 */
export const priceLists = pgTable('price_lists', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  name: text('name').notNull(),
  currency: char('currency', { length: 3 })
    .notNull()
    .default(sql`'KGS'::bpchar`),
  priceIncludesVat: boolean('price_includes_vat'),
  isUsedForSales: boolean('is_used_for_sales')
    .notNull()
    .default(sql`true`),
  isDefault: boolean('is_default')
    .notNull()
    .default(sql`false`),
  visibleToRoles: roleCodeEnum('visible_to_roles')
    .array()
    .notNull()
    .default(sql`'{seller,cashier,senior_seller,admin,owner}'::role_code[]`),
  sortOrder: integer('sort_order')
    .notNull()
    .default(sql`0`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** prices — 07 §5.27 */
export const prices = pgTable('prices', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  variantId: uuid('variant_id').notNull(),
  priceListId: uuid('price_list_id').notNull(),
  packagingId: uuid('packaging_id'),
  price: numeric('price', { precision: 14, scale: 2 }).notNull(),
  validFrom: timestamp('valid_from', { withTimezone: true }),
  onecDocumentRef: uuid('onec_document_ref'),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

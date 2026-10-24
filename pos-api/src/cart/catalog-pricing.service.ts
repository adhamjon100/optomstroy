import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { Money } from '../common/money/money.js';
import type {
  CatalogPricingPort,
  SalesActor,
  SalesTx,
  VariantQuote,
  VariantQuoteRequest,
} from '../common/ports/index.js';
import { resolvePriceListId } from '../sales-domain/index.js';
import { qty3, rows } from './cart-common.js';

/** Упаковка строки (08 `Packaging`). */
export interface PackagingInfo {
  readonly id: string;
  readonly unitId: string;
  readonly name: string;
  readonly factor: string;
  readonly isDefault: boolean;
  readonly allowFraction: boolean;
  readonly barcode: string | null;
}

/**
 * Котировка строки корзины: `VariantQuote` порта + сведения для DTO корзины (единица, упаковка, фото, проверка
 * упаковки). Цена строки — за единицу количества строки: базовая единица, а для строки в упаковке — за упаковку
 * (`prices.packaging_id`, иначе цена базовой единицы × коэффициент, HALF_UP до 0.01; см. FQ-CART-04), поэтому
 * `quantity` строки и `order_items.quantity` — всегда число упаковок (10 INV-002), а `line_subtotal =
 * round_half_up(unit_price × quantity, 2)` (CHECK `order_items_line_subtotal_calc_chk`).
 */
export interface LineQuote extends VariantQuote {
  /** Вариант найден в реплике. */
  readonly found: boolean;
  readonly baseUnitId: string | null;
  /** Упаковка задана и относится к товару (не удалена). `true` для строк в базовой единице. */
  readonly packagingValid: boolean;
  readonly packaging: PackagingInfo | null;
  readonly imageSha: Buffer | null;
  readonly imageWidth: number | null;
  readonly imageHeight: number | null;
  readonly productOnecRef: string | null;
  readonly variantOnecRef: string | null;
  readonly packagingOnecRef: string | null;
}

interface QuoteRow {
  ord: string;
  variant_id: string;
  packaging_id: string | null;
  found: boolean;
  product_id: string | null;
  product_name: string | null;
  variant_name: string | null;
  is_default: boolean | null;
  sku: string | null;
  base_unit_id: string | null;
  unit_code: string | null;
  qty_precision: number | null; // money-double: allow — число знаков единицы (0…3), не количество
  multiplicity: string | null;
  min_qty: string | null;
  sellable: boolean | null;
  pk_id: string | null;
  pk_product: string | null;
  pk_unit: string | null;
  pk_name: string | null;
  pk_factor: string | null;
  pk_allow_fraction: boolean | null;
  pk_default: boolean | null;
  pk_deleted: boolean | null;
  pk_barcode: string | null;
  barcode: string | null;
  pack_price: string | null;
  base_price: string | null;
  available: string | null;
  img_sha: Buffer | null;
  img_w: number | null;
  img_h: number | null;
  product_ref: string | null;
  variant_ref: string | null;
  packaging_ref: string | null;
}

/**
 * `CatalogPricingPort` (агент F-be-cart): цены и сведения о вариантах по виду цены корзины — read-only запросы над
 * репликами каталога этапа E (`prices`, `product_variants`, `products`, `units`, `packagings`, `stock_balances`,
 * `product_images`; 06 §7.4 п. (а) «через данные»). Выбор вида цены — `resolvePriceListId` (10 INV-030, CUST-021).
 */
@Injectable()
export class CatalogPricingService implements CatalogPricingPort {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async resolvePriceList(actor: SalesActor, input: { readonly customerId: string | null }): Promise<string | null> {
    if (actor.userId === null) return null;
    return this.resolveFor(this.db, {
      userId: actor.userId,
      role: actor.roles[0] ?? (actor.isCustomer ? 'customer' : ''),
      isCustomer: actor.isCustomer,
      customerId: input.customerId,
    });
  }

  /** Вид цены корзины: клиент (видимый роли; для `customer` — при подтверждённой привязке) → `is_default` → розничный. */
  async resolveFor(
    ex: DbExecutor,
    i: { userId: string; role: string; isCustomer: boolean; customerId: string | null },
  ): Promise<string | null> {
    const r = await rows<{
      customer_pl: string | null;
      customer_pl_visible: boolean | null;
      link_confirmed: boolean;
      default_pl: string | null;
      retail_pl: string | null;
    }>(
      ex,
      sql`SELECT
            (SELECT pl.id FROM customers c JOIN price_lists pl ON pl.id = c.default_price_list_id AND NOT pl.deletion_mark
              WHERE c.id = ${i.customerId}::uuid AND NOT c.deletion_mark) AS customer_pl,
            (SELECT ${i.role}::text = ANY(pl.visible_to_roles::text[]) FROM customers c
               JOIN price_lists pl ON pl.id = c.default_price_list_id
              WHERE c.id = ${i.customerId}::uuid) AS customer_pl_visible,
            EXISTS (SELECT 1 FROM customer_links l WHERE l.user_id = ${i.userId}::uuid
                      AND l.customer_id = ${i.customerId}::uuid AND l.status = 'confirmed') AS link_confirmed,
            (SELECT x.id FROM price_lists x WHERE x.is_default AND NOT x.deletion_mark ORDER BY x.sort_order, x.id LIMIT 1) AS default_pl,
            (SELECT x.id FROM price_lists x WHERE NOT x.deletion_mark AND lower(x.name) LIKE 'розничн%'
              ORDER BY x.sort_order, x.name, x.id LIMIT 1) AS retail_pl`,
    );
    const row = r[0];
    if (!row) return null;
    return resolvePriceListId({
      isCustomerMode: i.isCustomer,
      linkConfirmed: row.link_confirmed,
      customerPriceListId: row.customer_pl,
      // Клиент-покупатель видит только свой вид цены (CUST-021): видимость ролям проверяется для сотрудников.
      customerPriceListVisible: i.isCustomer ? true : row.customer_pl_visible === true,
      defaultPriceListId: row.default_pl,
      retailPriceListId: row.retail_pl,
    }).id;
  }

  quote(
    tx: SalesTx | null,
    input: {
      readonly priceListId: string;
      readonly warehouseId: string;
      readonly items: readonly VariantQuoteRequest[];
    },
  ): Promise<readonly VariantQuote[]> {
    return this.lineQuotes(tx ?? this.db, input);
  }

  /** Котировки в порядке `items` (одна запись на запрос, в том числе для ненайденного варианта). */
  async lineQuotes(
    ex: DbExecutor,
    input: {
      readonly priceListId: string;
      readonly warehouseId: string;
      readonly items: readonly VariantQuoteRequest[];
    },
  ): Promise<LineQuote[]> {
    if (input.items.length === 0) return [];
    const variantIds = input.items.map((i) => i.variantId);
    const packagingIds = input.items.map((i) => i.packagingId);
    const res = await rows<QuoteRow>(
      ex,
      sql`WITH req AS (
            SELECT r.ord, r.variant_id, r.packaging_id
              FROM unnest(${sql.param(variantIds)}::uuid[], ${sql.param(packagingIds)}::uuid[]) WITH ORDINALITY AS r(variant_id, packaging_id, ord))
          SELECT req.ord::text AS ord, req.variant_id, req.packaging_id, v.id IS NOT NULL AS found,
                 p.id AS product_id, p.name AS product_name, v.name AS variant_name, v.is_default,
                 coalesce(v.sku, p.sku) AS sku, p.base_unit_id, u.code AS unit_code, u.qty_precision,
                 p.multiplicity::text AS multiplicity, p.min_qty::text AS min_qty,
                 (NOT v.deletion_mark AND NOT p.deletion_mark AND p.is_sellable AND v.is_default = NOT p.has_variants) AS sellable,
                 k.id AS pk_id, k.product_id AS pk_product, k.unit_id AS pk_unit, k.name AS pk_name,
                 k.factor::text AS pk_factor, k.allow_fraction AS pk_allow_fraction, k.is_default AS pk_default,
                 k.deletion_mark AS pk_deleted,
                 (SELECT b.value FROM barcodes b WHERE b.packaging_id = k.id AND NOT b.deletion_mark ORDER BY b.value LIMIT 1) AS pk_barcode,
                 (SELECT b.value FROM barcodes b WHERE b.variant_id = v.id AND b.packaging_id IS NULL AND NOT b.deletion_mark
                   ORDER BY b.value LIMIT 1) AS barcode,
                 pp.price::text AS pack_price, bp.price::text AS base_price,
                 sb.available::text AS available,
                 img.checksum_sha256 AS img_sha, img.width AS img_w, img.height AS img_h,
                 p.onec_ref::text AS product_ref, CASE WHEN v.is_default THEN NULL ELSE v.onec_ref::text END AS variant_ref,
                 k.onec_ref::text AS packaging_ref
            FROM req
            LEFT JOIN product_variants v ON v.id = req.variant_id
            LEFT JOIN products p ON p.id = v.product_id
            LEFT JOIN units u ON u.id = p.base_unit_id
            LEFT JOIN packagings k ON k.id = req.packaging_id
            LEFT JOIN prices pp ON req.packaging_id IS NOT NULL AND pp.variant_id = v.id
                 AND pp.price_list_id = ${input.priceListId}::uuid AND pp.packaging_id = req.packaging_id
            LEFT JOIN prices bp ON bp.variant_id = v.id AND bp.price_list_id = ${input.priceListId}::uuid AND bp.packaging_id IS NULL
            LEFT JOIN stock_balances sb ON sb.variant_id = v.id AND sb.warehouse_id = ${input.warehouseId}::uuid
            LEFT JOIN LATERAL (
              SELECT i.checksum_sha256, i.width, i.height FROM product_images i
               WHERE i.deleted_at IS NULL AND i.status = 'ready' AND i.checksum_sha256 IS NOT NULL
                 AND (i.variant_id = v.id OR (i.product_id = p.id AND i.variant_id IS NULL))
               ORDER BY (i.variant_id IS NOT NULL) DESC, i.is_primary DESC, i.sort_order, i.id LIMIT 1) img ON true
           ORDER BY req.ord`,
    );
    return res.map((r) => this.toQuote(r));
  }

  private toQuote(r: QuoteRow): LineQuote {
    const packagingRequested = r.packaging_id !== null;
    const packagingValid =
      !packagingRequested ||
      (r.pk_id !== null && r.pk_deleted === false && r.pk_product !== null && r.pk_product === r.product_id);
    const packaging: PackagingInfo | null =
      packagingRequested && r.pk_id !== null && r.pk_unit !== null && r.pk_factor !== null
        ? {
            id: r.pk_id,
            unitId: r.pk_unit,
            name: r.pk_name ?? '',
            factor: qty3(r.pk_factor),
            isDefault: r.pk_default === true,
            allowFraction: r.pk_allow_fraction === true,
            barcode: r.pk_barcode,
          }
        : null;
    let unitPrice: string | null = null;
    if (!packagingRequested) unitPrice = r.base_price !== null ? Money.of(r.base_price).toString() : null;
    else if (r.pack_price !== null) unitPrice = Money.of(r.pack_price).toString();
    else if (r.base_price !== null && r.pk_factor !== null)
      unitPrice = Money.of(r.base_price).times(r.pk_factor).toString();
    return {
      variantId: r.variant_id,
      productId: r.product_id ?? '',
      packagingId: r.packaging_id,
      unitPrice,
      pricePerPackaging: packagingRequested,
      packagingFactor: r.pk_factor !== null ? qty3(r.pk_factor) : null,
      unitId: packaging?.unitId ?? r.base_unit_id ?? '',
      unitCode: r.unit_code ?? '',
      qtyPrecision: packagingRequested ? 0 : (r.qty_precision ?? 0), // money-double: allow — число знаков, не количество
      multiplicity: r.multiplicity,
      minQty: r.min_qty,
      available: r.available,
      sellable: r.found && r.sellable === true && packagingValid,
      productName: r.product_name ?? '',
      variantName: r.is_default === false && r.variant_name ? r.variant_name : null,
      sku: r.sku,
      barcode: packagingRequested ? (r.pk_barcode ?? r.barcode) : r.barcode,
      packagingName: packaging?.name ?? null,
      found: r.found,
      baseUnitId: r.base_unit_id,
      packagingValid,
      packaging,
      imageSha: r.img_sha,
      imageWidth: r.img_w,
      imageHeight: r.img_h,
      productOnecRef: r.product_ref,
      variantOnecRef: r.variant_ref,
      packagingOnecRef: r.packaging_ref,
    };
  }
}

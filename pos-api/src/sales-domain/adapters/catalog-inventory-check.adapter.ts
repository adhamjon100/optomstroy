import { Injectable } from '@nestjs/common';
import { CatalogSnapshotService } from '../../catalog/common/catalog-snapshot.js';
import { CatalogViewerService } from '../../catalog/common/catalog-viewer.js';
import { InventoryService } from '../../catalog/inventory/inventory.service.js';
import { bySubjectKind } from '../../common/auth/subject-kind.js';
import type { InventoryCheckOutcome, InventoryCheckPort, SalesActor } from '../../common/ports/index.js';

/**
 * `InventoryCheckPort` поверх сервиса этапа E `InventoryService.check` (`POST /inventory/check`, 08 §4.6): те же
 * правила зрителя (`CatalogViewerService`: показ остатков `customer` по `customer_stock_display`), тот же разбор
 * единиц/упаковок и признак «недоступен» (нет варианта, снят с продажи, нет цены в виде цены корзины).
 *
 * Вид зрителя — `SalesActor.subjectKind` (06 ARCH-065; не пересобирается из `isCustomer`, иначе планшет магазина стал бы
 * покупателем режима клиента с проверкой `CUSTOMER_SELF_SERVICE`); построители до ADR-115 — по `isCustomer`. Планшету
 * склад зрителя — склад планшета (параметр `warehouseId` зрителю не передаётся: он для `kind=kiosk` — `403`), а склад
 * проверки — склад корзины (смена склада планшета действует со следующей корзины, 10 KIOSK-007).
 */
@Injectable()
export class CatalogInventoryCheckAdapter implements InventoryCheckPort {
  constructor(
    private readonly viewers: CatalogViewerService,
    private readonly inventory: InventoryService,
    private readonly snapshots: CatalogSnapshotService,
  ) {}

  async check(
    actor: SalesActor,
    input: {
      readonly warehouseId: string;
      readonly priceListId?: string | null;
      readonly items: readonly {
        readonly variantId: string;
        readonly value: string;
        readonly unitId: string;
        readonly packagingId: string | null;
      }[];
    },
  ): Promise<InventoryCheckOutcome> {
    if (actor.userId === null) throw new Error('InventoryCheckPort: проверка требует пользователя (зритель каталога)');
    const kind = actor.subjectKind ?? (actor.isCustomer ? 'customer' : 'staff');
    const kiosk = bySubjectKind(kind, { staff: false, customer: false, kiosk: true });
    const viewer = await this.viewers.resolve(
      {
        userId: actor.userId,
        kind,
        roles: actor.roles,
        ...(actor.sessionId ? { sessionId: actor.sessionId } : {}),
      },
      kiosk ? {} : { warehouseId: input.warehouseId },
    );
    // Вид цены корзины задаёт cart (клиент корзины), а не «зритель каталога» (INV-030).
    const effective =
      input.priceListId !== undefined && input.priceListId !== null
        ? { ...viewer, priceList: { id: input.priceListId, name: viewer.priceList?.name ?? '' } }
        : viewer;
    const r = await this.inventory.check(
      effective,
      { warehouseId: input.warehouseId, items: input.items.map((i) => ({ ...i })) },
      await this.snapshots.read(),
    );
    return {
      ok: r.ok,
      shortages: r.shortages.map((s) => ({ ...s })),
      unavailable: [...r.unavailable],
      ...(r.asOf ? { asOf: r.asOf } : {}),
    };
  }
}

import { Injectable } from '@nestjs/common';
import { CatalogSnapshotService } from '../../catalog/common/catalog-snapshot.js';
import { CatalogViewerService } from '../../catalog/common/catalog-viewer.js';
import { InventoryService } from '../../catalog/inventory/inventory.service.js';
import type { InventoryCheckOutcome, InventoryCheckPort, SalesActor } from '../../common/ports/index.js';

/**
 * `InventoryCheckPort` поверх сервиса этапа E `InventoryService.check` (`POST /inventory/check`, 08 §4.6): те же
 * правила зрителя (`CatalogViewerService`: показ остатков `customer` по `customer_stock_display`), тот же разбор
 * единиц/упаковок и признак «недоступен» (нет варианта, снят с продажи, нет цены в виде цены корзины).
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
    const viewer = await this.viewers.resolve(
      {
        userId: actor.userId,
        kind: actor.isCustomer ? 'customer' : 'staff',
        roles: actor.roles,
        ...(actor.sessionId ? { sessionId: actor.sessionId } : {}),
      },
      { warehouseId: input.warehouseId },
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

import { Module } from '@nestjs/common';
import { CatalogCommonModule } from '../common/catalog-common.module.js';
import { InventoryController } from './inventory.controller.js';
import { InventoryService } from './inventory.service.js';

/** `GET /inventory/balances`, `POST /inventory/check` (08 §4.6; RM-E-004). */
@Module({
  imports: [CatalogCommonModule],
  controllers: [InventoryController],
  providers: [InventoryService],
  exports: [InventoryService],
})
export class InventoryModule {}

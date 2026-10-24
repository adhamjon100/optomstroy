import type { SyncEntity } from '../../common/enums.js';
import { ONEC_TYPE } from '../../integrations/onec/onec-catalog.types.js';
import type { ApplyScope, ChangeItemHandler } from '../apply/apply.types.js';
import { entryFromChangeItem } from './image-sources.js';
import type { ImageFileEntry } from './image.types.js';
import { ProductImageRepository } from './product-image.repository.js';

/**
 * Обработчик элементов `/changes` типа `Catalog_НоменклатураПрисоединенныеФайлы` и их `ObjectDeletion`
 * (05 §6.2, ONEC-006, SYNC-035; RM-E-003). Выполняется в транзакции сообщения после применения каталога —
 * владельцы-товары этого же сообщения уже записаны. Регистрирует файлы в `product_images` (`pending`), байты не
 * скачивает: скачивание и WebP — ежесуточный прогон `images` (`ImageSyncService`), чтобы сообщение плана обмена
 * не ждало HTTP к 1С и sharp.
 *
 * Прогон `sync_runs` для `images` здесь **не** открывается (`entityOf` → `undefined`): singleton прогона фото
 * занят ежесуточным скачиванием, и его захват откатывал бы всё сообщение (SYNC-023). Ошибки позиций пишутся в
 * `sync_errors` (entity `images`, без `sync_run_id`) в той же транзакции.
 */
export class ProductImageFilesHandler implements ChangeItemHandler {
  readonly types: readonly string[] = [ONEC_TYPE.imageFile];

  constructor(
    private readonly repo = new ProductImageRepository(),
    private readonly onRegistered?: (affectedProducts: ReadonlySet<string>) => void,
  ) {}

  entityOf(_item: Readonly<Record<string, unknown>>): SyncEntity | undefined {
    return undefined;
  }

  async apply(scope: ApplyScope, items: readonly Readonly<Record<string, unknown>>[]): Promise<void> {
    const entries: ImageFileEntry[] = [];
    for (const it of items) {
      const e = entryFromChangeItem(it);
      if (e) entries.push(e);
    }
    if (entries.length === 0) return;
    const res = await this.repo.register(scope.client, entries);
    // Снятая привязка/пометка удаления меняет главное фото сразу (без ожидания ночного прогона).
    await this.repo.refreshPrimary(scope.client, res.affectedProducts);
    await this.repo.writeErrors(scope.client, res.errors, null);
    this.onRegistered?.(res.affectedProducts);
  }
}

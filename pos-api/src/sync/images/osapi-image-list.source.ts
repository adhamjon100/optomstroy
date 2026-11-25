import type { OnecOsApiClient } from '../../integrations/onec/onec-osapi.client.js';
import { osApiRef } from '../../integrations/onec/onec-osapi.client.js';
import { OsApiCatalogIndex } from '../../integrations/onec/onec-osapi.mapping.js';
import type { ImageFileEntry } from './image.types.js';
import { type ImageListSource, onecFileVersion } from './image-sources.js';

/**
 * Список фото `ONEC_MODE=os_api` (ADR-126): `GET /item-files` ОС_API — присоединённые файлы-картинки товаров и
 * характеристик без помеченных на удаление (Module.bsl:1023-1099; исчезнувший файл помечает ночная сверка списка).
 * Владелец: фото товара — товар (`itemId`), фото характеристики товара — вариант (ссылка характеристики). Версия
 * файла — `changedAt|size` (05 ONEC-006). Байты — `OnecOsApiGateway.getImage`.
 *
 * Фото характеристики КАТЕГОРИИ не привязывается: `itemId` у файла характеристики — её `Владелец`, только если это
 * `СправочникСсылка.Номенклатура` (Module.bsl:1048-1050, 1081-1082), у характеристики категории — `null`, а вариант
 * в модели есть только у пары «характеристика × товар» (производная ссылка `OsApiCatalogSource`); один файл
 * (`source_ref`) не может принадлежать нескольким вариантам. Так же — характеристика владельца `unitSet`/`other`
 * или неизвестная `/characteristics`. Такие файлы пропускаются намеренно (одно предупреждение за прогон), а не
 * отдаются с владельцем, которого нет в реплике (иначе `NOT_FOUND_LOCAL` на каждом прогоне).
 */
export class OsApiImageListSource implements ImageListSource {
  readonly name = 'osapi:/item-files';

  constructor(
    private readonly client: Pick<OnecOsApiClient, 'itemFiles' | 'characteristics'>,
    private readonly log?: { warn(obj: object, msg: string): void },
  ) {}

  async *list(signal?: AbortSignal): AsyncIterable<readonly ImageFileEntry[]> {
    const opts = signal ? { signal } : undefined;
    const files = await this.client.itemFiles(opts);
    const hasCharacteristicFiles = files.items.some((f) => f.kind === 'characteristic');
    const index = new OsApiCatalogIndex(
      [],
      hasCharacteristicFiles ? (await this.client.characteristics(opts)).items : [],
    );
    if (signal?.aborted) return;
    const out: ImageFileEntry[] = [];
    let skipped = 0;
    for (const f of files.items) {
      const sourceRef = osApiRef(f.id);
      if (!sourceRef) continue;
      let ownerRef: string | null;
      if (f.kind === 'characteristic') {
        const owner = index.characteristicOwner(f.characteristicId);
        const item = osApiRef(f.itemId);
        // Вариант в реплике есть только у характеристики товара (её ссылка) или пары «характеристика категории ×
        // товар»; второе ОС_API не отдаёт (itemId = null у характеристики категории).
        if (owner === 'item' || (owner === 'category' && item)) {
          ownerRef = index.variantRef(f.itemId, f.characteristicId);
        } else {
          skipped++;
          continue;
        }
      } else {
        ownerRef = osApiRef(f.itemId);
      }
      out.push({
        sourceRef,
        ownerRef,
        sourceVersion: onecFileVersion(f.changedAt ?? null, f.size ?? null),
        sortOrder: 0,
        deletionMark: false,
        ...(typeof f.isMain === 'boolean' ? { isMain: f.isMain } : {}),
      });
    }
    if (skipped > 0) {
      this.log?.warn(
        { entity: 'images', skipped },
        'osapi.characteristic_file_skipped: фото характеристик категории (или владельца вне модели) не привязываются — пропущены',
      );
    }
    yield out;
  }
}

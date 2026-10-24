import { fileURLToPath } from 'node:url';

/**
 * Расположение шаблонов и шрифтов печатных форм: `pos-api/assets/templates/pdf/*.json` (замена без изменения кода,
 * Q-019) и `pos-api/assets/fonts/Inter-*.ttf` (OFL). Путь вычисляется от этого файла и одинаков для `src/` (dev,
 * тесты) и `dist/` (сборка): `src|dist/orders/documents` → `../../../assets`. Тесты подменяют токен своим каталогом.
 */
export const DOCUMENT_ASSETS = 'orders.documents.assets' as const;

export interface DocumentAssets {
  readonly templatesDir: string;
  readonly fontRegular: string;
  readonly fontBold: string;
}

export function defaultDocumentAssets(): DocumentAssets {
  const root = new URL('../../../assets/', import.meta.url);
  return {
    templatesDir: fileURLToPath(new URL('templates/pdf/', root)),
    fontRegular: fileURLToPath(new URL('fonts/Inter-Regular.ttf', root)),
    fontBold: fileURLToPath(new URL('fonts/Inter-Bold.ttf', root)),
  };
}

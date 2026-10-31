// Преобразования файлов виртуальной fs при сборке (точка расширения build-vfs.mjs, WP-B1 → WP-B3).
// Водяной знак «ДЕМО · тестовые данные · не фискальный документ» первым блоком шаблонов PDF (plan §3.7).
import { watermarkTemplate } from '../demo-overlay.mjs';

const PDF_TEMPLATE = /^\/vfs\/pos-api\/assets\/templates\/pdf\/[^/]+\.json$/;

export const transforms = [
  (key, buf) => (PDF_TEMPLATE.test(key) ? Buffer.from(watermarkTemplate(buf.toString('utf8')), 'utf8') : undefined),
];

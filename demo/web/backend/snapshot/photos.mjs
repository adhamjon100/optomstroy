// Синтетические «фото» товаров для снимка веб-демо (WP-B4; plan §3.5 шаг 5). Только Node и только при сборке:
// sharp из pos-api/node_modules. Это не фото товаров, а заглушки: мягкий фон в цвете категории, простая фигура,
// артикул и подпись «ДЕМО · фото-заглушка». Байты детерминированы (тот же sharp, тот же текст → тот же JPEG), поэтому
// sha256 исходника, а с ним адреса /images/{sha}/… и снимок не меняются от пересборки.
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { NM } from '../lib/paths.mjs';

const require = createRequire(`${NM}/`);
const sharp = require('sharp');

/** Палитра фона/фигуры (светлый фон, насыщенная фигура) — по категории. */
const PALETTE = [
  ['#EAF1FB', '#1F5FAE'],
  ['#FDEEE9', '#D9380F'],
  ['#E7F6EE', '#177245'],
  ['#FFF4E0', '#8A5300'],
  ['#F1ECFB', '#5B3FA8'],
  ['#E6F5F7', '#11707E'],
  ['#F3F1EC', '#5B6478'],
  ['#FBEAF1', '#A3245A'],
];
const esc = (s) => String(s).replace(/[<>&"']/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[c]);
const hash = (s) => createHash('sha256').update(s).digest();

function shape(kind, fg) {
  switch (kind) {
    case 0:
      return `<circle cx="320" cy="200" r="112" fill="${fg}" opacity="0.88"/><rect x="262" y="150" width="116" height="100" rx="16" fill="#FFFFFF" opacity="0.92"/>`;
    case 1:
      return `<rect x="208" y="92" width="224" height="216" rx="36" fill="${fg}" opacity="0.88"/><circle cx="320" cy="200" r="58" fill="#FFFFFF" opacity="0.92"/>`;
    case 2:
      return `<polygon points="320,82 424,142 424,262 320,322 216,262 216,142" fill="${fg}" opacity="0.88"/><rect x="286" y="150" width="68" height="100" rx="12" fill="#FFFFFF" opacity="0.92"/>`;
    default:
      return `<path d="M320 78 C 382 168, 426 214, 426 252 A 106 106 0 0 1 214 252 C 214 214, 258 168, 320 78 Z" fill="${fg}" opacity="0.88"/><circle cx="320" cy="250" r="44" fill="#FFFFFF" opacity="0.92"/>`;
  }
}

/** JPEG 640×480 для товара: { sku, category, index }. */
export async function syntheticPhoto({ sku, category, index }) {
  const h = hash(`${category}`);
  const [bg, fg] = PALETTE[h[0] % PALETTE.length];
  const label = esc(String(sku ?? `#${index + 1}`).slice(0, 24));
  const cat = esc(String(category ?? '').slice(0, 32));
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480">
  <rect width="640" height="480" fill="${bg}"/>
  ${shape(index % 4, fg)}
  <text x="320" y="378" font-family="Arial, sans-serif" font-size="36" font-weight="bold" text-anchor="middle" fill="#0E1456">${label}</text>
  <text x="320" y="414" font-family="Arial, sans-serif" font-size="20" text-anchor="middle" fill="#5B6478">${cat}</text>
  <text x="320" y="452" font-family="Arial, sans-serif" font-size="18" text-anchor="middle" fill="#656E80">ДЕМО · фото-заглушка</text>
</svg>`;
  return sharp(Buffer.from(svg)).jpeg({ quality: 82, mozjpeg: false }).toBuffer();
}

export const sharpVersion = () => sharp.versions?.sharp ?? null;

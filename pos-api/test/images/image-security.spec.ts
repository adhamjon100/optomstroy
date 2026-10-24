import { deflateSync, crc32 } from 'node:zlib';
import sharp from 'sharp';
import {
  ACCEPTED_SOURCE_FORMATS,
  DEFAULT_LIMIT_INPUT_PIXELS,
  ImageDecodeError,
  MAX_SOURCE_BYTES,
  MAX_SOURCE_SIDE_PX,
  processImage,
} from '../../src/sync/images/index.js';
import { syntheticJpeg, syntheticPng } from './support/image-fixtures.js';

/**
 * T-SEC-046 (12, класс A; 11 SEC-101, SEC-102; AC-SEC-101/102; ревью E-trace-4): валидация фото из 1С —
 * allowlist форматов по содержимому (JPEG/PNG/WebP/GIF), исходник ≤ 10 МБ, стороны ≤ 8000 px, защита от бомбы
 * распаковки, EXIF/GPS не переносятся в выдаваемые размеры. **Тестовые данные** — синтетические изображения.
 * Раздача (traversal `/images/../…`, листинг `/images/` → 404, `nosniff`) — test/images/caddyfile.spec.ts.
 */

async function rejection(data: Uint8Array): Promise<ImageDecodeError> {
  const e = await processImage(data).catch((x: unknown) => x);
  expect(e).toBeInstanceOf(ImageDecodeError);
  return e as ImageDecodeError;
}

/** PNG только с заголовком IHDR заданных размеров и пустым IDAT — «бомба»: файл крошечный, пикселей миллиард. */
function pngHeaderOnly(w: number, h: number): Buffer {
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td) >>> 0);
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(Buffer.alloc(0))),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

describe('T-SEC-046: фото из 1С — вредоносные и недопустимые файлы (SEC-101, SEC-102)', () => {
  it('пороги SEC-101: allowlist JPEG/PNG/WebP/GIF, 10 МБ, 8000×8000, предел пикселей = 64 Мп', () => {
    expect([...ACCEPTED_SOURCE_FORMATS].sort()).toEqual(['gif', 'jpeg', 'png', 'webp']);
    expect(MAX_SOURCE_BYTES).toBe(10 * 1024 * 1024);
    expect(MAX_SOURCE_SIDE_PX).toBe(8000);
    expect(DEFAULT_LIMIT_INPUT_PIXELS).toBe(64_000_000);
  });

  it('«.jpg» с HTML/SVG внутри → отказ (формат определяется по содержимому, SVG не в allowlist)', async () => {
    const html = Buffer.from('<html><body><script>alert(1)</script></body></html>', 'utf8');
    expect((await rejection(html)).reason).toMatch(/unsupported_format|corrupt/);
    const svg = Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>alert(1)</script><rect width="10" height="10"/></svg>',
      'utf8',
    );
    expect((await rejection(svg)).reason).toBe('unsupported_format');
  });

  it('TIFF (вне allowlist) → unsupported_format', async () => {
    const tiff = await sharp({ create: { width: 20, height: 10, channels: 3, background: '#808080' } })
      .tiff()
      .toBuffer();
    expect((await rejection(tiff)).reason).toBe('unsupported_format');
  });

  it('AC-SEC-101: PNG больше 10 МБ (в т. ч. 50 МБ) → too_large до декодирования', async () => {
    const png = await syntheticPng(10, 10, 1);
    const big = Buffer.concat([png, Buffer.alloc(MAX_SOURCE_BYTES + 1 - png.length)]);
    expect((await rejection(big)).reason).toBe('too_large');
    expect((await rejection(Buffer.alloc(50 * 1024 * 1024, 1))).reason).toBe('too_large');
  });

  it('стороны больше 8000 px (9000×100 и 9000×9000) → too_large', async () => {
    const wide = await sharp({ create: { width: 9000, height: 100, channels: 3, background: '#336699' } })
      .png()
      .toBuffer();
    expect((await rejection(wide)).reason).toBe('too_large');
    expect((await rejection(pngHeaderOnly(9000, 9000))).reason).toBe('too_large');
  });

  it('бомба распаковки (заголовок 40000×40000 в файле < 1 КБ) → too_large, без выделения памяти под пиксели', async () => {
    const bomb = pngHeaderOnly(40_000, 40_000);
    expect(bomb.length).toBeLessThan(1024);
    expect((await rejection(bomb)).reason).toBe('too_large');
  });

  it('EXIF/GPS исходника не переносятся в thumb/card/full (SEC-102)', async () => {
    const base = await syntheticJpeg(1600, 1200, 5);
    const withExif = await sharp(base)
      .withExif({ IFD0: { Make: 'TestCam', Copyright: 'secret-owner' }, IFD3: { GPSLatitudeRef: 'N' } })
      .jpeg()
      .toBuffer();
    expect((await sharp(withExif).metadata()).exif).toBeDefined();
    const img = await processImage(withExif);
    expect(img.renders.map((r) => r.name).sort()).toEqual(['card', 'full', 'thumb']);
    for (const r of img.renders) {
      const m = await sharp(r.data).metadata();
      expect(m.format, r.name).toBe('webp');
      expect(m.exif, r.name).toBeUndefined();
      expect(m.icc === undefined || m.icc.length > 0).toBe(true);
      expect(r.data.includes(Buffer.from('secret-owner'))).toBe(false);
    }
  });

  it('допустимые файлы проходят: JPEG 8000×10 (граница), PNG, WebP, GIF', async () => {
    const edge = await sharp({ create: { width: 8000, height: 10, channels: 3, background: '#112233' } })
      .jpeg()
      .toBuffer();
    expect((await processImage(edge)).width).toBe(8000);
    const make = (f: 'png' | 'webp' | 'gif') =>
      sharp({ create: { width: 30, height: 20, channels: 3, background: '#445566' } })
        .toFormat(f)
        .toBuffer();
    for (const f of ['png', 'webp', 'gif'] as const) expect((await processImage(await make(f))).height).toBe(20);
  });
});

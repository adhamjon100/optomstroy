import { deflateSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { parsePdf } from './support/pdf-text.js';

/**
 * Разбор PDF в тестах (`support/pdf-text.ts`): поток FlateDecode, чьи сжатые данные оканчиваются байтом 0x0A/0x0D,
 * читается по `/Length` целиком. Прежний разбор срезал все хвостовые 0x0A/0x0D — inflate падал «unexpected end of
 * file» (нестабильность documents.e2e «DocumentsPort.render …» в прогоне `test:cov:f`, ревью F раунд 2).
 */
function pdfWithContent(data: Buffer): Buffer {
  const parts = [
    '%PDF-1.3\n',
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n',
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 226.77 400] /Contents 4 0 R >>\nendobj\n',
  ].map((x) => Buffer.from(x, 'latin1'));
  const head = Buffer.from(`4 0 obj\n<< /Length ${data.length} /Filter /FlateDecode >>\nstream\n`, 'latin1');
  const tail = Buffer.from('\nendstream\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n', 'latin1');
  return Buffer.concat([...parts, head, data, tail]);
}

describe('test/documents/support/pdf-text.ts', () => {
  it.each([0x0a, 0x0d])('сжатый поток, оканчивающийся байтом 0x%s, разбирается по /Length', (last) => {
    let data: Buffer | null = null;
    for (let i = 0; i < 20_000 && !data; i++) {
      const pad = 'x'.repeat(i % 251);
      const d = deflateSync(Buffer.from(`BT /F1 12 Tf 10 10 Td (line ${i}${pad}) Tj ET`, 'latin1'));
      if (d[d.length - 1] === last) data = d;
    }
    expect(data).not.toBeNull();
    const pdf = parsePdf(pdfWithContent(data!));
    expect(pdf.pages).toEqual([{ width: 226.77, height: 400 }]);
  });
});

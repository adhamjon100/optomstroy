import { createCipheriv, createDecipheriv, createHmac } from 'node:crypto';

/**
 * Шифрование содержимого курсора keyset-пагинации (AES-256-GCM): курсор непрозрачен не только по форме, но и по
 * содержанию. В курсоре лежат значения ключа сортировки последней строки (например, `available` при
 * `sort=available:desc`), а `customer` при `customer_stock_display=status` количеств получать не должен (08 §3.6,
 * 10 CUST-022, 07 DATA-124, 11 §4.4; ревью E-api-1). GCM даёт и целостность (подделка → ошибка расшифровки).
 *
 * IV детерминирован (первые 12 байт HMAC-SHA256(key, plaintext)) — одинаковые страницы дают одинаковый курсор
 * (стабильные ETag); раскрывается только факт равенства двух курсоров, не их содержимое.
 */
const IV_LEN = 12;
const TAG_LEN = 16;

export function sealCursor(key: Buffer, aad: string, plain: string): string {
  const iv = createHmac('sha256', key).update(aad).update('\0').update(plain).digest().subarray(0, IV_LEN);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(Buffer.from(aad, 'utf8'));
  const ct = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  return Buffer.concat([iv, ct, cipher.getAuthTag()]).toString('base64url');
}

/** Расшифровка; `undefined` — повреждён, подделан или выдан с другим ключом/назначением. */
export function openCursor(key: Buffer, aad: string, token: string): string | undefined {
  if (!/^[A-Za-z0-9_-]+$/.test(token)) return undefined;
  const buf = Buffer.from(token, 'base64url');
  // Только каноническая запись: лишний «хвостовой» символ base64url декодировался бы в те же байты.
  if (buf.length < IV_LEN + TAG_LEN + 1 || buf.toString('base64url') !== token) return undefined;
  try {
    const decipher = createDecipheriv('aes-256-gcm', key, buf.subarray(0, IV_LEN));
    decipher.setAAD(Buffer.from(aad, 'utf8'));
    decipher.setAuthTag(buf.subarray(buf.length - TAG_LEN));
    return Buffer.concat([decipher.update(buf.subarray(IV_LEN, buf.length - TAG_LEN)), decipher.final()]).toString(
      'utf8',
    );
  } catch {
    return undefined;
  }
}

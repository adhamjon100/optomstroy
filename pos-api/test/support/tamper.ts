/**
 * Подделка подписанных значений в тестах (курсоры, токены, MAC, подписи): символ `s[index]` меняется на соседний
 * символ того же класса — `A`↔`B`, …, `Y`↔`Z`, `a`↔`b`, …, `0`↔`1`, …, `8`↔`9`, `-`↔`_`.
 *
 * - Результат **всегда** отличается от исходной строки. Запись фиксированного символа (`x${sig.slice(1)}`,
 *   `${mac.slice(0, -2)}00`) совпадает с настоящим значением, если оно уже начинается или кончается этим символом:
 *   1 раз из 64 для base64url, 1 из 256 для двух hex-знаков — тест «подделки» тогда получает 200 вместо 400.
 * - Алфавит сохраняется: hex остаётся hex, base64url — base64url. Проверяется сама подпись, а не формат строки.
 * - В base64url замена меняет младший бит 6-битного значения. Все символы, кроме последнего, несут только биты данных,
 *   поэтому меняются и декодированные байты. Последний символ может нести лишь биты дополнения — для проверок по
 *   байтам берите не последний символ (по умолчанию — первый).
 *
 * `index < 0` отсчитывается от конца строки, как у `String.prototype.at`.
 */
export function tamperChar(s: string, index = 0): string {
  const i = index < 0 ? s.length + index : index;
  if (!Number.isInteger(i) || i < 0 || i >= s.length) {
    throw new RangeError(`tamperChar: позиции ${index} нет в строке длиной ${s.length}`);
  }
  return `${s.slice(0, i)}${sibling(s.charAt(i))}${s.slice(i + 1)}`;
}

function sibling(c: string): string {
  if (c === '-') return '_';
  if (c === '_') return '-';
  for (const [first, size] of [
    ['A', 26],
    ['a', 26],
    ['0', 10],
  ] as const) {
    const offset = c.charCodeAt(0) - first.charCodeAt(0);
    if (offset >= 0 && offset < size) return String.fromCharCode(first.charCodeAt(0) + (offset ^ 1));
  }
  throw new RangeError(
    `tamperChar: символ «${c}» не из алфавита base64url/hex — подделывайте подпись, а не разделитель`,
  );
}

import { BlockList, isIP } from 'node:net';

/**
 * Разбор списка IP/подсетей через запятую (`203.0.113.5, 198.51.100.0/24, 2001:db8::/32`) в `BlockList`; пустой
 * список → `null` (проверки нет). Неверный элемент — исключение (env.schema.ts проверяет формат до старта).
 */
export function parseIpAllowlist(raw: string | undefined, name: string): BlockList | null {
  const items = (raw ?? '')
    .split(',')
    .map((x) => x.trim())
    .filter((x) => x !== '');
  if (items.length === 0) return null;
  const list = new BlockList();
  for (const item of items) {
    const [addr, prefix] = item.split('/');
    const family = isIP(addr ?? '');
    if (family === 0) throw new Error(`${name}: неверный адрес «${item}»`);
    const type = family === 6 ? 'ipv6' : 'ipv4';
    if (prefix !== undefined)
      list.addSubnet(addr, Number(prefix), type); // money-double: allow — длина префикса
    else list.addAddress(addr, type);
  }
  return list;
}

/** IPv4-mapped IPv6 (`::ffff:203.0.113.5`) → IPv4; пусто → ''. */
export function normalizeClientIp(ip: string | undefined | null): string {
  if (!ip) return '';
  const m = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  return m ? m[1] : ip;
}

export function ipAllowed(list: BlockList, ip: string): boolean {
  const family = isIP(ip);
  if (family === 0) return false;
  return list.check(ip, family === 6 ? 'ipv6' : 'ipv4');
}

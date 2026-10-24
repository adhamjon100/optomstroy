import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse as parseYaml } from 'yaml';
import { OPENAPI_INFO_VERSION } from './openapi.document.js';

/** Ревью E RC-3/RS-11: версия генерируемого /openapi.json совпадает с info.version источника истины. */
const contract = parseYaml(
  readFileSync(fileURLToPath(new URL('../../../contracts/openapi/pos-api.v1.yaml', import.meta.url)), 'utf8'),
) as { info: { version: string } };

describe('openapi.document ↔ contracts/openapi/pos-api.v1.yaml', () => {
  it('OPENAPI_INFO_VERSION = info.version контракта', () => {
    expect(OPENAPI_INFO_VERSION).toBe(contract.info.version);
  });
});

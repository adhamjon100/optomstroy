import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as enums from './enums.js';

/** RM-C-005 п. 2 / RM-B-009: сгенерированный common/enums.ts совпадает с contracts/enums.json. */
interface EnumsJson {
  version: string;
  dbEnums: { name: string; values: string[] }[];
  checkLists: { name: string; values: string[]; columns: string[] }[];
  apiEnums: { name: string; values: string[] }[];
  problemCodes: { code: string; http: number[] }[];
}

const contract = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../../contracts/enums.json', import.meta.url)), 'utf8'),
) as EnumsJson;

const exported = enums as unknown as Record<string, unknown>;
const valuesOf = (name: string): unknown => exported[`${name.toUpperCase()}_VALUES`];

describe('common/enums.ts ↔ contracts/enums.json', () => {
  it('версия контракта', () => {
    expect(enums.ENUMS_CONTRACT_VERSION).toBe(contract.version);
  });

  it.each([
    ['dbEnums', contract.dbEnums],
    ['checkLists', contract.checkLists],
    ['apiEnums', contract.apiEnums],
  ] as const)('%s: те же перечни, значения и порядок', (_group, list) => {
    for (const e of list) expect(valuesOf(e.name), e.name).toEqual(e.values);
  });

  it('DB_ENUMS и CHECK_LISTS (реестры) покрывают все перечни контракта', () => {
    expect(Object.keys(enums.DB_ENUMS)).toEqual(contract.dbEnums.map((e) => e.name));
    for (const e of contract.checkLists) {
      for (const col of e.columns) expect((enums.CHECK_LISTS as Record<string, unknown>)[col], col).toEqual(e.values);
    }
  });

  it('Problem.code: закрытый перечень 08 §2.4 и HTTP-статусы', () => {
    expect([...enums.PROBLEM_CODE_VALUES]).toEqual(contract.problemCodes.map((p) => p.code));
    for (const p of contract.problemCodes) {
      expect(enums.PROBLEM_CODE_HTTP_STATUS[p.code as enums.ProblemCode]).toEqual(p.http);
    }
    expect(enums.isProblemCode('APP_READ_ONLY')).toBe(true);
    expect(enums.isProblemCode('NOPE')).toBe(false);
  });
});

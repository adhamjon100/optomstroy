import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Шаблон печатной формы (RM-F-004; Q-019 — реквизиты и вид форм уточняются заказчиком): JSON-файл
 * `assets/templates/pdf/<kind>.<paper>.json`, отдельный от кода, — замена шаблона не требует изменения кода.
 * Геометрия — в пунктах PDF (1 pt = 1/72 дюйма; 80 мм = 226,77 pt). Подстановки `{{путь}}` берутся из модели
 * документа (`document-model.ts`); `when: "путь"` — блок/строка выводится, только если значение непустое.
 * Числа шаблона — геометрия и кегль, не деньги (деньги приходят в модель уже отформатированными строками).
 */
export type DocumentKindRendered = 'invoice' | 'receipt';
export type PaperFormatRendered = 'a4' | 'thermal80';
export type TextAlign = 'left' | 'center' | 'right';

export interface TemplateMargins {
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
  readonly left: number;
}

export interface TemplatePage {
  readonly width: number;
  /** Нет высоты — одна непрерывная страница по длине содержимого (чековая лента 80 мм). */
  readonly height?: number;
  readonly margins: TemplateMargins;
}

interface BlockBase {
  readonly when?: string;
  /** Отступ после блока, pt (по умолчанию 4). */
  readonly gapAfter?: number;
}

export interface TextBlock extends BlockBase {
  readonly type: 'text';
  readonly text: string;
  readonly size?: number;
  readonly bold?: boolean;
  readonly align?: TextAlign;
}

export interface FieldRow {
  readonly label: string;
  readonly value: string;
  readonly when?: string;
  readonly bold?: boolean;
}

/** Строки «подпись — значение» (реквизиты, итоги). `labelWidth` — доля ширины под подпись. */
export interface FieldsBlock extends BlockBase {
  readonly type: 'fields';
  readonly rows: readonly FieldRow[];
  readonly labelWidth: number;
  readonly size?: number;
  readonly valueAlign?: TextAlign;
  readonly labelAlign?: TextAlign;
}

export interface TableColumn {
  readonly header: string;
  readonly value: string;
  /** Доля ширины области содержимого; сумма долей колонок ≤ 1. */
  readonly width: number;
  readonly align?: TextAlign;
}

export interface TableBlock extends BlockBase {
  readonly type: 'table';
  /** Путь к массиву строк модели (например, `items`). */
  readonly rows: string;
  readonly columns: readonly TableColumn[];
  readonly size?: number;
  /** Сетка ячеек (A4) или только линии под шапкой и в конце (чек). */
  readonly grid?: boolean;
}

/** Повтор вложенных блоков для каждого элемента массива (например, платежи в товарном чеке). */
export interface EachBlock extends BlockBase {
  readonly type: 'each';
  readonly items: string;
  readonly blocks: readonly TemplateBlock[];
}

export interface RuleBlock extends BlockBase {
  readonly type: 'rule';
  readonly dashed?: boolean;
}

export interface SpacerBlock extends BlockBase {
  readonly type: 'spacer';
  readonly height: number;
}

export type TemplateBlock = TextBlock | FieldsBlock | TableBlock | EachBlock | RuleBlock | SpacerBlock;

export interface PdfTemplate {
  readonly kind: DocumentKindRendered;
  readonly paper: PaperFormatRendered;
  readonly title: string;
  readonly page: TemplatePage;
  /** Кегль по умолчанию. */
  readonly fontSize: number;
  readonly blocks: readonly TemplateBlock[];
}

export class TemplateError extends Error {}

const BLOCK_TYPES = new Set(['text', 'fields', 'table', 'each', 'rule', 'spacer']);

function isObj(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function num(v: unknown, where: string, min: number, max: number): number {
  if (typeof v !== 'number' || !Number.isFinite(v) || v < min || v > max) {
    throw new TemplateError(`${where}: ожидается число ${min}…${max}`);
  }
  return v;
}

function str(v: unknown, where: string): string {
  if (typeof v !== 'string') throw new TemplateError(`${where}: ожидается строка`);
  return v;
}

function checkBlocks(blocks: unknown, where: string): void {
  if (!Array.isArray(blocks)) throw new TemplateError(`${where}: blocks — массив`);
  blocks.forEach((b, i) => {
    const w = `${where}[${i}]`;
    if (!isObj(b) || typeof b.type !== 'string' || !BLOCK_TYPES.has(b.type)) {
      throw new TemplateError(`${w}: неизвестный тип блока`);
    }
    switch (b.type) {
      case 'text':
        str(b.text, `${w}.text`);
        break;
      case 'fields':
        num(b.labelWidth, `${w}.labelWidth`, 0.05, 0.95);
        if (!Array.isArray(b.rows)) throw new TemplateError(`${w}.rows — массив`);
        for (const r of b.rows as unknown[]) {
          if (!isObj(r)) throw new TemplateError(`${w}.rows: объект`);
          str(r.label, `${w}.rows.label`);
          str(r.value, `${w}.rows.value`);
        }
        break;
      case 'table': {
        str(b.rows, `${w}.rows`);
        if (!Array.isArray(b.columns) || b.columns.length === 0) throw new TemplateError(`${w}.columns — массив`);
        let share = 0;
        for (const c of b.columns as unknown[]) {
          if (!isObj(c)) throw new TemplateError(`${w}.columns: объект`);
          str(c.header, `${w}.columns.header`);
          str(c.value, `${w}.columns.value`);
          share += num(c.width, `${w}.columns.width`, 0.01, 1);
        }
        if (share > 1.0001) throw new TemplateError(`${w}: сумма долей колонок > 1`);
        break;
      }
      case 'each':
        str(b.items, `${w}.items`);
        checkBlocks(b.blocks, `${w}.blocks`);
        break;
      case 'spacer':
        num(b.height, `${w}.height`, 0, 500);
        break;
      default:
        break;
    }
  });
}

/** Проверка структуры шаблона (ошибка шаблона → 500 только для этого запроса, 08 §7.3). */
export function parseTemplate(raw: unknown, source: string): PdfTemplate {
  if (!isObj(raw)) throw new TemplateError(`${source}: шаблон — объект`);
  if (raw.kind !== 'invoice' && raw.kind !== 'receipt') throw new TemplateError(`${source}: kind`);
  if (raw.paper !== 'a4' && raw.paper !== 'thermal80') throw new TemplateError(`${source}: paper`);
  str(raw.title, `${source}.title`);
  const page = raw.page;
  if (!isObj(page) || !isObj(page.margins)) throw new TemplateError(`${source}: page`);
  num(page.width, `${source}.page.width`, 100, 2000);
  if (page.height !== undefined) num(page.height, `${source}.page.height`, 100, 5000);
  for (const k of ['top', 'right', 'bottom', 'left']) num(page.margins[k], `${source}.page.margins.${k}`, 0, 200);
  num(raw.fontSize, `${source}.fontSize`, 4, 40);
  checkBlocks(raw.blocks, `${source}.blocks`);
  return raw as unknown as PdfTemplate;
}

/** Каталог шаблонов с кэшем (файлы читаются один раз на процесс; `reload()` — для смены шаблона без рестарта). */
export class PdfTemplateStore {
  private readonly cache = new Map<string, PdfTemplate>();

  constructor(private readonly dir: string) {}

  get(kind: DocumentKindRendered, paper: PaperFormatRendered): PdfTemplate {
    const key = `${kind}.${paper}`;
    let t = this.cache.get(key);
    if (!t) {
      const file = join(this.dir, `${key}.json`);
      const parsed: unknown = JSON.parse(readFileSync(file, 'utf8'));
      t = parseTemplate(parsed, `${key}.json`);
      if (t.kind !== kind || t.paper !== paper)
        throw new TemplateError(`${key}.json: kind/paper не совпадают с именем`);
      this.cache.set(key, t);
    }
    return t;
  }

  reload(): void {
    this.cache.clear();
  }
}

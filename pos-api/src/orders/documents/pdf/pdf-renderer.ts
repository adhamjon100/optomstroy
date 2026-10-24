import { createHash } from 'node:crypto';
import PDFDocument from 'pdfkit';
import {
  type EachBlock,
  type FieldsBlock,
  type PdfTemplate,
  type TableBlock,
  type TemplateBlock,
  type TextAlign,
  type TextBlock,
} from './pdf-template.js';
import { fill, resolvePath, type Scope, truthy } from './placeholders.js';

/**
 * `PdfRenderer` (08 §7.3; D-27): рендер печатной формы по шаблону (`pdf-template.ts`) и модели документа на pdfkit
 * (без Chromium — 06), шрифт Inter с кириллицей (OFL, `assets/fonts`). Результат детерминирован (дата создания PDF —
 * из модели, а не «сейчас»), поэтому `ETag` = SHA-256 содержимого стабилен между запросами (08 §2.8).
 * Чековая лента 80 мм — одна страница по длине содержимого: первый проход измеряет высоту, второй рисует.
 */
export interface PdfFonts {
  readonly regular: string;
  readonly bold: string;
}

export interface PdfRenderOptions {
  /** Дата в метаданных PDF (`CreationDate`) — фиксированная для детерминизма (например, дата заказа). */
  readonly creationDate: Date;
  readonly title: string;
}

export interface PdfRenderResult {
  readonly bytes: Buffer;
  readonly sha256: string;
  readonly pages: number;
  /** Размер страницы, pt (для проверки ширины 80 мм). */
  readonly pageWidth: number;
  readonly pageHeight: number;
}

const FONT_REGULAR = 'Inter';
const FONT_BOLD = 'Inter-Bold';
const DEFAULT_GAP = 3;
const CELL_PAD = 2;
/** Высота страницы на проходе измерения чековой ленты (без переносов страниц). */
const MEASURE_HEIGHT = 100_000;

type Doc = PDFKit.PDFDocument;

class LayoutPass {
  y: number;
  pages = 1;
  private readonly x0: number;
  private readonly contentW: number;
  private readonly bottomY: number;

  constructor(
    private readonly doc: Doc,
    private readonly t: PdfTemplate,
    private readonly pageH: number,
    private readonly fixedPage: boolean,
    private readonly draw: boolean,
  ) {
    const m = t.page.margins;
    this.y = m.top;
    this.x0 = m.left;
    this.contentW = t.page.width - m.left - m.right;
    this.bottomY = pageH - m.bottom;
  }

  run(root: Scope): number {
    this.blocks(this.t.blocks, [root]);
    return this.y;
  }

  private setFont(bold: boolean | undefined, size: number | undefined): void {
    this.doc.font(bold ? FONT_BOLD : FONT_REGULAR).fontSize(size ?? this.t.fontSize);
  }

  private height(text: string, width: number, align: TextAlign = 'left'): number {
    if (text === '') return this.doc.currentLineHeight(true);
    return this.doc.heightOfString(text, { width, align });
  }

  /** Перенос на новую страницу (только формат с фиксированной высотой); `true` — был перенос. */
  private ensure(h: number): boolean {
    if (!this.fixedPage || this.y + h <= this.bottomY || this.y <= this.t.page.margins.top) return false;
    if (this.draw) {
      this.doc.addPage({ size: [this.t.page.width, this.pageH], margins: this.t.page.margins });
    }
    this.pages += 1;
    this.y = this.t.page.margins.top;
    return true;
  }

  private text(s: string, x: number, y: number, width: number, align: TextAlign = 'left'): void {
    if (this.draw && s !== '') this.doc.text(s, x, y, { width, align, lineBreak: true });
  }

  private blocks(blocks: readonly TemplateBlock[], scopes: readonly Scope[]): void {
    for (const b of blocks) {
      if (!truthy(b.when, scopes)) continue;
      switch (b.type) {
        case 'text':
          this.textBlock(b, scopes);
          break;
        case 'fields':
          this.fieldsBlock(b, scopes);
          break;
        case 'table':
          this.tableBlock(b, scopes);
          break;
        case 'each':
          this.eachBlock(b, scopes);
          break;
        case 'rule':
          this.ensure(6);
          if (this.draw) {
            const ly = this.y + 2;
            this.doc.save().lineWidth(0.5);
            if (b.dashed) this.doc.dash(2, { space: 2 });
            this.doc
              .moveTo(this.x0, ly)
              .lineTo(this.x0 + this.contentW, ly)
              .stroke();
            this.doc.undash().restore();
          }
          this.y += 4 + (b.gapAfter ?? 2);
          break;
        case 'spacer':
          this.y += b.height;
          break;
      }
    }
  }

  private textBlock(b: TextBlock, scopes: readonly Scope[]): void {
    const s = fill(b.text, scopes);
    this.setFont(b.bold, b.size);
    const h = this.height(s, this.contentW, b.align);
    this.ensure(h);
    this.text(s, this.x0, this.y, this.contentW, b.align);
    this.y += h + (b.gapAfter ?? DEFAULT_GAP);
  }

  private fieldsBlock(b: FieldsBlock, scopes: readonly Scope[]): void {
    const lw = this.contentW * b.labelWidth;
    const vx = this.x0 + lw + 4;
    const vw = this.contentW - lw - 4;
    for (const r of b.rows) {
      if (!truthy(r.when, scopes)) continue;
      const label = fill(r.label, scopes);
      const value = fill(r.value, scopes);
      this.setFont(r.bold, b.size);
      const h = Math.max(this.height(label, lw, b.labelAlign), this.height(value, vw, b.valueAlign));
      this.ensure(h);
      this.text(label, this.x0, this.y, lw, b.labelAlign);
      this.text(value, vx, this.y, vw, b.valueAlign);
      this.y += h + 1.5;
    }
    this.y += b.gapAfter ?? DEFAULT_GAP;
  }

  private tableBlock(b: TableBlock, scopes: readonly Scope[]): void {
    const rowsRaw = resolvePath(b.rows, scopes);
    const rows = Array.isArray(rowsRaw) ? (rowsRaw as Scope[]) : [];
    const xs: number[] = [];
    let cx = this.x0;
    const widths = b.columns.map((c) => this.contentW * c.width);
    for (const w of widths) {
      xs.push(cx);
      cx += w;
    }
    const tableW = cx - this.x0;
    const rowHeight = (cells: readonly string[]): number =>
      Math.max(...cells.map((s, i) => this.height(s, widths[i] - 2 * CELL_PAD, b.columns[i].align))) + 2 * CELL_PAD;
    const drawRow = (cells: readonly string[], bold: boolean): void => {
      this.setFont(bold, b.size);
      const h = rowHeight(cells);
      // Перенос строки данных на новую страницу A4 — шапка таблицы повторяется.
      if (this.ensure(h) && !bold) header();
      this.setFont(bold, b.size);
      cells.forEach((s, i) =>
        this.text(s, xs[i] + CELL_PAD, this.y + CELL_PAD, widths[i] - 2 * CELL_PAD, b.columns[i].align),
      );
      if (this.draw && b.grid) {
        this.doc.save().lineWidth(0.5);
        xs.forEach((x, i) => this.doc.rect(x, this.y, widths[i], h).stroke());
        this.doc.restore();
      }
      this.y += h;
      if (this.draw && !b.grid && bold) this.hline(tableW);
    };
    const headers = b.columns.map((c) => fill(c.header, scopes));
    const header = (): void => drawRow(headers, true);
    header();
    for (const r of rows) {
      const cells = b.columns.map((c) => fill(c.value, [r, ...scopes]));
      drawRow(cells, false);
    }
    if (this.draw && !b.grid) this.hline(tableW);
    this.y += b.gapAfter ?? DEFAULT_GAP + 2;
  }

  private hline(width: number): void {
    this.doc
      .save()
      .lineWidth(0.5)
      .moveTo(this.x0, this.y)
      .lineTo(this.x0 + width, this.y)
      .stroke()
      .restore();
  }

  private eachBlock(b: EachBlock, scopes: readonly Scope[]): void {
    const raw = resolvePath(b.items, scopes);
    if (!Array.isArray(raw)) return;
    for (const item of raw as Scope[]) this.blocks(b.blocks, [item, ...scopes]);
    this.y += b.gapAfter ?? 0;
  }
}

export class PdfRenderer {
  constructor(private readonly fonts: PdfFonts) {}

  async render(t: PdfTemplate, model: Scope, opts: PdfRenderOptions): Promise<PdfRenderResult> {
    let pageH = t.page.height;
    if (pageH === undefined) {
      const measured = await this.pass(t, model, opts, MEASURE_HEIGHT, false, false);
      pageH = Math.ceil(measured.endY + t.page.margins.bottom + 1);
    }
    const r = await this.pass(t, model, opts, pageH, t.page.height !== undefined, true);
    return {
      bytes: r.bytes,
      sha256: createHash('sha256').update(r.bytes).digest('hex'),
      pages: r.pages,
      pageWidth: t.page.width,
      pageHeight: pageH,
    };
  }

  private pass(
    t: PdfTemplate,
    model: Scope,
    opts: PdfRenderOptions,
    pageH: number,
    fixedPage: boolean,
    draw: boolean,
  ): Promise<{ bytes: Buffer; pages: number; endY: number }> {
    return new Promise((resolve, reject) => {
      const doc = new PDFDocument({
        size: [t.page.width, pageH],
        margins: t.page.margins,
        compress: true,
        info: { Title: opts.title, Creator: 'Optomstroy POS', CreationDate: opts.creationDate },
        lang: 'ru-RU',
      });
      const chunks: Buffer[] = [];
      doc.on('data', (c: Buffer) => chunks.push(c));
      doc.on('error', reject);
      let pages = 1;
      let endY = 0;
      doc.on('end', () => resolve({ bytes: Buffer.concat(chunks), pages, endY }));
      try {
        doc.registerFont(FONT_REGULAR, this.fonts.regular);
        doc.registerFont(FONT_BOLD, this.fonts.bold);
        doc.font(FONT_REGULAR).fontSize(t.fontSize).lineGap(1);
        const layout = new LayoutPass(doc, t, pageH, fixedPage, draw);
        endY = layout.run(model);
        pages = layout.pages;
        doc.end();
      } catch (e) {
        reject(e instanceof Error ? e : new Error(String(e)));
      }
    });
  }
}

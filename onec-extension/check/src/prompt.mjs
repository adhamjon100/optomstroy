// Вопросы в консоли: обычный ввод, скрытый ввод (пароль, ключ), «да/нет/пропустить», Enter.
// Без консоли (ввод из потока) строки читаются как есть; конец ввода — null.
import readline from 'node:readline';

// Ответы на «да/нет/пропустить». В латинской раскладке ЙЦУКЕН: «да» = «lf», «нет» = «ytn», «пропустить» =
// «ghjgecnbnm» (клавиши Д→l, Н→y, П→g). «y» / «yes» нет нарочно: это клавиша «Н» (см. Prompter.yesNo).
const YES_NO_ANSWERS = new Map([
  ...['д', 'да', 'l', 'lf'].map((w) => [w, 'y']),
  ...['н', 'нет', 'n', 'no', 'ytn'].map((w) => [w, 'n']),
  ...['п', 'пропустить', 's', 'skip', 'g', 'ghjgecnbnm'].map((w) => [w, 's']),
]);

export class CancelError extends Error {
  constructor() { super('Отменено пользователем (Ctrl+C)'); this.code = 'CANCELLED'; }
}

export class Prompter {
  constructor({ input = process.stdin, output = process.stdout, write = null } = {}) {
    this.input = input;
    this.output = output;
    this.write = write || ((s) => output.write(s));
    this.tty = !!input.isTTY && typeof input.setRawMode === 'function';
    this.queue = [];
    this.waiters = [];
    this.eof = false;
    this.rl = null;
  }

  get interactive() {
    return this.tty || !this.eof;
  }

  #ensureStream() {
    if (this.tty || this.rl) return;
    this.rl = readline.createInterface({ input: this.input, terminal: false, crlfDelay: Infinity });
    this.rl.on('line', (l) => {
      const w = this.waiters.shift();
      if (w) w(l); else this.queue.push(l);
    });
    this.rl.on('close', () => {
      this.eof = true;
      while (this.waiters.length) this.waiters.shift()(null);
    });
  }

  #nextStreamLine() {
    this.#ensureStream();
    if (this.queue.length) return Promise.resolve(this.queue.shift());
    if (this.eof) return Promise.resolve(null);
    return new Promise((r) => this.waiters.push(r));
  }

  /** Обычный ввод строки. */
  async line(question) {
    this.write(question);
    if (!this.tty) {
      const l = await this.#nextStreamLine();
      this.write('\n');
      return l === null ? null : l.replace(/^﻿/, '');
    }
    return new Promise((resolve, reject) => {
      const rl = readline.createInterface({ input: this.input, output: this.output, terminal: true });
      let answered = false;
      rl.on('SIGINT', () => { rl.close(); reject(new CancelError()); });
      rl.question('', (a) => { answered = true; rl.close(); resolve(a); });
      rl.on('close', () => { if (!answered) resolve(null); });
    });
  }

  /** Скрытый ввод: эхо выключено; вставка, Backspace, Ctrl+C (отмена). */
  async hidden(question) {
    this.write(question);
    if (!this.tty) {
      const l = await this.#nextStreamLine();
      this.write('\n');
      return l === null ? null : l.replace(/^﻿/, '').replace(/\r$/, '');
    }
    const input = this.input;
    return new Promise((resolve, reject) => {
      let buf = '';
      const wasRaw = input.isRaw;
      input.setRawMode(true);
      input.resume();
      input.setEncoding('utf8');
      const cleanup = () => {
        input.removeListener('data', onData);
        try { input.setRawMode(!!wasRaw); } catch { /* консоль закрыта */ }
        input.pause();
      };
      const onData = (chunk) => {
        for (const ch of String(chunk)) {
          if (ch === '\u0003') { cleanup(); this.write('\n'); reject(new CancelError()); return; }
          if (ch === '\r' || ch === '\n') { cleanup(); this.write('\n'); resolve(buf); return; }
          if (ch === '\u0004') { cleanup(); this.write('\n'); resolve(buf || null); return; }
          if (ch === '\b' || ch === '\u007f') { buf = [...buf].slice(0, -1).join(''); continue; }
          if (ch < ' ' && ch !== '\t') continue;
          buf += ch;
        }
      };
      input.on('data', onData);
    });
  }

  /**
   * «да/нет[/пропустить]»: возвращает 'y' | 'n' | 's' | null (нет ввода). Заглавная буква — ответ на Enter.
   * Латинская раскладка (ЙЦУКЕН): клавиша «Д» даёт «l», «П» — «g», а «Н» — «y». Поэтому «y» и «yes» ответом «да» не
   * считаются (человек, нажавший «н» в латинской раскладке, получил бы «да» — запись в 1С или «ВРУЧНУЮ: ДА»): на них и
   * на прочую латиницу программа переспрашивает с подсказкой о раскладке. «l», «lf» = «да»; «ytn» = «нет»; «g» = «п».
   */
  async yesNo(question, { def = 'n', allowSkip = false } = {}) {
    if (def === 's' && !allowSkip) def = 'n';
    const opts = allowSkip
      ? (def === 'y' ? '[Д/н/п]' : def === 's' ? '[д/н/П]' : '[д/Н/п]')
      : (def === 'y' ? '[Д/н]' : '[д/Н]');
    const letters = allowSkip ? 'д, н или п' : 'д или н';
    for (let i = 0; i < 3; i++) {
      const a = await this.line(`${question} ${opts}: `);
      if (a === null) return null;
      const s = a.trim().toLowerCase();
      if (!s) return def;
      const ans = YES_NO_ANSWERS.get(s);
      if (ans === 'y' || ans === 'n') return ans;
      if (ans === 's' && allowSkip) return 's';
      if (/^[a-z]+$/.test(s)) this.write(`Похоже, включена латинская раскладка — ответьте ${letters} (русскими буквами).\n`);
      else this.write(allowSkip ? 'Ответьте д (да), н (нет) или п (пропустить).\n' : 'Ответьте д (да) или н (нет).\n');
    }
    return def;
  }

  async enter(question) {
    const a = await this.line(question);
    return a !== null;
  }

  close() {
    if (this.rl) { this.rl.close(); this.rl = null; }
    if (this.tty) { try { this.input.pause(); } catch { /* закрыто */ } }
  }
}

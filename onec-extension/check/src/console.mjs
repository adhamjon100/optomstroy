// Вывод в консоль Windows: UTF-8 (запускатель делает chcp 65001), без цвета, всё через вычистку секретов.

export function createConsole({ redactor, masker, verbose = false, stream = process.stdout } = {}) {
  const write = (s) => {
    // Сначала секреты, потом ПДн, потом ещё раз секреты: маска не должна переписать середину пароля или ключа.
    let t = String(s);
    if (redactor) t = redactor.redact(t);
    if (masker) t = masker.maskText(t);
    if (redactor) t = redactor.redact(t);
    stream.write(t);
  };
  const api = {
    raw: (s) => stream.write(redactor ? redactor.redact(String(s)) : String(s)),
    write,
    say: (s = '') => write(s + '\n'),
    debug: (s) => { if (verbose) write('  · ' + s + '\n'); },
    banner: (lines) => {
      const arr = Array.isArray(lines) ? lines : [lines];
      const w = Math.min(96, Math.max(...arr.map((l) => l.length)) + 4);
      write('\n' + '!'.repeat(w) + '\n');
      for (const l of arr) write('!! ' + l + '\n');
      write('!'.repeat(w) + '\n\n');
    },
    rule: () => write('-'.repeat(78) + '\n'),
    verbose,
  };
  return api;
}

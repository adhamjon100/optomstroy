import { PassThrough } from 'node:stream';
import { shutdownOnStdinEof, type StdinLike } from './stdin-shutdown.js';

/** Дождаться обработки событий потока (end/close приходят через process.nextTick / setImmediate). */
const settle = () => new Promise((r) => setTimeout(r, 20));

describe('POS_SHUTDOWN_ON_STDIN_EOF: остановка по концу stdin (служба Windows)', () => {
  it('выключено (по умолчанию) → stdin не открывается, обработчиков нет', () => {
    const open = vi.fn<() => StdinLike>();
    const trigger = vi.fn();
    expect(shutdownOnStdinEof(false, trigger, open)).toBe(false);
    expect(open).not.toHaveBeenCalled();
    expect(trigger).not.toHaveBeenCalled();
  });

  it('выключено → реальный process.stdin не трогается (поток не создаётся)', () => {
    const getter = vi.spyOn(process, 'stdin', 'get');
    try {
      expect(shutdownOnStdinEof(false, vi.fn())).toBe(false);
      expect(getter).not.toHaveBeenCalled();
    } finally {
      getter.mockRestore();
    }
  });

  it('включено → данные stdin отбрасываются, остановки нет, пока канал открыт', async () => {
    const stdin = new PassThrough();
    const trigger = vi.fn();
    expect(shutdownOnStdinEof(true, trigger, () => stdin)).toBe(true);
    stdin.write('любые данные\n');
    await settle();
    expect(trigger).not.toHaveBeenCalled();
    expect(stdin.readableFlowing).toBe(true);
    stdin.destroy();
  });

  it('включено → конец stdin (end + close) вызывает остановку ровно один раз', async () => {
    const stdin = new PassThrough();
    const trigger = vi.fn();
    shutdownOnStdinEof(true, trigger, () => stdin);
    stdin.end();
    await settle();
    stdin.destroy();
    stdin.emit('close');
    await settle();
    expect(trigger).toHaveBeenCalledTimes(1);
    expect(trigger).toHaveBeenCalledWith('stdin-eof');
  });

  it('включено → ошибка канала (родитель исчез) тоже останавливает, один раз', async () => {
    const stdin = new PassThrough();
    const trigger = vi.fn();
    shutdownOnStdinEof(true, trigger, () => stdin);
    stdin.destroy(new Error('EPIPE'));
    await settle();
    expect(trigger).toHaveBeenCalledTimes(1);
  });
});

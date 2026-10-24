import type { SmsLogger } from '../../../src/integrations/sms/sms-telemetry.js';

/** Логгер-перехватчик: сырые записи до redaction (проверка «секретов нет в источнике лога», SMS-023). */
export class CaptureLogger implements SmsLogger {
  readonly entries: { level: 'info' | 'warn' | 'error'; entry: Record<string, unknown> }[] = [];

  log(entry: Record<string, unknown>): void {
    this.entries.push({ level: 'info', entry });
  }

  warn(entry: Record<string, unknown>): void {
    this.entries.push({ level: 'warn', entry });
  }

  error(entry: Record<string, unknown>): void {
    this.entries.push({ level: 'error', entry });
  }

  get text(): string {
    return this.entries.map((e) => JSON.stringify(e.entry)).join('\n');
  }

  events(name: string): Record<string, unknown>[] {
    return this.entries.filter((e) => e.entry.event === name).map((e) => e.entry);
  }

  clear(): void {
    this.entries.length = 0;
  }
}

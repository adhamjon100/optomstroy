import { BlockList, isIP } from 'node:net';
import { Controller, Header, HttpCode, Inject, Post, Req } from '@nestjs/common';
import { ApiConsumes, ApiOperation, ApiTags } from '@nestjs/swagger';
import type { Request } from 'express';
import { Public } from '../../common/auth/auth.decorators.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { SMS_TELEMETRY, type SmsTelemetry } from '../../integrations/sms/sms-telemetry.js';
import { parseDlrPush, XmlParseError } from '../../integrations/sms/smspro-xml.js';
import { SmsDlrService } from './sms-dlr.service.js';

/** Предел тела push-DLR (08 §4.22.1: > 1 MB → 413). */
export const DLR_BODY_LIMIT_BYTES = 1024 * 1024;
/** Бюджет синхронной обработки: ответ провайдеру ≤ 1 с, остаток — в фоне (09 §6.5). */
export const DLR_SYNC_BUDGET_MS = 700;

/** Разбор `SMSPRO_DLR_ALLOWED_IPS`: IP через запятую, допускаются подсети `a.b.c.d/nn`. Пустой список → `null`. */
export function parseAllowedIps(raw: string | undefined): BlockList | null {
  const items = (raw ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (items.length === 0) return null;
  const list = new BlockList();
  for (const item of items) {
    const [addr, prefix] = item.split('/');
    const family = isIP(addr ?? '');
    if (family === 0) throw new Error(`SMSPRO_DLR_ALLOWED_IPS: неверный адрес «${item}»`);
    const type = family === 6 ? 'ipv6' : 'ipv4';
    if (prefix !== undefined) list.addSubnet(addr, Number(prefix), type);
    else list.addAddress(addr, type);
  }
  return list;
}

/** IPv4-mapped IPv6 (`::ffff:203.0.113.5`) → IPv4. */
export function normalizeRemoteIp(ip: string | undefined): string {
  if (!ip) return '';
  const m = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  return m ? m[1] : ip;
}

function allowed(list: BlockList, ip: string): boolean {
  const family = isIP(ip);
  if (family === 0) return false;
  return list.check(ip, family === 6 ? 'ipv6' : 'ipv4');
}

/** Сверх этого объёма тело не дочитывается (соединение обрывается). */
const DRAIN_CAP_BYTES = 8 * 1024 * 1024;

/**
 * Чтение тела с пределом. Превышение → 413; тело до `DRAIN_CAP_BYTES` дочитывается и отбрасывается, чтобы клиент
 * получил ответ, а не обрыв соединения посреди отправки.
 */
async function readBody(req: Request, limit: number): Promise<string> {
  const tooLarge = () => new ProblemException('PAYLOAD_TOO_LARGE', { detail: 'Тело запроса больше 1 MB.' });
  const declared = Number(req.headers['content-length'] ?? 0);
  if (declared > DRAIN_CAP_BYTES) {
    req.destroy();
    throw tooLarge();
  }
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req as AsyncIterable<Buffer | string>) {
    const b = typeof chunk === 'string' ? Buffer.from(chunk) : chunk;
    size += b.length;
    if (size > DRAIN_CAP_BYTES) {
      req.destroy();
      throw tooLarge();
    }
    if (size <= limit) chunks.push(b);
  }
  if (size > limit || declared > limit) throw tooLarge();
  return Buffer.concat(chunks).toString('utf8');
}

/**
 * Push-DLR SMSPro `POST /api/v1/integrations/smspro/dlr` (08 §4.22.1; 09 §6.5, SMS-017; RM-D-002 п. 4–5):
 * - `SMSPRO_DLR_MODE=poll` (по умолчанию) или пустой `SMSPRO_DLR_ALLOWED_IPS` → 404 (маршрут как отсутствующий);
 * - без Bearer (подписи у вендора нет): только IP-allowlist (`req.ip` с учётом `trust proxy` pos-proxy) → иначе 403;
 * - тело `application/xml` / `text/xml` ≤ 1 MB (иначе 415 / 413), формат `report/dr[]/{id, phone[]}`;
 * - неизвестные `dr/id` игнорируются (`sms_dlr_unknown_id_total`), повтор того же отчёта идемпотентен;
 * - ответ — 200 с пустым телом не позже ~1 с; обновление `sms_outbox`, не уложившееся в бюджет, завершается в фоне.
 * Аудит не пишется (технический канал); номера в лог — только маской.
 */
@ApiTags('integrations')
@Controller('integrations/smspro')
export class SmsDlrController {
  private readonly allowList: BlockList | null;
  private readonly pushEnabled: boolean;

  constructor(
    @Inject(APP_CONFIG) config: AppConfig,
    @Inject(SmsDlrService) private readonly dlr: SmsDlrService,
    @Inject(SMS_TELEMETRY) private readonly telemetry: SmsTelemetry,
  ) {
    this.allowList = parseAllowedIps(config.SMSPRO_DLR_ALLOWED_IPS);
    this.pushEnabled = config.SMSPRO_DLR_MODE === 'push' && this.allowList !== null;
  }

  @Public()
  @ApiOperation({
    operationId: 'integrations_smspro_dlr_receive',
    summary: 'Отчёт о доставке SMS от SMSPro (push-DLR)',
  })
  @ApiConsumes('application/xml')
  @Post('dlr')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  async receive(@Req() req: Request): Promise<void> {
    if (!this.pushEnabled || !this.allowList) throw new ProblemException('NOT_FOUND', { detail: 'Ресурс не найден.' });
    const ip = normalizeRemoteIp(req.ip);
    if (!allowed(this.allowList, ip)) {
      this.telemetry.logger.warn({ event: 'sms.dlr.push_forbidden', ip });
      throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
    }
    const type = (req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
    if (type !== 'application/xml' && type !== 'text/xml') {
      throw new ProblemException('UNSUPPORTED_MEDIA_TYPE', { detail: 'Ожидается application/xml.' });
    }
    const body = await readBody(req, DLR_BODY_LIMIT_BYTES);
    let entries;
    try {
      entries = parseDlrPush(body);
    } catch (e) {
      // Ответ провайдеру — 200 без деталей: повтор того же нечитаемого отчёта не поможет (08 §4.22.1).
      this.telemetry.logger.warn({
        event: 'sms.dlr.push_malformed',
        error: e instanceof XmlParseError ? 'xml_parse' : 'unknown',
      });
      return;
    }
    const work = this.dlr.applyPush(entries).catch((e: unknown) => {
      this.telemetry.logger.warn({
        event: 'sms.dlr.push_failed',
        error: e instanceof Error ? e.name : 'unknown',
      });
    });
    let timer: NodeJS.Timeout | undefined;
    await Promise.race([work, new Promise<void>((r) => (timer = setTimeout(r, DLR_SYNC_BUDGET_MS)))]);
    if (timer) clearTimeout(timer);
  }
}

import { Body, Controller, Get, HttpCode, Param, Post, Req } from '@nestjs/common';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { Public } from '../../common/auth/auth.decorators.js';
import { isUuid } from '../../common/ids/uuid.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { UsersRepository } from '../../users/users.repository.js';
import { Inject } from '@nestjs/common';
import { AuthHttpRateLimiter } from '../common/http-rate-limits.js';
import { AuthPolicyService } from '../common/auth-policy.js';
import { normalizeKgPhone } from '../common/phone.js';
import { type AuthHttpRequest, clientIp, headerValue, requestIdOf, requireDeviceKey } from '../common/request.js';
import { EmergencyLoginService } from '../login/emergency-login.service.js';
import { LoginService, type VerifyBody } from '../login/login.service.js';
import { maskPhone } from '../../common/logging/redaction.js';
import { OtpChallengesRepository } from './otp-challenges.repository.js';
import { OtpRequestDto, OtpVerifyDto } from './otp.dto.js';
import { OtpService } from './otp.service.js';
import { SmsOutboxRepository } from './sms-outbox.repository.js';

/** Челлендж, истёкший более 10 мин назад, статусом не отвечает (08 §4.1.9). */
const STATUS_VISIBLE_AFTER_EXPIRY_MS = 10 * 60_000;

/**
 * Публичные эндпоинты OTP (RM-D-001, RM-D-014; 08 §4.1.1, §4.1.2, §4.1.9; 09 §4). Без Bearer; `X-Device-Id`
 * обязателен (UUID v4). Ответ `request` одинаков по форме, статусу и пути обработки для любого номера (D-10).
 */
@Public()
@Controller('auth/otp')
export class OtpController {
  constructor(
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly otp: OtpService,
    private readonly login: LoginService,
    private readonly users: UsersRepository,
    private readonly challenges: OtpChallengesRepository,
    private readonly outbox: SmsOutboxRepository,
    private readonly policy: AuthPolicyService,
    private readonly limiter: AuthHttpRateLimiter,
    private readonly emergency: EmergencyLoginService,
  ) {}

  @Post('request')
  @HttpCode(202)
  async request(@Req() req: AuthHttpRequest, @Body() body: OtpRequestDto) {
    const deviceKey = requireDeviceKey(req);
    const ip = clientIp(req);
    this.limiter.publicIp(ip);
    const phone = normalizeKgPhone(body.phone) as string;
    // Проверка существования аккаунта — только на сервере (09 §4.1): результат пишется в otp_challenges.user_id.
    const user = await this.users.findByPhone(phone);
    // Аварийный код администратора (09 §6.13 п. 3; RM-D-016): 202 с его challengeId без SMS, без cooldown и без
    // аннулирования (в т. ч. при открытом circuit-breaker); с другого устройства после привязки → 409.
    const emergency = await this.emergency.claim(phone, deviceKey, requestIdOf(req));
    if (emergency.kind === 'other_device') {
      throw new ProblemException('DEVICE_MISMATCH', { detail: 'Код запрошен на другом устройстве.' });
    }
    if (emergency.kind === 'bound') {
      const policy = (await this.policy.effective()).otp;
      const now = this.clock.now();
      return {
        challengeId: emergency.challenge.challengeId,
        resendAfterSec: policy.resendCooldownSeconds,
        otpTtlSec: Math.max(1, Math.ceil((emergency.challenge.expiresAt.getTime() - now.getTime()) / 1000)),
        codeLength: policy.codeLength,
        phoneMasked: maskPhone(phone),
        deliveryHint: 'sms',
      };
    }
    const issued = await this.otp.issue({
      phoneE164: phone,
      purpose: 'login_or_register',
      deviceKey,
      ip,
      requestId: requestIdOf(req),
      userId: user?.id ?? null,
      audit: auditContextFromRequest(req),
    });
    return {
      challengeId: issued.challengeId,
      resendAfterSec: issued.resendAfterSec,
      otpTtlSec: issued.otpTtlSec,
      codeLength: issued.codeLength,
      phoneMasked: issued.phoneMasked,
      deliveryHint: 'sms',
    };
  }

  @Post('verify')
  @HttpCode(200)
  async verify(@Req() req: AuthHttpRequest, @Body() body: OtpVerifyDto): Promise<VerifyBody> {
    const deviceKey = requireDeviceKey(req);
    const ip = clientIp(req);
    this.limiter.publicIp(ip);
    await this.limiter.otpVerifyIp(ip);
    return this.login.verify({
      challengeId: body.challengeId.toLowerCase(),
      code: body.code,
      deviceKey,
      device: {
        name: body.device.name,
        platform: body.device.platform,
        ...(body.device.osVersion !== undefined ? { osVersion: body.device.osVersion } : {}),
        appVersion: body.device.appVersion,
        ...(body.device.biometricClass !== undefined ? { biometricClass: body.device.biometricClass } : {}),
      },
      ip,
      userAgent: headerValue(req, 'user-agent') ?? null,
      audit: auditContextFromRequest(req),
    });
  }

  /** Статус доставки SMS без ПДн (08 §4.1.9; ядро §19.2): чужой `X-Device-Id` или неизвестный id → 404. */
  @Get('challenges/:challengeId')
  async status(@Req() req: AuthHttpRequest, @Param('challengeId') challengeId: string) {
    if (!isUuid(challengeId)) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Запрос не прошёл проверку.',
        errors: [{ field: 'challengeId', message: 'Ожидается UUID', rule: 'uuid' }],
      });
    }
    const deviceKey = requireDeviceKey(req);
    this.limiter.publicIp(clientIp(req));
    const id = challengeId.toLowerCase();
    this.limiter.otpStatus(id, deviceKey);
    const now = this.clock.now();
    const ch = await this.challenges.findById(id);
    if (!ch || ch.deviceKey !== deviceKey || ch.expiresAt.getTime() + STATUS_VISIBLE_AFTER_EXPIRY_MS < now.getTime()) {
      throw new ProblemException('NOT_FOUND', { detail: 'Код не найден.' });
    }
    let delivery: 'queued' | 'sent' | 'failed' = 'sent';
    if (ch.status === 'failed_delivery') delivery = 'failed';
    else if (ch.smsOutboxId !== null) {
      const sms = await this.outbox.findById(ch.smsOutboxId);
      if (sms?.status === 'queued') delivery = 'queued';
      else if (sms?.status === 'failed' || sms?.status === 'expired') delivery = 'failed';
    }
    const cooldown = this.policy.base().otp.resendCooldownSeconds;
    const resendAfterSec =
      delivery === 'failed'
        ? 0
        : Math.max(0, Math.ceil((ch.createdAt.getTime() + cooldown * 1000 - now.getTime()) / 1000));
    return {
      challengeId: ch.id,
      delivery,
      resendAfterSec,
      expiresAt: ch.expiresAt.toISOString(),
      channel: 'sms',
    };
  }
}

/**
 * Признак `<test>1</test>` запроса SMSPro (09 §5.8) — одно правило для отправки кода напрямую (`SmsOtpProvider`) и
 * через очередь `sms.send` воркера (`SmsSendProcessor`): `SMSPRO_TEST_FLAG=true` — всем; иначе на стенде
 * (`APP_ENV=staging`) с провайдером `smspro` — всем номерам вне `SMS_STAGING_ALLOWED_PHONES` (E.164 через запятую;
 * пустой список — настоящая SMS не уходит никому). Прочие окружения и провайдеры — без тега.
 */
export interface SmsTestFlagConfig {
  readonly testFlag: boolean;
  readonly appEnv: string;
  readonly provider: string;
  /** `SMS_STAGING_ALLOWED_PHONES` как есть (строка через запятую) или уже разобранный список. */
  readonly stagingAllowedPhones: string | readonly string[] | null | undefined;
}

/** Разбор `SMS_STAGING_ALLOWED_PHONES`: E.164 через запятую, пробелы и пустые элементы отбрасываются. */
export function parseStagingAllowedPhones(v: string | readonly string[] | null | undefined): string[] {
  const list = typeof v === 'string' ? v.split(',') : [...(v ?? [])];
  return list.map((s) => s.trim()).filter((s) => s !== '');
}

export function smsTestFlag(c: SmsTestFlagConfig, phoneE164: string): boolean {
  if (c.testFlag) return true;
  if (c.appEnv !== 'staging' || c.provider !== 'smspro') return false;
  return !parseStagingAllowedPhones(c.stagingAllowedPhones).includes(phoneE164);
}

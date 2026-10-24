import { IsInt, IsObject, Min } from 'class-validator';

/**
 * Тело `PUT /admin/settings` (contracts/openapi `AdminSettingsUpdateRequest`, `additionalProperties: false`):
 * частичный объект `settings` + `rowVersion`. Поля `settings` проверяет сервис по таблице соответствия
 * (admin-settings.map.ts): неизвестные → 400 `unknown_setting`, блока `env` → 400 `read_only_setting`.
 */
export class AdminSettingsUpdateDto {
  @IsObject()
  settings!: Record<string, unknown>;

  @IsInt()
  @Min(0)
  rowVersion!: number;
}

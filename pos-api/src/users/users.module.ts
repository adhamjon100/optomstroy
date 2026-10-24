import { Global, Module } from '@nestjs/common';
import { AUTH_STATE_READER } from '../common/auth/auth-state.js';
import { PgAuthStateReader } from './auth-state.reader.js';
import { DevicesRepository } from './devices.repository.js';
import { SessionsRepository } from './sessions.repository.js';
import { TokenDenylistRepository } from './token-denylist.repository.js';
import { UserProfilesRepository } from './user-profiles.repository.js';
import { UserRolesRepository } from './user-roles.repository.js';
import { UsersRepository } from './users.repository.js';

const REPOSITORIES = [
  UsersRepository,
  UserRolesRepository,
  UserProfilesRepository,
  DevicesRepository,
  SessionsRepository,
  TokenDenylistRepository,
];

/**
 * Данные пользователей и сессий (этап D, общий фундамент): репозитории `users`, `user_roles`, `user_profiles`,
 * `devices`, `sessions`, `token_denylist` на Drizzle (`DRIZZLE`, common/db) — без HTTP и бизнес-правил; порт
 * `AUTH_STATE_READER` для AuthGuard. Глобальный: используется модулями auth, registration, profile, admin.
 */
@Global()
@Module({
  providers: [...REPOSITORIES, PgAuthStateReader, { provide: AUTH_STATE_READER, useExisting: PgAuthStateReader }],
  exports: [...REPOSITORIES, AUTH_STATE_READER],
})
export class UsersModule {}

import { Global, Module } from '@nestjs/common';
import { AppVersionMiddleware } from './app-version.middleware.js';
import { AppVersionPolicy } from './app-version.policy.js';

@Global()
@Module({ providers: [AppVersionPolicy, AppVersionMiddleware], exports: [AppVersionPolicy, AppVersionMiddleware] })
export class AppVersionModule {}

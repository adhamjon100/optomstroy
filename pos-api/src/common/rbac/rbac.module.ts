import { Global, Module } from '@nestjs/common';
import { PermissionCatalog } from './permission-catalog.js';

@Global()
@Module({ providers: [PermissionCatalog], exports: [PermissionCatalog] })
export class RbacModule {}

import { type DynamicModule, Module } from '@nestjs/common';
import { CustomerMatchingModule, type CustomerMatchingModuleOptions } from '../matching/customer-matching.module.js';
import { CustomerLinkQueueController, CustomerLinksController } from './customer-links.controller.js';
import { CustomerLinksRepository } from './customer-links.repository.js';
import { CustomerLinksService } from './customer-links.service.js';
import { CustomerMatchController } from './customer-match.controller.js';
import { LinkConflictNotifier } from './link-conflict.notifier.js';
import { selfServiceFlagProvider } from './self-service.flag.js';
import { StepUpTokenVerifier } from '../../auth/step-up/step-up-token.verifier.js';
import { StepUpVerifier } from './step-up.verifier.js';

export interface CustomerLinksModuleOptions {
  readonly matching?: CustomerMatchingModuleOptions;
  /**
   * Регистрировать `GET /customers` (ветка `linkStatus`). `false` — когда RM-G-001 подключил собственный
   * обработчик списка клиентов и вызывает `CustomerLinksService.listQueue` сам.
   */
  readonly queueController?: boolean;
}

/**
 * Привязки клиентов (RM-D-005): `customer_links`, SCR-06 и очередь администратора SCR-45. Зависимости — глобальные
 * модули фундамента (ConfigModule, DatabaseModule, RbacModule, AuditModule, AuthCoreModule, UsersModule).
 * Подключение в `CustomersModule`: `imports: [CustomerLinksModule.forRoot()]` (интеграция — владелец модуля).
 * Экспорт: `CustomerLinksService` (`proposeForUser`/`applyMatch` для `POST /registration/complete`) и порт
 * `CUSTOMER_MATCHING` (дедупликация `POST /customers`, RM-G-001).
 */
@Module({})
export class CustomerLinksModule {
  static forRoot(options: CustomerLinksModuleOptions = {}): DynamicModule {
    const matching = CustomerMatchingModule.forRoot(options.matching ?? { onec: true });
    return {
      module: CustomerLinksModule,
      imports: [matching],
      controllers: [
        CustomerMatchController,
        CustomerLinksController,
        ...(options.queueController === false ? [] : [CustomerLinkQueueController]),
      ],
      providers: [
        CustomerLinksRepository,
        CustomerLinksService,
        LinkConflictNotifier,
        StepUpTokenVerifier,
        StepUpVerifier,
        selfServiceFlagProvider,
      ],
      exports: [CustomerLinksService, CustomerLinksRepository, matching],
    };
  }
}

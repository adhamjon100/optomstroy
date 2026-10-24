export {
  CUSTOMER_MATCHING_PORT,
  type CustomerMatchingPort,
  type CustomerMatchSummary,
  NO_MATCH,
  type RegistrationMatchInput,
  summaryOf,
} from './ports/customer-matching.port.js';
export { RegistrationModule } from './registration.module.js';
export {
  REGISTRATION_ROUTE,
  type RegistrationAuthenticatedResponse,
  type RegistrationPendingResponse,
  type RegistrationResponse,
  RegistrationService,
} from './registration.service.js';

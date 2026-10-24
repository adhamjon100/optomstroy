export { CustomerMatchingModule, type CustomerMatchingModuleOptions } from './customer-matching.module.js';
export {
  CUSTOMER_MATCHING,
  type CustomerMatching,
  type CustomerMatchResult,
  type FindByPhoneOptions,
  KG_E164,
  type MatchCandidate,
  type MatchKind,
  type OnecLookupState,
} from './customer-matching.port.js';
export { PgCustomerMatching } from './pg-customer-matching.js';

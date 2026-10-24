export { SearchController, SEARCH_CACHE_CONTROL } from './search.controller.js';
export { SearchModule } from './search.module.js';
export {
  SEARCH_CURSOR_CODEC,
  type SearchBarcodeResponse,
  type SearchProductItem,
  type SearchProductsResponse,
  SearchService,
  type SearchSuggestResponse,
  stagePlan,
} from './search.service.js';
export { classifyQuery, normSku, type SearchStage, wordVariants } from './search-text.js';
export {
  buildStageQuery,
  buildSuggestQuery,
  TRGM_SIMILARITY_THRESHOLD,
  TRGM_WORD_SIMILARITY_THRESHOLD,
} from './search.repository.js';

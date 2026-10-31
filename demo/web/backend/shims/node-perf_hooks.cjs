'use strict';
// Шим `perf_hooks` и `v8`.
function monitorEventLoopDelay() {
  return { enable() {}, disable() {}, reset() {}, percentile: () => 0, percentiles: new Map(), min: 0, max: 0, mean: 0, stddev: 0, exceeds: 0, count: 0 };
}
class PerformanceObserver {
  observe() {}
  disconnect() {}
}
PerformanceObserver.supportedEntryTypes = [];
const heap = () => {
  const m = typeof performance !== 'undefined' && performance.memory ? performance.memory : { usedJSHeapSize: 0, totalJSHeapSize: 0, jsHeapSizeLimit: 0 };
  return {
    total_heap_size: m.totalJSHeapSize,
    used_heap_size: m.usedJSHeapSize,
    heap_size_limit: m.jsHeapSizeLimit,
    total_available_size: m.jsHeapSizeLimit - m.usedJSHeapSize,
    malloced_memory: 0,
    external_memory: 0,
    total_physical_size: m.totalJSHeapSize,
    number_of_native_contexts: 1,
    number_of_detached_contexts: 0,
  };
};
module.exports = {
  performance: globalThis.performance,
  PerformanceObserver,
  PerformanceEntry: globalThis.PerformanceEntry,
  monitorEventLoopDelay,
  createHistogram: monitorEventLoopDelay,
  constants: {},
  // v8
  getHeapStatistics: heap,
  getHeapSpaceStatistics: () => [],
  getHeapCodeStatistics: () => ({}),
  serialize: (v) => new TextEncoder().encode(JSON.stringify(v)),
  deserialize: (b) => JSON.parse(new TextDecoder().decode(b)),
  setFlagsFromString() {},
  cachedDataVersionTag: () => 0,
};

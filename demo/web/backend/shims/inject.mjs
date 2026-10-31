// Внедряется esbuild `inject` во все модули бандла: свободные идентификаторы process, Buffer, global и таймеры
// Node. `process` НЕ становится глобальным (иначе PGlite решит, что работает в Node). Первым импортом ставится
// запрет исходящей сети (net-guard.mjs), чтобы он сработал раньше любого кода pos-api и пакетов.
import './net-guard.mjs';
import processShim from './node-process.cjs';
import bufferShim from './node-buffer.cjs';
import timersShim from './node-timers.cjs';

export const process = processShim;
export const Buffer = bufferShim.Buffer;
export const global = globalThis;
export const setImmediate = timersShim.setImmediate;
export const clearImmediate = timersShim.clearImmediate;
export const setTimeout = timersShim.setTimeout;
export const clearTimeout = timersShim.clearTimeout;
export const setInterval = timersShim.setInterval;
export const clearInterval = timersShim.clearInterval;

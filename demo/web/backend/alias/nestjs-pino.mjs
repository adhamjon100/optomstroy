// Подмена nestjs-pino: глобальный LoggerModule с провайдерами Logger/PinoLogger поверх мини-pino. Журнал HTTP
// (pino-http) не нужен: мост воркера сам учитывает запросы.
import { Global, Injectable, Module } from '@nestjs/common';
import { pino } from './pino.mjs';

let rootLevel = 'warn';
const root = () => pino({ level: rootLevel, base: { service: 'pos-api' } });

export class PinoLogger {
  constructor() {
    this.logger = root();
    this.context = '';
  }
  setContext(ctx) {
    this.context = ctx;
  }
  assign(fields) {
    this.logger.setBindings(fields);
  }
  trace(...a) {
    this.logger.trace(...a);
  }
  debug(...a) {
    this.logger.debug(...a);
  }
  info(...a) {
    this.logger.info(...a);
  }
  warn(...a) {
    this.logger.warn(...a);
  }
  error(...a) {
    this.logger.error(...a);
  }
  fatal(...a) {
    this.logger.fatal(...a);
  }
}
Injectable()(PinoLogger);

function split(args) {
  let context;
  const rest = [...args];
  if (rest.length > 0 && typeof rest[rest.length - 1] === 'string') context = rest.pop();
  return { context, rest };
}
export class Logger {
  constructor() {
    this.logger = root();
  }
  _call(level, message, args) {
    const { context, rest } = split(args);
    const ctx = context ? { context } : {};
    if (message instanceof Error) this.logger[level]({ ...ctx, err: message }, message.message);
    else if (message && typeof message === 'object') {
      const err = rest.find((x) => x instanceof Error);
      this.logger[level]({ ...ctx, ...message, ...(err ? { err } : {}) }, message.msg ?? message.message ?? '');
    } else {
      const stack = level === 'error' && typeof rest[0] === 'string' ? rest[0] : undefined;
      this.logger[level]({ ...ctx, ...(stack ? { stack } : {}) }, String(message));
    }
  }
  verbose(m, ...a) {
    this._call('debug', m, a);
  }
  debug(m, ...a) {
    this._call('debug', m, a);
  }
  log(m, ...a) {
    this._call('info', m, a);
  }
  warn(m, ...a) {
    this._call('warn', m, a);
  }
  error(m, ...a) {
    this._call('error', m, a);
  }
  fatal(m, ...a) {
    this._call('fatal', m, a);
  }
  setLogLevels() {}
}
Injectable()(Logger);

export const PARAMS_PROVIDER_TOKEN = 'pino-params'; // check-secrets: allow — имя DI-токена nestjs-pino, не секрет
export class LoggerModule {
  static forRoot(params = {}) {
    rootLevel = params?.pinoHttp?.level ?? rootLevel;
    return {
      module: LoggerModule,
      global: true,
      providers: [Logger, PinoLogger, { provide: PARAMS_PROVIDER_TOKEN, useValue: params }],
      exports: [Logger, PinoLogger, PARAMS_PROVIDER_TOKEN],
    };
  }
  static forRootAsync(params = {}) {
    return LoggerModule.forRoot(params);
  }
}
Module({})(LoggerModule);
Global()(LoggerModule);

export function getLoggerToken(context) {
  return `PinoLogger:${context}`;
}
export function InjectPinoLogger() {
  return () => {};
}
export class LoggerErrorInterceptor {
  intercept(_ctx, next) {
    return next.handle();
  }
}
Injectable()(LoggerErrorInterceptor);
export const Params = undefined;

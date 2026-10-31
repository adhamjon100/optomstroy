'use strict';
// Необязательный пакет, которого нет в браузерном бэкенде (@nestjs/microservices, @nestjs/websockets,
// @fastify/static, pg-native, pino-http…): загрузка бросает MODULE_NOT_FOUND, как в Node без пакета, — Nest
// и pg корректно обрабатывают отсутствие. Подключается только ленивыми require/import.
const e = new Error('Cannot find module (необязательный пакет отсутствует в браузерном бэкенде)');
e.code = 'MODULE_NOT_FOUND';
throw e;

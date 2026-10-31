'use strict';
// Заглушка встроенного модуля Node без функций, нужных браузерному бэкенду (repl, worker_threads, child_process,
// tty, readline, cluster, vm, inspector…): свойства-функции бросают понятную ошибку.
function unsupported(name) {
  return () => {
    const e = new Error(`${name} не поддерживается в браузерном бэкенде`);
    e.code = 'ERR_DEMO_UNSUPPORTED';
    throw e;
  };
}
module.exports = {
  isMainThread: true,
  parentPort: null,
  workerData: null,
  threadId: 0,
  Worker: unsupported('worker_threads.Worker'),
  MessageChannel: globalThis.MessageChannel,
  BroadcastChannel: globalThis.BroadcastChannel,
  spawn: unsupported('child_process.spawn'),
  exec: unsupported('child_process.exec'),
  execSync: unsupported('child_process.execSync'),
  execFile: unsupported('child_process.execFile'),
  fork: unsupported('child_process.fork'),
  start: unsupported('repl.start'),
  isatty: () => false,
  ReadStream: function ReadStream() {},
  WriteStream: function WriteStream() {},
  createInterface: unsupported('readline.createInterface'),
  isPrimary: true,
  isMaster: true,
  isWorker: false,
  Script: unsupported('vm.Script'),
  runInNewContext: unsupported('vm.runInNewContext'),
  createContext: (o) => o || {},
  isContext: () => false,
  Session: unsupported('inspector.Session'),
  url: () => undefined,
  close() {},
};

'use strict';
// Шим `stream`: readable-stream 3.6.2 + недостающее из новых Node (Readable.from, promises, writableEnded,
// readableEnded, writableFinished, addAbortSignal, isReadable). module.exports — legacy Stream, как в Node.
const EventEmitter = require('./node-events.cjs');
const rs = require('nm:readable-stream/readable-browser.js');

const { Readable, Writable, Duplex, Transform, PassThrough, finished, pipeline } = rs;

function Stream(opts) {
  EventEmitter.call(this, opts);
}
Object.setPrototypeOf(Stream.prototype, EventEmitter.prototype);
Object.setPrototypeOf(Stream, EventEmitter);
Stream.prototype.pipe = function pipe(dest, options) {
  const source = this;
  function ondata(chunk) {
    if (dest.writable && dest.write(chunk) === false && source.pause) source.pause();
  }
  source.on('data', ondata);
  function ondrain() {
    if (source.readable && source.resume) source.resume();
  }
  dest.on('drain', ondrain);
  if (!options || options.end !== false) source.on('end', () => dest.end());
  dest.emit('pipe', source);
  return dest;
};

const def = (proto, name, get) => {
  if (!Object.getOwnPropertyDescriptor(proto, name)) Object.defineProperty(proto, name, { configurable: true, enumerable: false, get });
};
for (const proto of [Writable.prototype, Duplex.prototype]) {
  def(proto, 'writableEnded', function () {
    return this._writableState ? this._writableState.ending : false;
  });
  def(proto, 'writableFinished', function () {
    return this._writableState ? this._writableState.finished : false;
  });
  def(proto, 'writableNeedDrain', function () {
    const s = this._writableState;
    return s ? !s.destroyed && !s.ending && s.needDrain : false;
  });
  def(proto, 'writableObjectMode', function () {
    return this._writableState ? this._writableState.objectMode : false;
  });
  def(proto, 'writableCorked', function () {
    return this._writableState ? this._writableState.corked : 0;
  });
}
for (const proto of [Readable.prototype, Duplex.prototype]) {
  def(proto, 'readableEnded', function () {
    return this._readableState ? this._readableState.endEmitted : false;
  });
  def(proto, 'readableObjectMode', function () {
    return this._readableState ? this._readableState.objectMode : false;
  });
  def(proto, 'readableAborted', function () {
    const s = this._readableState;
    return s ? !!s.destroyed && !s.endEmitted : false;
  });
  def(proto, 'readableDidRead', function () {
    return this._readableState ? !!this._readableState.dataEmitted || !!this._readableState.flowing : false;
  });
  def(proto, 'closed', function () {
    return this._readableState ? !!this._readableState.destroyed : false;
  });
  def(proto, 'errored', function () {
    return null;
  });
}

Readable.from = function from(iterable, opts) {
  if (typeof iterable === 'string' || (iterable && typeof iterable === 'object' && ArrayBuffer.isView(iterable))) {
    return new Readable({
      objectMode: true,
      ...opts,
      read() {
        this.push(iterable);
        this.push(null);
      },
    });
  }
  let iterator;
  const isAsync = iterable && typeof iterable[Symbol.asyncIterator] === 'function';
  if (isAsync) iterator = iterable[Symbol.asyncIterator]();
  else if (iterable && typeof iterable[Symbol.iterator] === 'function') iterator = iterable[Symbol.iterator]();
  else throw new TypeError('The "iterable" argument must be an instance of Iterable');
  let reading = false;
  return new Readable({
    objectMode: true,
    highWaterMark: 1,
    ...opts,
    async read() {
      if (reading) return;
      reading = true;
      try {
        for (;;) {
          const { value, done } = isAsync ? await iterator.next() : iterator.next();
          if (done) {
            this.push(null);
            break;
          }
          const v = value && typeof value.then === 'function' ? await value : value;
          if (!this.push(v)) break;
        }
      } catch (e) {
        this.destroy(e);
      } finally {
        reading = false;
      }
    },
  });
};

const promises = {
  pipeline: (...streams) =>
    new Promise((resolve, reject) => {
      const last = streams[streams.length - 1];
      if (last && typeof last === 'object' && !('pipe' in last) && !('write' in last) && !(typeof last[Symbol.asyncIterator] === 'function')) streams.pop();
      pipeline(...streams, (err, val) => (err ? reject(err) : resolve(val)));
    }),
  finished: (stream, opts) => new Promise((resolve, reject) => finished(stream, opts || {}, (err) => (err ? reject(err) : resolve()))),
};

function addAbortSignal(signal, stream) {
  const onAbort = () => stream.destroy(Object.assign(new Error('The operation was aborted'), { name: 'AbortError', code: 'ABORT_ERR' }));
  if (signal.aborted) onAbort();
  else signal.addEventListener('abort', onAbort, { once: true });
  return stream;
}
const isReadable = (s) => !!s && typeof s.read === 'function' && s.readable !== false && !(s._readableState && s._readableState.endEmitted);
const isDisturbed = (s) => !!(s && s._readableState && (s._readableState.dataEmitted || s._readableState.endEmitted));
const isErrored = () => false;
function duplexPair() {
  throw new Error('stream.duplexPair is not supported');
}

Object.assign(Stream, {
  Stream,
  Readable,
  Writable,
  Duplex,
  Transform,
  PassThrough,
  finished,
  pipeline,
  promises,
  addAbortSignal,
  isReadable,
  isDisturbed,
  isErrored,
  duplexPair,
  getDefaultHighWaterMark: (objectMode) => (objectMode ? 16 : 16384),
  setDefaultHighWaterMark() {},
  _isUint8Array: (v) => v instanceof Uint8Array,
});
module.exports = Stream;

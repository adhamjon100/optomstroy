'use strict';
// Шим `assert` (и `assert/strict`).
const { isDeepStrictEqual } = require('./node-util.cjs');

class AssertionError extends Error {
  constructor(opts = {}) {
    super(opts.message || 'Assertion failed');
    this.name = 'AssertionError';
    this.code = 'ERR_ASSERTION';
    this.actual = opts.actual;
    this.expected = opts.expected;
    this.operator = opts.operator;
  }
}
const fail = (message, actual, expected, operator) => {
  if (message instanceof Error) throw message;
  throw new AssertionError({ message, actual, expected, operator });
};
function assert(v, message) {
  if (!v) fail(message || 'The expression evaluated to a falsy value', v, true, '==');
}
assert.ok = assert;
assert.fail = (m) => fail(m || 'Failed');
assert.equal = (a, b, m) => (a == b ? undefined : fail(m || `${a} == ${b}`, a, b, '=='));
assert.notEqual = (a, b, m) => (a != b ? undefined : fail(m || `${a} != ${b}`, a, b, '!='));
assert.strictEqual = (a, b, m) => (Object.is(a, b) ? undefined : fail(m || `Expected values to be strictly equal: ${a} !== ${b}`, a, b, 'strictEqual'));
assert.notStrictEqual = (a, b, m) => (!Object.is(a, b) ? undefined : fail(m || 'Expected values to be not strictly equal', a, b, 'notStrictEqual'));
assert.deepEqual = (a, b, m) => (isDeepStrictEqual(a, b) ? undefined : fail(m || 'Expected values to be deeply equal', a, b, 'deepEqual'));
assert.deepStrictEqual = assert.deepEqual;
assert.notDeepStrictEqual = (a, b, m) => (!isDeepStrictEqual(a, b) ? undefined : fail(m || 'Expected values not to be deeply equal', a, b, 'notDeepStrictEqual'));
assert.notDeepEqual = assert.notDeepStrictEqual;
assert.throws = (fn, _e, m) => {
  try {
    fn();
  } catch {
    return;
  }
  fail(m || 'Missing expected exception.');
};
assert.doesNotThrow = (fn) => fn();
assert.rejects = async (p, _e, m) => {
  try {
    await (typeof p === 'function' ? p() : p);
  } catch {
    return;
  }
  fail(m || 'Missing expected rejection.');
};
assert.doesNotReject = async (p) => {
  await (typeof p === 'function' ? p() : p);
};
assert.match = (s, re, m) => (re.test(s) ? undefined : fail(m || `The input did not match ${re}`, s, re, 'match'));
assert.doesNotMatch = (s, re, m) => (!re.test(s) ? undefined : fail(m || `The input was expected to not match ${re}`, s, re, 'doesNotMatch'));
assert.ifError = (v) => {
  if (v !== null && v !== undefined) throw v;
};
assert.AssertionError = AssertionError;
assert.strict = assert;
module.exports = assert;

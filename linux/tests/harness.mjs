// A tiny test harness that runs unchanged under Node (`node`), GJS (`gjs -m`) and JavaScriptCore
// (`jsc -m`). It detects the runtime to read files, print and exit, and offers a few assertions.
//
//   test('name', () => { expectEqual(actual, expected); });
//   await runTests();   // prints ✔/✘ per test and a summary; exits non-zero on failure

// --- Runtime ---------------------------------------------------------------------------------------

/** Which JavaScript runtime this is, with file reading and exit for it. */
export async function detectRuntime() {
  if (typeof process !== 'undefined' && process.versions && process.versions.node) {
    const fs = await import('node:fs');
    return {
      name: `node ${process.versions.node}`,
      readText: (path) => fs.readFileSync(path, 'utf8'),
      args: process.argv.slice(2),
      exit: (code) => process.exit(code),
    };
  }
  try {
    const GLib = (await import('gi://GLib')).default;
    const System = (await import('system')).default;
    const decoder = new TextDecoder('utf-8');
    return {
      name: `gjs ${System.version}`,
      readText: (path) => {
        const [, bytes] = GLib.file_get_contents(path);
        return decoder.decode(bytes);
      },
      args: [...(System.programArgs ?? [])],
      exit: (code) => System.exit(code),
    };
  } catch {
    // not GJS
  }
  if (typeof readFile === 'function' || typeof read === 'function') {
    return {
      name: 'javascriptcore',
      readText: (path) => (typeof readFile === 'function' ? readFile(path) : read(path)),
      // jsc passes the words after `--` as the global `arguments` (not this function's arguments).
      args: [...(globalThis.scriptArgs ?? globalThis.arguments ?? [])],
      // jsc's quit() always exits with status 0, so a failed run ends with an uncaught error instead.
      exit: (code) => {
        if (code !== 0) throw new Error(`${code === 1 ? 'Tests failed' : `Exit ${code}`}`);
        if (typeof quit === 'function') quit();
      },
    };
  }
  throw new Error('Unknown JavaScript runtime: expected Node, GJS or JavaScriptCore');
}

export const print = (line) => {
  if (typeof globalThis.print === 'function') globalThis.print(line);
  else console.log(line);
};

/** The directory containing `metaURL` (a file:// URL), as a path. */
export function directoryOf(metaURL) {
  let path = String(metaURL).replace(/^file:\/\//, '');
  path = decodeURIComponent(path);
  return path.slice(0, path.lastIndexOf('/'));
}

// --- Tests -----------------------------------------------------------------------------------------

const tests = [];

/** Registers a test. `body` may throw (or return a promise); assertion failures are collected. */
export function test(name, body) {
  tests.push({name, body});
}

let failures = [];
let currentChecks = 0;

/** Counts one checked vector (fixture case) toward the summary. */
export function countCheck(n = 1) {
  currentChecks += n;
}

export function fail(message) {
  failures.push(message);
}

/** Records a failure unless `condition` holds. */
export function expect(condition, message) {
  if (!condition) failures.push(message);
}

export function expectEqual(actual, expected, label = '') {
  const difference = firstDifference(actual, expected);
  if (difference !== null) failures.push(`${label ? `${label}: ` : ''}${difference}`);
}

/** Expects `body` to throw; returns the error (or null when it didn't throw). */
export function expectThrows(body, label = '') {
  try {
    body();
  } catch (e) {
    return e;
  }
  failures.push(`${label ? `${label}: ` : ''}expected an error`);
  return null;
}

export function show(value) {
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'bigint') return `${value}n`;
  if (typeof value === 'number') return Object.is(value, -0) ? '-0' : String(value);
  if (value === undefined) return 'undefined';
  try {
    return JSON.stringify(value, (_, v) => (typeof v === 'bigint' ? `${v}n` : v));
  } catch {
    return String(value);
  }
}

/** Describes the first difference between two JSON-like values, or null when they are equal. */
export function firstDifference(actual, expected, path = '$') {
  if (typeof actual === 'number' && typeof expected === 'number') {
    return Object.is(actual, expected) ? null : `${path}: expected ${show(expected)}, got ${show(actual)}`;
  }
  if (typeof actual === 'bigint' || typeof expected === 'bigint') {
    return String(actual) === String(expected) ? null : `${path}: expected ${show(expected)}, got ${show(actual)}`;
  }
  if (actual === expected) return null;
  if (actual === null || expected === null || typeof actual !== 'object' || typeof expected !== 'object') {
    return `${path}: expected ${show(expected)}, got ${show(actual)}`;
  }
  if (Array.isArray(actual) !== Array.isArray(expected)) return `${path}: expected ${show(expected)}, got ${show(actual)}`;
  if (Array.isArray(actual)) {
    if (actual.length !== expected.length) {
      return `${path}: expected ${expected.length} items, got ${actual.length}: ${show(actual)} vs ${show(expected)}`;
    }
    for (let i = 0; i < actual.length; i++) {
      const d = firstDifference(actual[i], expected[i], `${path}[${i}]`);
      if (d !== null) return d;
    }
    return null;
  }
  const keysA = Object.keys(actual).filter((k) => actual[k] !== undefined).sort();
  const keysE = Object.keys(expected).filter((k) => expected[k] !== undefined).sort();
  if (keysA.join('\u0000') !== keysE.join('\u0000')) {
    return `${path}: expected keys ${show(keysE)}, got ${show(keysA)} (${show(actual)})`;
  }
  for (const k of keysA) {
    const d = firstDifference(actual[k], expected[k], `${path}.${k}`);
    if (d !== null) return d;
  }
  return null;
}

/** Runs the registered tests, prints ✔/✘ per test and a summary, and returns the failure count. */
export async function runTests({filter = null, maxFailuresShown = 12} = {}) {
  let passed = 0;
  let failed = 0;
  let checks = 0;
  for (const t of tests) {
    if (filter && !t.name.toLowerCase().includes(filter.toLowerCase())) continue;
    failures = [];
    currentChecks = 0;
    try {
      await t.body();
    } catch (e) {
      failures.push(`threw ${e && e.stack ? e.stack : e}`);
    }
    checks += currentChecks;
    const counted = currentChecks > 0 ? ` (${currentChecks} vectors)` : '';
    if (failures.length === 0) {
      passed++;
      print(`✔ ${t.name}${counted}`);
    } else {
      failed++;
      print(`✘ ${t.name}${counted}`);
      for (const f of failures.slice(0, maxFailuresShown)) print(`    ${f}`);
      if (failures.length > maxFailuresShown) print(`    … and ${failures.length - maxFailuresShown} more`);
    }
  }
  print(`\n${passed} passed, ${failed} failed; ${checks} golden vectors checked`);
  return failed;
}

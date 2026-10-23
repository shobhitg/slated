// A tiny test harness that runs unchanged under Node and GJS, mirroring the Swift harness's API
// (Tests/SlatedTests/Harness.swift): suites of named tests with expect/expectEqual/expectThrows.

import {stableStringify} from '../../gnome-extension/lib/prefs/util.js';

class Failure extends Error {}

let failures = [];

export function expect(condition, message = 'expected condition to be true') {
  if (!condition) failures.push(message);
}

export function expectEqual(actual, expected, message = '') {
  const a = stableStringify(actual);
  const e = stableStringify(expected);
  if (a !== e) failures.push(`${message ? `${message}: ` : ''}expected ${e}, got ${a}`);
}

/** Stops the test when `value` is null/undefined (like Swift's `require`). */
export function require(value, message = 'required value is missing') {
  if (value === null || value === undefined) throw new Failure(message);
  return value;
}

export function expectThrows(fn, pattern = null, message = 'expected an error') {
  try {
    fn();
  } catch (error) {
    if (pattern && !pattern.test(String(error?.message ?? error))) {
      failures.push(`${message}: error "${error?.message}" doesn't match ${pattern}`);
    }
    return error;
  }
  failures.push(message);
  return null;
}

export function suite(name, tests) {
  return {name, tests};
}

/** Runs the suites; returns the number of failed tests. */
export async function run(suites, filter = '') {
  let passed = 0;
  let failed = 0;
  for (const s of suites) {
    const selected = s.tests.filter(([name]) => !filter || `${s.name} ${name}`.toLowerCase().includes(filter.toLowerCase()));
    if (!selected.length) continue;
    print(`${s.name}`);
    for (const [name, fn] of selected) {
      failures = [];
      try {
        await fn();
      } catch (error) {
        if (!(error instanceof Failure)) failures.push(`threw ${error?.stack ?? error}`);
        else failures.push(error.message);
      }
      if (failures.length) {
        failed++;
        print(`  ✘ ${name}`);
        for (const f of failures) print(`      ${f}`);
      } else {
        passed++;
        print(`  ✔ ${name}`);
      }
    }
  }
  print(`\n${passed} passed, ${failed} failed`);
  return failed;
}

function print(line) {
  console.log(line);
}

/** The file system path of `relative` next to the module at `base` (import.meta.url). GJS has no URL class. */
export function resolvePath(relative, base) {
  const dir = decodeURIComponent(base.replace(/^file:\/\//, '')).replace(/\/[^/]*$/, '');
  return `${dir}/${relative.replace(/^\.\//, '')}`;
}

/** Reads a text file next to the tests (Node or GJS). */
export async function readText(relative, base) {
  const path = resolvePath(relative, base);
  if (globalThis.process?.versions?.node) {
    const fs = await import('node:fs');
    return fs.readFileSync(path, 'utf8');
  }
  const GLib = (await import('gi://GLib')).default;
  const [, bytes] = GLib.file_get_contents(path);
  return new TextDecoder().decode(bytes);
}

const isNode = Boolean(globalThis.process?.versions?.node);

/** Command-line arguments after the script (GJS has them in its built-in "system" module). */
export async function commandLineArgs() {
  if (isNode) return process.argv.slice(2);
  return [...(await import('system')).default.programArgs];
}

export async function exit(code) {
  if (isNode) process.exitCode = code;
  else if (code) (await import('system')).default.exit(code);
}

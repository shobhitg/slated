// Tests for Slated's Linux engine (linux/gnome-extension/lib/core): every golden vector in /fixtures
// (written by Swift: `make fixtures`) plus handwritten tests for what fixtures can't express.
//
//   node linux/tests/run.mjs [filter] [--fixtures <dir>]
//   gjs -m linux/tests/run.mjs [filter]
//   /System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc -m linux/tests/run.mjs [-- filter]
//
// `make linux-test` picks Node when present, else JavaScriptCore. Prints ✔/✘ per test and a summary;
// exits non-zero on failure. `--self-check` runs one deliberately failing test, to prove failures
// reach the exit code on this runtime.

import {detectRuntime, directoryOf, fail, print, runTests, test} from './harness.mjs';
import {registerFixtureTests} from './fixtures.mjs';
import {registerUnitTests} from './unit.mjs';

const runtime = await detectRuntime();
const testsDir = typeof import.meta.url === 'string' && import.meta.url.startsWith('file:') ? directoryOf(import.meta.url) : 'linux/tests';
const root = `${testsDir}/../..`;
const args = runtime.args.filter((a) => a !== '--');
const selfCheck = args.includes('--self-check');
// `--fixtures <dir>` checks another set of fixture files, such as `make fuzz`'s random ones.
const fixturesAt = args.indexOf('--fixtures');
const fixtures = fixturesAt >= 0 ? args[fixturesAt + 1] : `${root}/fixtures`;
const filter = args.find((a, i) => !a.startsWith('--') && !(fixturesAt >= 0 && i === fixturesAt + 1)) ?? null;

print(`Slated engine tests on ${runtime.name}`);
if (selfCheck) {
  test('self-check: a failing test fails the run', () => fail('deliberate failure'));
} else {
  registerFixtureTests(fixtures, runtime.readText);
  registerUnitTests({root, readText: runtime.readText});
}
const failed = await runTests({filter});
runtime.exit(failed === 0 ? 0 : 1);

// Which preferences code the tests never run: executes the unit tests and the UI smoke test under
// V8's coverage and lists, per file in lib/prefs (and lib/prefs/ui), the functions and blocks that
// never ran, with line numbers. A development aid for finding untested UI paths:
//
//   node linux/tests/prefs/coverage.mjs [--all]     (--all also lists uncovered blocks)

import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const prefsDir = path.resolve(here, '../../gnome-extension/lib/prefs');
const showBlocks = process.argv.includes('--all');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'slated-coverage-'));

for (const script of ['run.mjs', 'ui.mjs']) {
  const result = spawnSync(process.execPath, [path.join(here, script)], {env: {...process.env, NODE_V8_COVERAGE: dir}, encoding: 'utf8'});
  if (result.status !== 0) {
    console.log(`${script} failed:\n${result.stdout}${result.stderr}`);
    process.exitCode = 1;
  }
}

// Merge: a range counts as covered if any run covered it.
const files = new Map();
for (const name of fs.readdirSync(dir)) {
  const data = JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
  for (const script of data.result) {
    if (!script.url.startsWith('file://')) continue;
    const file = decodeURIComponent(new URL(script.url).pathname);
    if (!file.startsWith(prefsDir)) continue;
    const entry = files.get(file) ?? {ranges: new Map()};
    for (const fn of script.functions) {
      fn.ranges.forEach((range, index) => {
        const key = `${range.startOffset}:${range.endOffset}`;
        const previous = entry.ranges.get(key);
        entry.ranges.set(key, {
          ...range, fn: fn.functionName || '(anonymous)', isFunction: index === 0,
          count: Math.max(previous?.count ?? 0, range.count),
        });
      });
    }
    files.set(file, entry);
  }
}

let totalFunctions = 0;
let coveredFunctions = 0;
for (const file of [...files.keys()].sort()) {
  const source = fs.readFileSync(file, 'utf8');
  const lineOf = offset => source.slice(0, offset).split('\n').length;
  const ranges = [...files.get(file).ranges.values()];
  const functions = ranges.filter(r => r.isFunction && r.startOffset > 0);
  const missed = functions.filter(r => r.count === 0);
  totalFunctions += functions.length;
  coveredFunctions += functions.length - missed.length;
  const blocks = showBlocks ? ranges.filter(r => !r.isFunction && r.count === 0) : [];
  if (!missed.length && !blocks.length) continue;
  console.log(`\n${path.relative(prefsDir, file)}: ${functions.length - missed.length}/${functions.length} functions ran`);
  for (const r of missed) console.log(`  function ${r.fn} (line ${lineOf(r.startOffset)})`);
  for (const r of blocks) console.log(`  block in ${r.fn}, lines ${lineOf(r.startOffset)}–${lineOf(r.endOffset)}`);
}
console.log(`\n${coveredFunctions} of ${totalFunctions} functions in lib/prefs ran (${Math.round((100 * coveredFunctions) / Math.max(totalFunctions, 1))}%)`);
fs.rmSync(dir, {recursive: true, force: true});

// Loads every module of the extension (with GNOME stubbed out) so a misspelled import or export, or
// GNOME work done at import time, fails here instead of inside GNOME Shell.

import assert from 'node:assert/strict';
import {readdirSync, readFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {test} from 'node:test';
import {fileURLToPath, pathToFileURL} from 'node:url';

const extension = join(dirname(fileURLToPath(import.meta.url)), '../../gnome-extension');
const platform = join(extension, 'lib/platform');

test('every platform module links and evaluates without touching GNOME', async () => {
  const files = readdirSync(platform).filter((f) => f.endsWith('.js'));
  assert.ok(files.length >= 20, `found ${files.length} modules`);
  for (const file of files) {
    await assert.doesNotReject(import(pathToFileURL(join(platform, file)).href), `lib/platform/${file}`);
  }
});

test('the settings modules the extension shares (the migration and Slate importer) import no GTK or GNOME API', () => {
  // GNOME Shell must never load Gtk or Adw; lib/prefs/migration.js and what it imports are pure.
  const seen = new Set();
  const queue = [join(extension, 'lib/prefs/migration.js')];
  while (queue.length) {
    const file = queue.shift();
    if (seen.has(file)) continue;
    seen.add(file);
    const source = readFileSync(file, 'utf8');
    assert.ok(!/from\s+['"](gi|resource):/.test(source), `${file.slice(extension.length + 1)} imports a GNOME API`);
    for (const [, spec] of source.matchAll(/from\s+'(\.[^']+)'/g)) queue.push(join(dirname(file), spec));
  }
  assert.ok([...seen].some((f) => f.endsWith('importer.js')) && seen.size > 5, `followed ${seen.size} modules`);
});

test('extension.js exports the Extension subclass GNOME Shell instantiates', async () => {
  const module = await import(pathToFileURL(join(extension, 'extension.js')).href);
  assert.equal(typeof module.default, 'function');
  const instance = new module.default({uuid: 'slated@shobhitg.github.io'});
  assert.equal(typeof instance.enable, 'function');
  assert.equal(typeof instance.disable, 'function');
});

test('enable() never throws, even when GNOME APIs fail; disable() cleans up after it', async () => {
  const {default: SlatedExtension} = await import(pathToFileURL(join(extension, 'extension.js')).href);
  const instance = new SlatedExtension({uuid: 'slated@shobhitg.github.io'});
  instance.path = '/nonexistent';
  instance.metadata = {'version-name': '0.1.0'};
  instance.uuid = 'slated@shobhitg.github.io';
  const errors = [];
  const original = console.error;
  console.error = (...args) => errors.push(args.join(' '));
  try {
    assert.doesNotThrow(() => instance.enable());
    assert.doesNotThrow(() => instance.disable());
  } finally {
    console.error = original;
  }
  // With every GNOME call stubbed to throw, the failure is reported, not raised.
  assert.ok(errors.some((e) => e.includes("Slated couldn't start")));
});

test('runtime helpers read versions from metadata and build-info.json', async () => {
  const {buildInfo, parseVersionName} = await import(pathToFileURL(join(platform, 'runtime.js')).href);
  assert.deepEqual(parseVersionName('0.1.0'), {version: '0.1.0', commit: 'unknown'});
  assert.deepEqual(parseVersionName('0.1.0+3f2a9c1'), {version: '0.1.0', commit: '3f2a9c1'});
  assert.deepEqual(parseVersionName('0.2.0 (3f2a9c1-dirty)'), {version: '0.2.0', commit: '3f2a9c1-dirty'});
  assert.deepEqual(parseVersionName(undefined), {version: 'dev', commit: 'unknown'});
  assert.deepEqual(buildInfo({'version-name': '0.1.0'}, '{"commit": "abc1234", "builtAt": "2026-10-22T10:00:00Z", "build": 42}'), {
    version: '0.1.0',
    commit: 'abc1234',
    builtAt: '2026-10-22T10:00:00Z',
    build: '42',
  });
  assert.deepEqual(buildInfo({'version-name': '0.1.0'}, 'not json'), {version: '0.1.0', commit: 'unknown'});
});

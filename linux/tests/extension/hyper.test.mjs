import assert from 'node:assert/strict';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';

import {createFakeGnome} from './fake-gnome.mjs';
import {MemoryLog} from './fixtures.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {HyperManager, acceleratorOptions, chooseHyperMode, withCapsHyper, withoutCapsHyper} = await import(
  '../../gnome-extension/lib/platform/hyper.js'
);

test('adding caps:hyper keeps the other options and sets conflicting caps options aside', () => {
  assert.deepEqual(withCapsHyper(['compose:ralt', 'caps:escape', 'lv3:ralt_switch']), {
    options: ['compose:ralt', 'lv3:ralt_switch', 'caps:hyper'],
    removed: ['caps:escape'],
    added: true,
    changed: true,
  });
  assert.deepEqual(withCapsHyper([]), {options: ['caps:hyper'], removed: [], added: true, changed: true});
});

test('an existing caps:hyper is left alone and never counted as Slated’s', () => {
  const result = withCapsHyper(['compose:ralt', 'caps:hyper']);
  assert.equal(result.changed, false);
  assert.equal(result.added, false);
  assert.deepEqual(result.options, ['compose:ralt', 'caps:hyper']);
});

test('removing caps:hyper restores what was set aside, without duplicates', () => {
  assert.deepEqual(withoutCapsHyper(['compose:ralt', 'caps:hyper'], ['caps:escape']), ['compose:ralt', 'caps:escape']);
  assert.deepEqual(withoutCapsHyper(['caps:escape', 'caps:hyper'], ['caps:escape']), ['caps:escape']);
  assert.deepEqual(withoutCapsHyper(['compose:ralt']), ['compose:ralt']);
});

test('round trip leaves the user’s options as they were (order aside)', () => {
  const original = ['compose:ralt', 'caps:ctrl_modifier'];
  const added = withCapsHyper(original);
  assert.deepEqual(withoutCapsHyper(added.options, added.removed).sort(), [...original].sort());
});

test('mode choice: off, keyd when it runs, otherwise xkb', () => {
  assert.equal(chooseHyperMode({wanted: false, keyd: true}), 'off');
  assert.equal(chooseHyperMode({wanted: true, keyd: true}), 'keyd');
  assert.equal(chooseHyperMode({wanted: true, keyd: false}), 'xkb');
  assert.deepEqual(acceleratorOptions('xkb'), {hyperMode: 'xkb'});
  assert.deepEqual(acceleratorOptions('keyd'), {});
  assert.deepEqual(acceleratorOptions('off'), {});
});

test('keyd set up while Slated runs is picked up from its socket; when keyd goes, GNOME’s option comes back', () => {
  const dir = mkdtempSync(join(tmpdir(), 'slated-hyper-'));
  const socketPath = join(dir, 'keyd.socket');
  const xkbOptions = () => gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'];
  const watches = () => gnome.state.monitors.get(socketPath)?.size ?? 0;
  gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'] = ['compose:ralt'];
  let detected = 0;
  const manager = new HyperManager({log: new MemoryLog(), statePath: join(dir, 'hyper.json'), socketPath, onDetected: () => detected++});
  manager.detect();
  assert.equal(manager.keyd, false, 'no keyd yet');
  assert.equal(manager.apply({wanted: true}).mode, 'xkb');
  assert.deepEqual(xkbOptions(), ['compose:ralt', 'caps:hyper']);

  writeFileSync(socketPath, ''); // linux/install.sh --hyper-keyd starts keyd
  gnome.fileChanged(socketPath);
  assert.equal(detected, 1, 'the runtime is told to apply again');
  assert.deepEqual(manager.apply({wanted: true}), {wanted: true, mode: 'keyd', active: true, hyperIsSuper: false, pending: false});
  assert.deepEqual(xkbOptions(), ['compose:ralt'], 'caps:hyper is taken back');
  gnome.fileChanged(socketPath);
  assert.equal(detected, 1, 'only changes count');

  rmSync(socketPath); // keyd stops
  gnome.fileChanged(socketPath);
  assert.equal(detected, 2);
  assert.equal(manager.apply({wanted: true}).mode, 'xkb');

  manager.destroy();
  assert.equal(watches(), 0, 'the watch ends with the extension');
  assert.deepEqual(xkbOptions(), ['compose:ralt']);
  rmSync(dir, {recursive: true, force: true});
});

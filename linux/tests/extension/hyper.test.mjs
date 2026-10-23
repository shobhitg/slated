import assert from 'node:assert/strict';
import {test} from 'node:test';

import {
  acceleratorOptions,
  chooseHyperMode,
  withCapsHyper,
  withoutCapsHyper,
} from '../../gnome-extension/lib/platform/hyper.js';

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

import assert from 'node:assert/strict';
import {test} from 'node:test';

import {comboOf, comboText, bindingKey, fallbackComboText, modalOf} from '../../gnome-extension/lib/platform/combos.js';
import {
  abbreviateHome,
  appSelector,
  conditionMatches,
  defaultEntry,
  expandHome,
  gridSizes,
  integralRect,
  isWindowGeometry,
  normalizeCondition,
  orderedLeftToRight,
  screenContaining,
  sequenceSteps,
  stableStringify,
} from '../../gnome-extension/lib/platform/util.js';
import * as realCore from '../../gnome-extension/lib/core/index.js';
import {fakeCore} from './fake-core.mjs';
import {landscape, portrait} from './fixtures.mjs';

test('expandHome and abbreviateHome are inverses for paths under home', () => {
  assert.equal(expandHome('~/.slate.js', '/home/me'), '/home/me/.slate.js');
  assert.equal(expandHome('~', '/home/me'), '/home/me');
  assert.equal(expandHome('/etc/x', '/home/me'), '/etc/x');
  assert.equal(abbreviateHome('/home/me/.slate.js', '/home/me'), '~/.slate.js');
  assert.equal(abbreviateHome('/home/me', '/home/me/'), '~');
  assert.equal(abbreviateHome('/home/meow/x', '/home/me'), '/home/meow/x');
});

test('stableStringify sorts keys at every level', () => {
  assert.equal(stableStringify({b: 1, a: {d: [{z: 1, y: 2}], c: 3}}), '{"a":{"c":3,"d":[{"y":2,"z":1}]},"b":1}');
});

test('integralRect matches CGRect.integral, ignoring float noise', () => {
  assert.deepEqual(integralRect({x: 10.5, y: 0.2, width: 100, height: 50.5}), {x: 10, y: 0, width: 101, height: 51});
  assert.deepEqual(integralRect({x: 0, y: 32, width: 1920 / 3, height: 1048}), {x: 0, y: 32, width: 640, height: 1048});
  assert.deepEqual(integralRect({x: 639.9999999999, y: 0, width: 640.0000000001, height: 1}), {x: 640, y: 0, width: 640, height: 1});
});

test('screenContaining picks the largest overlap, then the main screen', () => {
  const screens = [landscape, portrait];
  assert.equal(screenContaining(screens, {x: 100, y: 100, width: 300, height: 300}), landscape);
  assert.equal(screenContaining(screens, {x: 1800, y: 100, width: 600, height: 300}), portrait);
  assert.equal(screenContaining(screens, {x: -5000, y: 0, width: 10, height: 10}), landscape);
  assert.equal(screenContaining([], null), null);
});

test('orderedLeftToRight sorts by x, then lower screens first', () => {
  const a = {...landscape, displayID: 1, frame: {x: 0, y: 0, width: 100, height: 100}};
  const b = {...landscape, displayID: 2, frame: {x: 0, y: 100, width: 100, height: 100}};
  const c = {...landscape, displayID: 3, frame: {x: -100, y: 0, width: 100, height: 100}};
  assert.deepEqual(orderedLeftToRight([a, b, c]).map((s) => s.displayID), [3, 2, 1]);
});

test('display default conditions accept plain and Swift-coded shapes', () => {
  const screens = [landscape, portrait];
  assert.deepEqual(normalizeCondition({count: {_0: 2}}), {count: 2});
  assert.deepEqual(normalizeCondition({resolutions: {_0: ['1920x1080']}}), {resolutions: ['1920x1080']});
  assert.deepEqual(normalizeCondition(3), {count: 3});
  assert.equal(conditionMatches({count: 2}, screens), true);
  assert.equal(conditionMatches({count: 1}, screens), false);
  assert.equal(conditionMatches({resolutions: ['1080x1920', '1920x1080']}, screens), true);
  assert.equal(conditionMatches({resolutions: ['1920x1080']}, screens), false);
  assert.equal(conditionMatches(null, screens), false);
  assert.deepEqual(defaultEntry({target: 'coding', condition: {count: {_0: 2}}}), {condition: {count: 2}, target: 'coding'});
  assert.equal(defaultEntry({condition: {count: 2}}), null);
});

test('config.json display defaults apply in both the current and the old shape', () => {
  const screens = [landscape, portrait];
  const file = `{"defaults": [{"target": "two", "count": 2}, {"target": "pair", "resolutions": ["1920x1080", "1080x1920"]},
    {"target": "old", "condition": {"count": {"_0": 2}}}]}`;
  const entries = realCore.decodeConfiguration(file).defaults.map(defaultEntry);
  assert.deepEqual(entries, [
    {condition: {count: 2}, target: 'two'},
    {condition: {resolutions: ['1920x1080', '1080x1920']}, target: 'pair'},
    {condition: {count: 2}, target: 'old'},
  ]);
  assert.ok(entries.every((entry) => conditionMatches(entry.condition, screens)));
  assert.equal(defaultEntry({target: 'none'}), null);
});

test('isWindowGeometry covers by-orientation pairs', () => {
  assert.equal(isWindowGeometry({op: 'move'}), true);
  assert.equal(isWindowGeometry({op: 'focus', direction: 'left'}), false);
  assert.equal(isWindowGeometry({op: 'by-orientation', landscape: {op: 'push'}, portrait: {op: 'corner'}}), true);
  assert.equal(isWindowGeometry({op: 'by-orientation', landscape: {op: 'push'}, portrait: {op: 'hint'}}), false);
});

test('sequenceSteps reads both canonical sequence shapes', () => {
  assert.deepEqual(sequenceSteps({op: 'sequence', operations: [{op: 'undo'}]}), [{action: {op: 'undo'}, keepWindow: false}]);
  assert.deepEqual(sequenceSteps({op: 'sequence', steps: [{action: {op: 'undo'}, keepWindow: true}]}), [{action: {op: 'undo'}, keepWindow: true}]);
});

test('appSelector understands Slate app selectors', () => {
  assert.deepEqual(appSelector('current'), {kind: 'current'});
  assert.deepEqual(appSelector('ALL'), {kind: 'all'});
  assert.deepEqual(appSelector('all-but:Firefox'), {kind: 'allBut', name: 'Firefox'});
  assert.deepEqual(appSelector(['A', 'B']), {kind: 'apps', names: ['A', 'B']});
  assert.deepEqual(appSelector('Terminal'), {kind: 'apps', names: ['Terminal']});
});

test('gridSizes reads the canonical map and lists', () => {
  assert.deepEqual(gridSizes({1: {width: 4, height: 2}, 0: {width: 6, height: 6}}), [
    {screen: '0', width: 6, height: 6},
    {screen: '1', width: 4, height: 2},
  ]);
  assert.deepEqual(gridSizes([{screen: '1920x1080', width: 3, height: 3}]), [{screen: '1920x1080', width: 3, height: 3}]);
  assert.deepEqual(gridSizes(undefined), []);
});

test('combos accept strings and KeyCombo objects', () => {
  assert.deepEqual(comboOf('hyper+a', fakeCore), {key: 'a', modifiers: ['ctrl', 'alt', 'shift', 'cmd']});
  assert.deepEqual(comboOf({key: 'b', modifiers: ['cmd']}, fakeCore), {key: 'b', modifiers: ['cmd']});
  assert.equal(comboText({key: 'a', modifiers: ['ctrl', 'alt', 'shift', 'cmd']}, fakeCore), 'hyper+a');
  assert.equal(comboText('ctrl+cmd+left', fakeCore), 'ctrl+cmd+left');
  assert.equal(fallbackComboText({key: 'x', modifiers: ['cmd', 'ctrl']}), 'ctrl+cmd+x');
  assert.equal(fallbackComboText({key: 'x', modifiers: ['cmd', 'ctrl', 'alt', 'shift', 'fn']}), 'fn+hyper+x');
  const modal = modalOf({keys: 'ctrl+alt+f4', toggle: 1}, fakeCore);
  assert.deepEqual(modal, {keys: {key: 'f4', modifiers: ['ctrl', 'alt']}, toggle: true});
  assert.equal(bindingKey({key: '1', modifiers: []}, modal, fakeCore), 'ctrl+alt+f4 1');
});

test('comboText falls back when the core cannot format yet', () => {
  const brokenCore = {
    parseKeyCombo() {
      throw new Error('Not implemented yet');
    },
    formatKeyCombo() {
      throw new Error('Not implemented yet');
    },
  };
  assert.equal(comboText({key: 'a', modifiers: ['ctrl', 'alt', 'shift', 'cmd']}, brokenCore), 'hyper+a');
});

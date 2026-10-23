import assert from 'node:assert/strict';
import {test} from 'node:test';

import {
  EVDEV_MODIFIERS,
  canTypeText,
  isTerminal,
  keyFor,
  keyPlan,
  keymapIsLatin,
  keysymForCharacter,
  keysymsForText,
  shouldPaste,
  sourceLayout,
} from '../../gnome-extension/lib/platform/input.js';
import {isModifierKeysym} from '../../gnome-extension/lib/platform/overlays.js';
import {gridCellAt, gridSizeFor, gridTarget} from '../../gnome-extension/lib/platform/util.js';
import {landscape, portrait} from './fixtures.mjs';

test('named keys and modifiers use layout-independent evdev codes', () => {
  assert.deepEqual(EVDEV_MODIFIERS, {ctrl: 29, shift: 42, alt: 56, cmd: 125});
  assert.deepEqual(keyFor('left'), {code: 105});
  assert.deepEqual(keyFor('Return'), {code: 28});
  assert.deepEqual(keyFor('delete'), {code: 14}, "Slate's delete is backspace");
  assert.deepEqual(keyFor('forwardDelete'), {code: 111});
  assert.deepEqual(keyFor('pageup'), {code: 104});
  assert.deepEqual(keyFor('esc'), {code: 1});
  assert.deepEqual(keyFor('space'), {code: 57});
  assert.deepEqual(keyFor('f1'), {code: 59});
  assert.deepEqual(keyFor('f10'), {code: 68});
  assert.deepEqual(keyFor('f11'), {code: 87});
  assert.deepEqual(keyFor('f12'), {code: 88});
  assert.deepEqual(keyFor('f13'), {code: 183});
  assert.deepEqual(keyFor('f20'), {code: 190});
  assert.deepEqual(keyFor('pad0'), {code: 82});
  assert.deepEqual(keyFor('pad7'), {code: 71});
  assert.deepEqual(keyFor('padEnter'), {code: 96});
  assert.deepEqual(keyFor('pad+'), {code: 78});
  assert.equal(keyFor('f99'), null);
  assert.equal(keyFor('nope'), null);
  assert.equal(keyFor(''), null);
});

test('character keys go by keysym on Latin layouts and by US position elsewhere', () => {
  assert.deepEqual(keyFor('a'), {keysym: 0x61});
  assert.deepEqual(keyFor('Z'), {keysym: 0x7a});
  assert.deepEqual(keyFor("'"), {keysym: 0x27});
  assert.deepEqual(keyFor('é'), {keysym: 0xe9});
  assert.deepEqual(keyFor('a', {latin: false}), {code: 30});
  assert.deepEqual(keyFor('v', {latin: false}), {code: 47});
  assert.deepEqual(keyFor('4', {latin: false}), {code: 5});
  assert.equal(keyFor('é', {latin: false}), null);
  assert.equal(keysymForCharacter('ab'), null);
});

test('a combo becomes modifier presses in a fixed order, then the key', () => {
  assert.deepEqual(keyPlan({key: '4', modifiers: ['cmd', 'shift']}), {modifiers: [42, 125], key: {keysym: 0x34}});
  assert.deepEqual(keyPlan({key: 'v', modifiers: ['shift', 'ctrl']}, {latin: false}), {modifiers: [29, 42], key: {code: 47}});
  assert.deepEqual(keyPlan({key: 'left', modifiers: ['fn', 'alt']}), {modifiers: [56], key: {code: 105}});
  assert.equal(keyPlan({key: 'unknown', modifiers: []}), null);
});

test('input sources: Latin layouts type, others and input methods paste', () => {
  assert.deepEqual(sourceLayout({type: 'xkb', id: 'de+nodeadkeys'}), {layout: 'de', variant: 'nodeadkeys', ime: false});
  assert.deepEqual(sourceLayout({type: 'ibus', id: 'anthy', xkbId: 'jp'}), {layout: 'jp', variant: '', ime: true});
  assert.deepEqual(sourceLayout({type: 'ibus', id: 'xkb:ru::rus'}), {layout: 'ru', variant: '', ime: false});
  assert.equal(sourceLayout(null), null);

  assert.equal(keymapIsLatin({type: 'xkb', id: 'us'}), true);
  assert.equal(keymapIsLatin({type: 'xkb', id: 'fr+azerty'}), true);
  assert.equal(keymapIsLatin({type: 'xkb', id: 'ru'}), false);
  assert.equal(keymapIsLatin({type: 'xkb', id: 'rs+latin'}), true);
  assert.equal(keymapIsLatin({type: 'xkb', id: 'gr'}), false);
  assert.equal(keymapIsLatin(null), true, 'unknown: assume Latin');

  assert.equal(canTypeText({type: 'xkb', id: 'us'}), true);
  assert.equal(canTypeText({type: 'xkb', id: 'ua'}), false);
  assert.equal(canTypeText({type: 'ibus', id: 'pinyin', xkbId: 'us'}), false, 'an input method would intercept typed keys');
  assert.equal(canTypeText({type: 'ibus', id: 'xkb:us::eng'}), true);
});

test('ASCII text types key by key; anything else must be pasted', () => {
  assert.deepEqual(keysymsForText('Hi!\n\tok'), [0x48, 0x69, 0x21, 0xff0d, 0xff09, 0x6f, 0x6b]);
  assert.deepEqual(keysymsForText('a\r\nb\rc'), [0x61, 0xff0d, 0x62, 0xff0d, 0x63]);
  assert.equal(keysymsForText('¯\\_(ツ)_/¯'), null);
  assert.equal(keysymsForText('café'), null);
  assert.deepEqual(keysymsForText(''), []);
});

test('insert-text methods choose typing or pasting like the macOS app', () => {
  assert.equal(shouldPaste('short', 'auto'), false);
  assert.equal(shouldPaste('x'.repeat(81), 'auto'), true);
  assert.equal(shouldPaste('x'.repeat(81), 'type'), false);
  assert.equal(shouldPaste('short', 'paste'), true);
  assert.equal(shouldPaste('naïve', 'type'), true, 'non-ASCII falls back to pasting');
  assert.equal(shouldPaste('short', 'type', {typeable: false}), true, 'a non-Latin layout falls back to pasting');
});

test('terminals get Ctrl+Shift+V', () => {
  assert.equal(isTerminal('org.gnome.Terminal'), true);
  assert.equal(isTerminal('org.gnome.Ptyxis'), true);
  assert.equal(isTerminal('kitty'), true);
  assert.equal(isTerminal('firefox'), false);
  assert.equal(isTerminal(null), false);
});

test('modifier keysyms are recognized so they don’t dismiss overlays', () => {
  for (const keysym of [0xffe1, 0xffe3, 0xffe5, 0xffe9, 0xffeb, 0xffed, 0xfe03]) assert.equal(isModifierKeysym(keysym), true);
  for (const keysym of [0x61, 0xff1b, 0xff0d, 0xffbe]) assert.equal(isModifierKeysym(keysym), false);
});

test('grid sizes come from the screen index or resolution, else 12×12', () => {
  const sizes = [
    {screen: '0', width: 6, height: 4},
    {screen: '1080x1920', width: 2, height: 3},
  ];
  assert.deepEqual(gridSizeFor(landscape, 0, sizes), {columns: 6, rows: 4});
  assert.deepEqual(gridSizeFor(portrait, 1, sizes), {columns: 2, rows: 3});
  assert.deepEqual(gridSizeFor(landscape, 2, []), {columns: 12, rows: 12});
  assert.deepEqual(gridSizeFor(landscape, 0, [{screen: '0', width: 0, height: NaN}]), {columns: 12, rows: 12});
});

test('a cell selection becomes that share of the work area', () => {
  const visible = landscape.visibleFrame; // 1920×1048 at y 32
  assert.deepEqual(gridTarget(visible, 6, 6, {col: 0, row: 0}, {col: 2, row: 5}), {x: 0, y: 32, width: 960, height: 1048});
  assert.deepEqual(gridTarget(visible, 6, 6, {col: 5, row: 3}, {col: 3, row: 0}), {x: 960, y: 32, width: 960, height: 699});
  assert.deepEqual(gridTarget(visible, 3, 3, {col: 1, row: 1}, {col: 1, row: 1}), {x: 640, y: 381, width: 640, height: 350});
});

test('points map to cells, clamped to the grid', () => {
  assert.deepEqual(gridCellAt(0, 0, 600, 400, 6, 4), {col: 0, row: 0});
  assert.deepEqual(gridCellAt(599, 399, 600, 400, 6, 4), {col: 5, row: 3});
  assert.deepEqual(gridCellAt(-20, 900, 600, 400, 6, 4), {col: 0, row: 3});
  assert.deepEqual(gridCellAt(150, 150, 600, 400, 6, 4), {col: 1, row: 1});
});

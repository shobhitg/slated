import assert from 'node:assert/strict';
import {test} from 'node:test';

import {MODIFIER_KEYSYMS, isTerminal, keysymForKey, keysymsForText, shouldPaste} from '../../gnome-extension/lib/platform/input.js';
import {isModifierKeysym} from '../../gnome-extension/lib/platform/overlays.js';
import {gridCellAt, gridSizeFor, gridTarget} from '../../gnome-extension/lib/platform/util.js';
import {landscape, portrait} from './fixtures.mjs';

test('Slate key names map to X keysyms', () => {
  assert.equal(keysymForKey('a'), 0x61);
  assert.equal(keysymForKey('A'), 0x61);
  assert.equal(keysymForKey('4'), 0x34);
  assert.equal(keysymForKey("'"), 0x27);
  assert.equal(keysymForKey('left'), 0xff51);
  assert.equal(keysymForKey('return'), 0xff0d);
  assert.equal(keysymForKey('delete'), 0xff08, "Slate's delete is backspace");
  assert.equal(keysymForKey('forwardDelete'), 0xffff);
  assert.equal(keysymForKey('pageup'), 0xff55);
  assert.equal(keysymForKey('esc'), 0xff1b);
  assert.equal(keysymForKey('f1'), 0xffbe);
  assert.equal(keysymForKey('f12'), 0xffc9);
  assert.equal(keysymForKey('f20'), 0xffd1);
  assert.equal(keysymForKey('pad0'), 0xffb0);
  assert.equal(keysymForKey('pad9'), 0xffb9);
  assert.equal(keysymForKey('padEnter'), 0xff8d);
  assert.equal(keysymForKey('pad+'), 0xffab);
  assert.equal(keysymForKey('é'), 0xe9);
  assert.equal(keysymForKey('nope'), null);
  assert.equal(keysymForKey(''), null);
  assert.deepEqual(MODIFIER_KEYSYMS, {ctrl: 0xffe3, alt: 0xffe9, shift: 0xffe1, cmd: 0xffeb});
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

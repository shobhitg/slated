// Synthesized input for automation (lib/platform/synth.js) and the "running" indicator
// (indicator.js) against the simulated GNOME Shell's Clutter virtual devices and St actors; plus the
// paste shortcut the clipboard switcher presses (input.js).

import assert from 'node:assert/strict';
import {beforeEach, test} from 'node:test';

import {createFakeGnome} from './fake-gnome.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {BUTTONS, InputSynthesizer, MODIFIER_KEYSYMS, automationKey, holdPlan} = await import('../../gnome-extension/lib/platform/synth.js');
const {AutomationIndicator} = await import('../../gnome-extension/lib/platform/indicator.js');
const {InputInjector} = await import('../../gnome-extension/lib/platform/input.js');
const {Timers} = await import('../../gnome-extension/lib/platform/timers.js');

beforeEach(() => {
  Object.assign(gnome.state, {typed: [], buttons: [], disposed: [], inputSource: {type: 'xkb', id: 'us', xkbId: 'us'}});
  gnome.global.get_pointer = () => [0, 0, 0];
});

test('modifier keys press by keysym; other keys like keystroke does', () => {
  assert.deepEqual(MODIFIER_KEYSYMS, {
    shift: 0xffe1, rightShift: 0xffe2, ctrl: 0xffe3, rightCtrl: 0xffe4, alt: 0xffe9, rightAlt: 0xffea, cmd: 0xffeb, rightCmd: 0xffec,
  });
  assert.deepEqual(automationKey('shift'), {keysym: 0xffe1}, 'Shift_L');
  assert.deepEqual(automationKey('rightCmd'), {keysym: 0xffec}, 'Super_R');
  assert.deepEqual(automationKey('w'), {keysym: 0x77}, 'the key labeled W');
  assert.deepEqual(automationKey('w', {latin: false}), {code: 17}, 'by US position on non-Latin layouts');
  assert.deepEqual(automationKey('space'), {code: 57});
  assert.equal(automationKey('mouse4'), null);
  assert.deepEqual(holdPlan({key: 'w', modifiers: ['shift', 'ctrl']}), [{keysym: 0xffe3}, {keysym: 0xffe1}, {keysym: 0x77}], 'modifiers first, by keysym');
  assert.deepEqual(holdPlan({key: 'shift', modifiers: ['shift']}), [{keysym: 0xffe1}], 'shift+shift is one key');
  assert.equal(holdPlan({key: 'bogus', modifiers: []}), null);
  assert.deepEqual(BUTTONS, {left: 1, middle: 2, right: 3});
});

test('clicks, held buttons and keys go through virtual devices with increasing timestamps', () => {
  const synth = new InputSynthesizer();
  assert.deepEqual(synth.click('left', 2), {ok: true});
  assert.deepEqual(gnome.state.buttons.map((b) => [b.button, b.pressed]), [[1, true], [1, false], [1, true], [1, false]], 'a double-click');
  const times = gnome.state.buttons.map((b) => b.time);
  assert.ok(times.every((t, i) => i === 0 || t > times[i - 1]), 'timestamps only move forward');
  synth.mouse('right', true);
  synth.key({key: 'w', modifiers: ['shift']}, true);
  assert.deepEqual(gnome.state.typed, [{keysym: 0xffe1, pressed: true}, {keysym: 0x77, pressed: true}]);
  synth.key({key: 'w', modifiers: ['shift']}, false);
  assert.deepEqual(gnome.state.typed.slice(2), [{keysym: 0x77, pressed: false}, {keysym: 0xffe1, pressed: false}], 'released key first');
  assert.deepEqual(synth.mouse('back', true), {ok: false, error: 'Unknown mouse button back'});
  assert.match(synth.key({key: 'bogus', modifiers: []}, true).error, /isn't a key/);
  synth.destroy();
  assert.deepEqual(gnome.state.buttons.at(-1), {...gnome.state.buttons.at(-1), button: 3, pressed: false}, 'destroy releases the held right button');
  assert.deepEqual(gnome.state.disposed.sort(), ['keyboard', 'pointer']);
  assert.throws(() => synth.mouse('left', true), /stopping/);
});

test('releaseAll lets go of exactly what is down', () => {
  const synth = new InputSynthesizer();
  synth.key({key: 'ctrl', modifiers: []}, true);
  synth.key({key: 'space', modifiers: []}, true);
  synth.mouse('middle', true);
  gnome.state.typed = [];
  gnome.state.buttons = [];
  synth.releaseAll();
  assert.deepEqual(gnome.state.typed.map((t) => [t.keysym ?? t.code, t.pressed]).sort(), [[57, false], [0xffe3, false]]);
  assert.deepEqual(gnome.state.buttons.map((b) => [b.button, b.pressed]), [[2, false]]);
  gnome.state.typed = [];
  synth.releaseAll();
  assert.deepEqual(gnome.state.typed, [], 'nothing left to release');
});

test('the indicator shows what runs and how to stop it, above windows, and hides when idle', () => {
  const indicator = new AutomationIndicator();
  indicator.update([], {stopLabel: '✦ Esc'});
  assert.equal(indicator.text, null, 'nothing runs: nothing shown');
  indicator.update([{title: 'Repeat click left every 100 ms'}], {stopLabel: '✦ Esc'});
  assert.equal(indicator.text, 'Repeat click left every 100 ms');
  const pill = gnome.modules['resource:///org/gnome/shell/ui/main.js'].uiGroup.children.find((a) => a.style_class === 'slated-automation-pill');
  assert.ok(pill && pill.visible && pill.reactive === false);
  assert.equal(pill.children[2].text, '✦ Esc to stop');
  assert.equal(pill.y, 32 + 10, 'just below the top bar');
  indicator.update([{title: 'a'}, {title: 'b'}], {stopLabel: null});
  assert.equal(indicator.text, '2 automations running');
  assert.equal(pill.children[2].visible, false, 'no stop shortcut: no hint');
  indicator.update([{title: 'a'}], {visible: false});
  assert.equal(indicator.text, null, 'showIndicator off');
  indicator.destroy();
  assert.ok(pill.destroyed);
});

test('the paste shortcut is Ctrl+V, or Ctrl+Shift+V in terminals, once modifiers are up', () => {
  const timers = new Timers();
  let app = 'org.gnome.TextEditor';
  const input = new InputInjector({timers, focusedAppId: () => app});
  input.pasteShortcut();
  assert.deepEqual(gnome.state.typed.map((t) => [t.code ?? t.keysym, t.pressed]), [[29, true], [0x76, true], [0x76, false], [29, false]]);
  gnome.state.typed = [];
  app = 'org.gnome.Ptyxis';
  let mods = 4; // Ctrl still held from Ctrl+3 in the switcher
  gnome.global.get_pointer = () => [0, 0, mods];
  input.pasteShortcut();
  input.pasteShortcut();
  assert.deepEqual(gnome.state.typed, [], 'waits while a modifier is held');
  gnome.loop.advance(100);
  assert.deepEqual(gnome.state.typed, []);
  mods = 0;
  gnome.loop.advance(25);
  assert.deepEqual(gnome.state.typed.slice(0, 4).map((t) => [t.code ?? t.keysym, t.pressed]), [[29, true], [42, true], [0x76, true], [0x76, false]]);
  assert.equal(gnome.state.typed.length, 12, 'both queued pastes ran, in order');
  assert.equal(gnome.loop.pending, 0, 'one shared poller, gone when done');
  input.destroy();
});

test('cancelPending drops keys waiting for modifiers, so a stopped automation types nothing later', () => {
  const timers = new Timers();
  const input = new InputInjector({timers});
  gnome.global.get_pointer = () => [0, 0, 8]; // Alt held, as for Alt+Tab
  input.pressKeys({key: 'e', modifiers: []});
  input.pressKeys({key: 'e', modifiers: []});
  input.cancelPending();
  assert.equal(gnome.loop.pending, 0, 'the poller is gone');
  gnome.global.get_pointer = () => [0, 0, 0];
  gnome.loop.advance(2000);
  assert.deepEqual(gnome.state.typed, [], 'nothing typed once Alt is let go');
  input.pressKeys({key: 'e', modifiers: []});
  assert.equal(gnome.state.typed.length, 2, 'later keys still work');
  input.destroy();
});

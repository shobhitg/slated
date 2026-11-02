// keyboard.keyRepeat on GNOME (keyRepeat.js) and the Caps Lock lock cleared under the Hyper key
// (capsLock.js): against fake GSettings, a fake keymap and virtual keyboard (fake-gnome.mjs), and
// wired into the runtime.

import assert from 'node:assert/strict';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, beforeEach, test} from 'node:test';

import {configPathIn, writeConfigFiles} from './config-files.mjs';
import {fakeCore} from './fake-core.mjs';
import {createFakeGnome} from './fake-gnome.mjs';
import {FakeTimers, MemoryLog} from './fixtures.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {KeyRepeatManager, keyRepeatWrites} = await import('../../gnome-extension/lib/platform/keyRepeat.js');
const {CAPS_LOCK_KEYSYM, CapsLockGuard} = await import('../../gnome-extension/lib/platform/capsLock.js');
const {SlatedRuntime} = await import('../../gnome-extension/lib/platform/runtime.js');

console.error = () => {};
console.log = () => {};

const KEYBOARD = 'org.gnome.desktop.peripherals.keyboard';
const XKB = 'org.gnome.desktop.input-sources:xkb-options';
const homes = [];
let home;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'slated-keyboard-'));
  homes.push(home);
  Object.assign(gnome.state, {
    home,
    env: {SLATED_KEYD_CONF: join(home, 'etc/keyd/slated.conf')},
    programs: {},
    subprocesses: undefined,
    focused: null,
    windows: [],
    apps: [],
    settings: {[XKB]: ['compose:ralt'], [`${KEYBOARD}:repeat`]: true, [`${KEYBOARD}:delay`]: 500, [`${KEYBOARD}:repeat-interval`]: 30},
    settingsWrites: [],
    settingsReadOnly: false,
    taken: new Set(),
    grabs: new Map(),
    allowed: {},
    locked: false,
    statusArea: {},
    launched: [],
    typed: [],
    capsLock: false,
  });
});

after(() => {
  for (const dir of homes) rmSync(dir, {recursive: true, force: true});
});

const statePath = (name) => join(home, '.local/state/slated', name);
const quiet = {clipboard: {shortcut: null}, automation: {stopShortcut: null}};
const writeConfig = (config) => writeConfigFiles(home, {...quiet, ...config});
const readConfig = () => JSON.parse(readFileSync(configPathIn(home), 'utf8'));
const status = () => JSON.parse(readFileSync(statePath('status.json'), 'utf8'));
const gnomeRepeat = () => ({
  repeat: gnome.state.settings[`${KEYBOARD}:repeat`],
  delay: gnome.state.settings[`${KEYBOARD}:delay`],
  interval: gnome.state.settings[`${KEYBOARD}:repeat-interval`],
});

function logEvents() {
  if (!existsSync(statePath('slated.log'))) return [];
  return readFileSync(statePath('slated.log'), 'utf8').trim().split('\n').map((line) => JSON.parse(line));
}
const events = (name) => logEvents().filter((e) => e.event === name);

function startRuntime() {
  const runtime = new SlatedRuntime({path: join(home, 'extension'), metadata: {'version-name': '0.1.0'}, uuid: 'slated@shobhitg.github.io', core: fakeCore});
  runtime.start();
  gnome.loop.run();
  return runtime;
}

const capsTaps = () => gnome.state.typed.filter((t) => t.keysym === CAPS_LOCK_KEYSYM);

// --- Key repeat ------------------------------------------------------------------------------------

test('only what differs is written, and turning repeat on counts', () => {
  assert.deepEqual(keyRepeatWrites({enabled: true, delay: 200, interval: 17}, {delay: 200, interval: 17}), []);
  assert.deepEqual(keyRepeatWrites({enabled: false, delay: 500, interval: 17}, {delay: 200, interval: 17}), [
    ['set_boolean', 'repeat', true],
    ['set_uint', 'delay', 200],
  ]);
  assert.deepEqual(keyRepeatWrites(null, {delay: 200, interval: 17}).length, 3);
});

test('applying sets GNOME’s repeat, delay and interval once, logs it once, and nothing when absent', () => {
  const log = new MemoryLog();
  const manager = new KeyRepeatManager({log, markerPath: join(home, 'marker.json'), settings: () => new gnome.modules['gi://Gio'].Settings({schema_id: KEYBOARD})});
  assert.deepEqual(manager.apply(null), {state: 'off', delay: null, interval: null});
  assert.deepEqual(gnome.state.settingsWrites, [], 'absent: GNOME’s own setting is left alone');

  gnome.state.settings[`${KEYBOARD}:repeat`] = false;
  assert.deepEqual(manager.apply({delay: 200, interval: 17}), {state: 'applied', delay: 200, interval: 17});
  assert.deepEqual(gnomeRepeat(), {repeat: true, delay: 200, interval: 17});
  assert.equal(gnome.state.settingsWrites.length, 3);
  assert.deepEqual(manager.apply({delay: 200, interval: 17}), {state: 'applied', delay: 200, interval: 17});
  assert.equal(gnome.state.settingsWrites.length, 3, 'nothing written when GNOME already repeats that way');
  const applied = log.events.filter((e) => e.event === 'keyboard.key_repeat_applied');
  assert.deepEqual(applied.map((e) => e.data), [{delay: 200, interval: 17, live: true, changed: true}]);

  // Out-of-range values (a hand edit) are clamped like config.json's reader does.
  manager.apply({delay: 5, interval: 9000});
  assert.deepEqual(gnomeRepeat(), {repeat: true, delay: 100, interval: 500});
});

test('a GSettings failure is reported, not thrown', () => {
  const log = new MemoryLog();
  gnome.state.settingsReadOnly = true;
  const manager = new KeyRepeatManager({log, markerPath: join(home, 'marker.json'), settings: () => new gnome.modules['gi://Gio'].Settings({schema_id: KEYBOARD})});
  assert.deepEqual(manager.apply({delay: 200, interval: 17}), {state: 'failed', delay: 200, interval: 17});
  assert.equal(log.events.filter((e) => e.event === 'keyboard.key_repeat_failed').length, 1);
});

test('first run: GNOME’s key repeat goes into config.json once, and turning it off afterwards sticks', () => {
  gnome.state.settings[`${KEYBOARD}:delay`] = 250;
  gnome.state.settings[`${KEYBOARD}:repeat-interval`] = 25;
  writeConfig({keyboard: {capsLock: 'off'}});
  let runtime = startRuntime();
  assert.deepEqual(readConfig().keyboard.keyRepeat, {delay: 250, interval: 25});
  assert.deepEqual(events('keyboard.key_repeat_captured').map((e) => e.data), [{delay: 250, interval: 25}]);
  assert.ok(existsSync(statePath('key-repeat.json')));
  assert.deepEqual(gnome.state.settingsWrites, [], 'capturing changes nothing in GNOME');
  assert.deepEqual(status().keyRepeat, {state: 'applied', delay: 250, interval: 25});
  runtime.stop();

  // The switch off in Settings removes keyRepeat; the next start doesn't capture again.
  writeConfig({keyboard: {capsLock: 'off'}});
  runtime = startRuntime();
  assert.equal(readConfig().keyboard.keyRepeat, undefined);
  assert.equal(events('keyboard.key_repeat_captured').length, 1);
  assert.deepEqual(status().keyRepeat, {state: 'off', delay: null, interval: null});
  runtime.stop();
});

test('a keyRepeat copied from another computer is applied at once and live on edits, and stays after disable', () => {
  writeConfig({keyboard: {keyRepeat: {delay: 200, interval: 17}}});
  const runtime = startRuntime();
  assert.equal(events('keyboard.key_repeat_captured').length, 0);
  assert.ok(existsSync(statePath('key-repeat.json')), 'this computer counts as captured: turning it off sticks');
  assert.deepEqual(gnomeRepeat(), {repeat: true, delay: 200, interval: 17});
  assert.deepEqual(status().keyRepeat, {state: 'applied', delay: 200, interval: 17});

  writeConfig({keyboard: {keyRepeat: {delay: 300, interval: 40}}});
  gnome.fileChanged(configPathIn(home));
  gnome.loop.advance(300);
  assert.deepEqual(gnomeRepeat(), {repeat: true, delay: 300, interval: 40});
  assert.deepEqual(events('keyboard.key_repeat_applied').map((e) => [e.data.delay, e.data.interval]), [[200, 17], [300, 40]]);

  runtime.stop();
  assert.deepEqual(gnomeRepeat(), {repeat: true, delay: 300, interval: 40}, 'your preference, not undone');
});

test('nothing is captured while config.json can’t be read, or while GNOME’s key repeat is off', () => {
  writeConfigFiles(home, {});
  writeFileSync(configPathIn(home), '{"keyboard": {"capsLock": 5}}');
  let runtime = startRuntime();
  assert.equal(readFileSync(configPathIn(home), 'utf8'), '{"keyboard": {"capsLock": 5}}');
  assert.equal(existsSync(statePath('key-repeat.json')), false, 'tried again once the file can be read');
  runtime.stop();

  gnome.state.settings[`${KEYBOARD}:repeat`] = false;
  writeConfig({keyboard: {capsLock: 'off'}});
  runtime = startRuntime();
  assert.equal(readConfig().keyboard.keyRepeat, undefined, 'applying one would turn repeating on');
  assert.equal(gnome.state.settings[`${KEYBOARD}:repeat`], false);
  assert.equal(events('keyboard.key_repeat_not_captured').length, 1);
  assert.ok(existsSync(statePath('key-repeat.json')));
  runtime.stop();
});

// --- Caps Lock under the Hyper key ----------------------------------------------------------------

/** A keymap whose lock a Caps_Lock tap toggles (unless `dropTaps`), with 'state-changed'. */
function fakeKeymap({dropTaps = false} = {}) {
  const handlers = new Map();
  let next = 1;
  const keymap = {
    on: false,
    taps: 0,
    get_caps_lock_state: () => keymap.on,
    connect: (signal, callback) => {
      handlers.set(next, {signal, callback});
      return next++;
    },
    disconnect: (id) => handlers.delete(id),
    set(on) {
      keymap.on = on;
      for (const h of handlers.values()) if (h.signal === 'state-changed') h.callback(keymap);
    },
    tap() {
      keymap.taps++;
      if (!dropTaps) keymap.set(!keymap.on);
      return {ok: true};
    },
    get handlers() {
      return handlers.size;
    },
  };
  return keymap;
}

function guard(keymap, {hyper = true} = {}) {
  const log = new MemoryLog();
  const timers = new FakeTimers();
  const state = {hyper};
  const g = new CapsLockGuard({keymap, tap: () => keymap.tap(), timers, log, hyperActive: () => state.hyper}).start();
  return {g, log, timers, state, logged: (name) => log.events.filter((e) => e.event === name)};
}

test('a lock that turns on while Caps Lock is Hyper is turned off again, and logged without keystrokes', () => {
  const keymap = fakeKeymap();
  const {logged} = guard(keymap);
  keymap.set(true);
  assert.equal(keymap.on, false);
  assert.equal(keymap.taps, 1);
  assert.deepEqual(logged('hyper.caps_lock_cleared').map((e) => e.data), [{reason: 'caps lock turned on'}]);
});

test('with Hyper off the lock is yours: nothing is tapped', () => {
  const keymap = fakeKeymap();
  const {g} = guard(keymap, {hyper: false});
  keymap.set(true);
  assert.equal(keymap.on, true);
  assert.equal(keymap.taps, 0);
  assert.equal(g.clear('nothing to do') && false, false);
});

test('a tap the keymap drops is reported once, after a moment, with advice', () => {
  const keymap = fakeKeymap({dropTaps: true});
  const {g, timers, logged} = guard(keymap);
  keymap.set(true);
  assert.equal(logged('hyper.caps_lock_clear_failed').length, 0, 'waits for the lock to go off');
  timers.advance(300);
  const [failed] = logged('hyper.caps_lock_clear_failed');
  assert.equal(failed.level, 'error');
  assert.match(failed.data.advice, /Turn the Hyper key off/);
  g.clear('again');
  timers.advance(300);
  assert.equal(logged('hyper.caps_lock_clear_failed').length, 1, 'not repeated');
  assert.equal(logged('hyper.caps_lock_cleared').length, 0);
});

test('clearSoon waits for the keymap; destroy disconnects', () => {
  const keymap = fakeKeymap();
  const {g, timers, logged} = guard(keymap);
  keymap.on = true; // already on (no signal)
  g.clearSoon('hyper mode changed');
  assert.equal(keymap.taps, 0);
  timers.advance(500);
  assert.equal(keymap.on, false);
  assert.deepEqual(logged('hyper.caps_lock_cleared').map((e) => e.data.reason), ['hyper mode changed']);
  g.destroy();
  assert.equal(keymap.handlers, 0);
});

test('turning Hyper on clears a lock that was on, before GNOME’s caps:hyper option takes the key away', () => {
  gnome.state.capsLock = true;
  writeConfig({keyboard: {capsLock: 'off'}});
  const runtime = startRuntime();
  assert.equal(gnome.state.capsLock, true, 'Hyper off: Caps Lock is a plain Caps Lock');
  assert.equal(capsTaps().length, 0);

  writeConfig({keyboard: {capsLock: 'hyper'}});
  gnome.fileChanged(configPathIn(home));
  gnome.loop.advance(300);
  assert.deepEqual(gnome.state.settings[XKB], ['compose:ralt', 'caps:hyper']);
  assert.equal(gnome.state.capsLock, false, 'tapped while the keymap still had Caps_Lock');
  assert.deepEqual(capsTaps(), [{keysym: CAPS_LOCK_KEYSYM, pressed: true}, {keysym: CAPS_LOCK_KEYSYM, pressed: false}]);
  assert.deepEqual(events('hyper.caps_lock_cleared').map((e) => e.data), [{reason: 'hyper turned on'}]);
  runtime.stop();
});

test('starting with Hyper on clears the lock too; a paused Slated leaves it alone', () => {
  gnome.state.capsLock = true;
  writeConfig({keyboard: {capsLock: 'hyper'}});
  const runtime = startRuntime();
  assert.equal(gnome.state.capsLock, false);
  assert.equal(events('hyper.caps_lock_cleared').length, 1);

  runtime.setPaused(true);
  gnome.loop.run();
  gnome.capsLock(true); // Caps Lock is plain again while paused
  gnome.loop.run();
  assert.equal(gnome.state.capsLock, true, 'yours to turn on while paused');
  runtime.stop();
});

test('a lock that can’t be tapped off under caps:hyper is cleared once keyd takes over the key', () => {
  // GNOME's option is in use, and the lock comes on anyway (another app, a second keyboard layout).
  writeConfig({keyboard: {capsLock: 'hyper'}});
  Object.assign(gnome.state, {programs: {systemctl: '/usr/bin/systemctl'}, subprocesses: []});
  const runtime = startRuntime();
  gnome.capsLock(true);
  gnome.loop.run();
  gnome.loop.advance(300);
  assert.equal(gnome.state.capsLock, true, 'no Caps_Lock in the keymap while caps:hyper is set');
  assert.equal(events('hyper.caps_lock_clear_failed').length, 1);

  // linux/install.sh --hyper-keyd: keyd maps Caps Lock; Slated switches modes, takes caps:hyper out,
  // and taps Caps_Lock once the keymap has it again.
  const etc = join(home, 'etc/keyd');
  mkdirSync(etc, {recursive: true});
  writeFileSync(join(etc, 'slated.conf'), '[ids]\n*\n\n[main]\ncapslock = layer(hyper)\n');
  gnome.fileChanged(etc);
  gnome.state.subprocesses[0].exit(true);
  gnome.loop.run();
  assert.equal(status().hyper.mode, 'keyd');
  assert.deepEqual(gnome.state.settings[XKB], ['compose:ralt']);
  gnome.loop.advance(500);
  gnome.loop.run();
  assert.equal(gnome.state.capsLock, false);
  assert.deepEqual(events('hyper.caps_lock_cleared').map((e) => e.data.reason), ['hyper mode changed']);
  runtime.stop();
  assert.equal(gnome.keymapHandlers(), 0, 'disable() disconnects from the keymap');
});

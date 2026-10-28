// Game automation and clipboard history wired into the runtime, with the real engine (lib/core)
// against the simulated GNOME Shell: built-in shortcuts, status.json, per-app grabs that follow focus,
// mouse-button triggers, while-held release through key repeat, the safety stops, and clipboard copies.

import assert from 'node:assert/strict';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {after, afterEach, beforeEach, test} from 'node:test';

import * as realCore from '../../gnome-extension/lib/core/index.js';
import {createFakeGnome} from './fake-gnome.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {SlatedRuntime} = await import('../../gnome-extension/lib/platform/runtime.js');
const {MOUSE_BUTTON_REASON} = await import('../../gnome-extension/lib/platform/keybindings.js');
console.error = () => {};
console.log = () => {};

const KEYBOARD = 'org.gnome.desktop.peripherals.keyboard';
const HYPER = '<Control><Alt><Shift><Super>';
const homes = [];
let home;
let runtime;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'slated-automation-'));
  homes.push(home);
  Object.assign(gnome.state, {
    home,
    env: {},
    focused: null,
    windows: [],
    apps: [],
    settings: {
      'org.gnome.desktop.input-sources:xkb-options': [],
      [`${KEYBOARD}:repeat`]: true,
      [`${KEYBOARD}:delay`]: 500,
      [`${KEYBOARD}:repeat-interval`]: 30,
    },
    taken: new Set(),
    grabs: new Map(),
    allowed: {},
    locked: false,
    typed: [],
    buttons: [],
    disposed: [],
    clipboard: null,
    clipboardMimeTypes: [],
    chrome: new Set(),
    modal: [],
    modifiers: 0,
    overview: false,
  });
});

afterEach(() => {
  runtime?.stop();
  runtime = null;
  assert.deepEqual(events('runtime.error'), [], 'no part of the runtime failed');
});

after(() => {
  for (const dir of homes) rmSync(dir, {recursive: true, force: true});
});

const configPath = () => join(home, '.config/slated/config.json');
const statePath = (name) => join(home, '.local/state/slated', name);

function writeConfig(config) {
  mkdirSync(dirname(configPath()), {recursive: true});
  writeFileSync(configPath(), JSON.stringify({general: {loadSlateConfigs: false}, ...config}, null, 2));
}

function logEvents() {
  if (!existsSync(statePath('slated.log'))) return [];
  return readFileSync(statePath('slated.log'), 'utf8').trim().split('\n').map((line) => JSON.parse(line));
}

const events = (name) => logEvents().filter((e) => e.event === name);
const status = () => {
  gnome.loop.run();
  return JSON.parse(readFileSync(statePath('status.json'), 'utf8'));
};
const clicks = () => gnome.state.buttons.filter((b) => b.pressed).length;

function start(config) {
  writeConfig(config);
  runtime = new SlatedRuntime({path: join(home, 'extension'), metadata: {'version-name': '0.1.0'}, uuid: 'slated@shobhit-aida.github.io', core: realCore});
  runtime.start();
  gnome.loop.run();
  return runtime;
}

const game = {id: 'org.prismlauncher.PrismLauncher', name: 'Prism Launcher'};
const autoClick = {op: 'repeat', action: {op: 'click', button: 'left'}, interval: 0.1};

test('the stop and clipboard shortcuts are registered, and status.json reports automation and the clipboard', () => {
  start({bindings: [{keys: 'hyper+f', action: autoClick}]});
  assert.deepEqual(gnome.accelerators(), [`${HYPER}Escape`, `${HYPER}f`, '<Shift><Super>v']);
  const s = status();
  assert.deepEqual(s.hotkeys, {'hyper+esc': 'active', 'hyper+f': 'active', 'shift+cmd+v': 'active'});
  assert.deepEqual(s.automation, {running: [], shortcuts: [], stopShortcut: 'hyper+esc', whileHeld: 'key-repeat'});
  assert.deepEqual(s.clipboard, {enabled: true, items: 0});
});

test('a repeat binding clicks until the stop shortcut; with the island off, the pill and status follow', () => {
  start({bindings: [{keys: 'hyper+f', action: autoClick}], island: {enabled: false}});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  assert.ok(gnome.press(`${HYPER}f`));
  gnome.loop.advance(250);
  assert.equal(clicks(), 3);
  assert.deepEqual(status().automation.running, ['Repeat click left every 100 ms']);
  assert.deepEqual(status().automation.shortcuts, ['hyper+f'], 'Settings can tell which binding runs');
  const ui = gnome.modules['resource:///org/gnome/shell/ui/main.js'].uiGroup;
  const pill = ui.children.find((a) => a.style_class === 'slated-automation-pill');
  assert.ok(pill?.visible);
  assert.equal(pill.children[2].text, '✦ Esc to stop');
  const [started] = events('automation.started');
  assert.deepEqual([started.data.app, started.data.trigger], ['org.prismlauncher.PrismLauncher', 'hotkey hyper+f']);

  assert.ok(gnome.press(`${HYPER}Escape`));
  gnome.loop.advance(1000);
  assert.equal(clicks(), 3, 'stopped');
  assert.equal(pill.visible, false);
  assert.deepEqual(status().automation.running, []);
  assert.equal(events('automation.stopped_all')[0].data.reason, 'stop shortcut');
  const done = events('action.done').filter((e) => e.data.trigger === 'hotkey hyper+esc');
  assert.equal(done[0].data.source, 'Slated automation');
});

test('onlyInApps bindings are grabbed only while their app has focus', () => {
  start({bindings: [{keys: 'f', onlyInApps: ['org.prismlauncher.PrismLauncher.desktop'], action: autoClick}, {keys: 'g', onlyInApps: ['steam_app_1086940'], action: 'click right'}]});
  assert.ok(!gnome.accelerators().includes('f'));
  assert.equal(status().hotkeys.f, 'active');
  const launcher = gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.loop.run();
  assert.ok(gnome.accelerators().includes('f'), 'grabbed once the game has focus');
  assert.ok(!gnome.accelerators().includes('g'));
  gnome.addWindow({id: 2, app: {id: 'window:7', name: 'steam_app_1086940'}, wmClass: 'steam_app_1086940', frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.loop.run();
  assert.ok(gnome.accelerators().includes('g'), 'a Proton game, by WM_CLASS');
  assert.ok(!gnome.accelerators().includes('f'), 'f is free again for typing');
  gnome.focus(launcher);
  gnome.loop.run();
  assert.ok(gnome.accelerators().includes('f'));
  // A game without a desktop file is known by its WM_CLASS: the id its onlyInApps takes.
  assert.deepEqual(status().recentApps.map((a) => a.id), ['org.prismlauncher.PrismLauncher', 'steam_app_1086940']);
});

test('the overview counts as leaving the game: automations stop and its plain-key bindings are let go', () => {
  start({bindings: [{keys: 'f', onlyInApps: ['org.prismlauncher.PrismLauncher'], action: autoClick}]});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.loop.run();
  gnome.press('f');
  gnome.overview(true);
  gnome.loop.run();
  assert.equal(events('automation.stopped_all').at(-1).data.reason, 'left the app');
  assert.ok(!gnome.accelerators().includes('f'), 'typing f in the overview search reaches the search');
  gnome.overview(false);
  gnome.loop.run();
  assert.ok(gnome.accelerators().includes('f'), 'back in the game');
});

test('in the overview, shortcuts that would start an automation are ignored; stopping one still works', () => {
  start({bindings: [
    {keys: 'hyper+f', action: autoClick},
    {keys: 'hyper+w', action: 'hold key:w'},
    {keys: 'f6', action: 'sequence press key:w down | wait 2 | press key:w up | click left'},
    {keys: 'f7', action: 'sequence click left | wait 1 | click left'},
  ], automation: {stopOnAppSwitch: false}});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.overview(true);
  for (const accelerator of [`${HYPER}f`, `${HYPER}w`, 'F6', 'F7']) assert.ok(gnome.press(accelerator));
  gnome.loop.advance(3000);
  assert.deepEqual([clicks(), gnome.state.typed.length], [0, 0], 'nothing clicks or presses into the overview');
  assert.deepEqual(events('automation.start_ignored').map((e) => [e.data.trigger, e.data.reason]), [
    ['hotkey hyper+f', 'the overview is open'], ['hotkey hyper+w', 'the overview is open'],
    ['hotkey f6', 'the overview is open'], ['hotkey f7', 'the overview is open'],
  ]);
  assert.equal(events('action.done').length, 0);
  gnome.overview(false);

  // Started in the game, they go on in the overview here (stopOnAppSwitch is off): a second press
  // and the stop shortcut still stop them there.
  gnome.press(`${HYPER}f`);
  gnome.press(`${HYPER}w`);
  gnome.overview(true);
  gnome.press(`${HYPER}w`);
  assert.deepEqual(gnome.state.typed.at(-1), {keysym: 0x77, pressed: false}, 'W toggled off');
  gnome.press(`${HYPER}Escape`);
  const atStop = clicks();
  gnome.loop.advance(1000);
  assert.equal(clicks(), atStop);
  assert.equal(events('automation.stopped_all').at(-1).data.reason, 'stop shortcut');
  assert.equal(events('automation.start_ignored').length, 4);
  gnome.overview(false);
});

test('mouse button triggers fail with the keyd hint', () => {
  start({bindings: [{keys: 'mouse4', action: 'hold mouse:right'}, {keys: 'ctrl+mouse5', action: 'click'}]});
  const s = status();
  assert.equal(s.hotkeys.mouse4, `failed: ${MOUSE_BUTTON_REASON}`);
  assert.equal(s.hotkeys['ctrl+mouse5'], `failed: ${MOUSE_BUTTON_REASON}`);
  assert.match(events('hotkeys.registered')[0].data.failed.join(), /keyd/);
});

test('a while-held repeat stops when GNOME’s key repeat stops arriving', () => {
  start({bindings: [{keys: 'hyper+g', action: {...autoClick, interval: 0.05, mode: 'while-held'}}]});
  const grab = [...gnome.state.grabs.values()].find((g) => g.accelerator === `${HYPER}g`);
  assert.equal(grab.flags, 0, 'key repeat is delivered for it');
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press(`${HYPER}g`);
  gnome.loop.advance(500);
  for (let i = 0; i < 20; i++) {
    gnome.press(`${HYPER}g`); // the held key's repeats, every 30 ms
    gnome.loop.advance(30);
  }
  const whileHeld = clicks();
  assert.ok(whileHeld >= 21, `clicked while held (${whileHeld})`);
  gnome.loop.advance(150);
  const atRelease = clicks();
  gnome.loop.advance(1000);
  assert.equal(clicks(), atRelease, 'stopped about 100 ms after the repeats stopped');
  assert.equal(events('automation.stopped')[0].data.reason, 'released');
  assert.equal(events('action.done').length, 1, 'the repeats didn’t run the binding again');
});

test('without keyboard repeat, while-held works like a toggle and says so', () => {
  gnome.state.settings[`${KEYBOARD}:repeat`] = false;
  start({bindings: [{keys: 'hyper+g', action: {...autoClick, mode: 'while-held'}}, {keys: 'hyper+e', action: "repeat 0.05 while-held 'keystroke e'"}]});
  assert.equal(status().automation.whileHeld, 'toggle');
  const [note] = events('automation.while_held');
  assert.equal(note.level, 'notice');
  assert.deepEqual(note.data.toggles, ['hyper+g', 'hyper+e']);
  assert.match(note.data.reason, /keyboard repeat is off/);
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press(`${HYPER}g`);
  gnome.loop.advance(2000);
  assert.ok(clicks() > 10, 'keeps going without repeats');
  gnome.press(`${HYPER}g`);
  const count = clicks();
  gnome.loop.advance(1000);
  assert.equal(clicks(), count, 'a second press stops it');
});

test('a while-held repeat that types keys falls back to toggle, with key repeat on', () => {
  start({bindings: [{keys: 'hyper+e', action: "repeat 0.05 while-held 'keystroke e'"}]});
  assert.equal(status().automation.whileHeld, 'key-repeat');
  const [note] = events('automation.while_held');
  assert.deepEqual(note.data.toggles, ['hyper+e']);
  assert.match(note.data.reason, /keystrokes/);
  const grab = [...gnome.state.grabs.values()].find((g) => g.accelerator === `${HYPER}e`);
  assert.equal(grab.flags, 16, 'ignores key repeat like a toggle');
});

test('switching apps, reloading the config and disabling stop everything and release what’s held', () => {
  start({bindings: [{keys: 'hyper+f', action: autoClick}, {keys: 'hyper+w', action: 'hold key:w'}]});
  const launcher = gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press(`${HYPER}f`);
  gnome.press(`${HYPER}w`);
  gnome.loop.run();
  assert.deepEqual(gnome.state.typed.at(-1), {keysym: 0x77, pressed: true});
  gnome.addWindow({id: 2, app: {id: 'firefox', name: 'Firefox'}, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.loop.run();
  assert.equal(events('automation.stopped_all').at(-1).data.reason, 'switched to another app');
  assert.deepEqual(gnome.state.typed.at(-1), {keysym: 0x77, pressed: false}, 'W released');

  gnome.focus(launcher);
  gnome.press(`${HYPER}w`);
  writeConfig({bindings: [{keys: 'hyper+w', action: 'hold key:w'}], automation: {showIndicator: false}});
  gnome.fileChanged(configPath());
  gnome.loop.advance(300);
  assert.equal(events('automation.stopped_all').at(-1).data.reason, 'config reloaded');
  assert.deepEqual(gnome.state.typed.at(-1), {keysym: 0x77, pressed: false});

  gnome.press(`${HYPER}w`);
  gnome.loop.run();
  runtime.stop();
  runtime = null;
  assert.equal(events('automation.stopped_all').at(-1).data.reason, 'disabled');
  assert.deepEqual(gnome.state.typed.at(-1), {keysym: 0x77, pressed: false}, 'released on disable');
  assert.ok(gnome.state.disposed.includes('keyboard'), 'the virtual devices are gone');
  assert.equal(gnome.loop.pending, 0, 'no timers left');
  for (const [name, signals] of Object.entries(gnome.signals)) assert.equal(signals.size, 0, `no ${name} signal handlers left`);
});

// The Settings recipe "Macro: Walk, Then Click".
const walkThenClick = {op: 'sequence', operations: [
  {op: 'press', input: 'key:w', phase: 'down'}, {op: 'wait', seconds: 2}, {op: 'press', input: 'key:w', phase: 'up'},
  {op: 'click', button: 'left'},
]};
const firefox = {id: 'firefox', name: 'Firefox'};

test('switching apps or the overview mid-macro drops the rest of it: nothing clicks in the other app', () => {
  start({bindings: [{keys: 'f6', action: walkThenClick}]});
  const launcher = gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F6');
  gnome.loop.run();
  assert.deepEqual(gnome.state.typed, [{keysym: 0x77, pressed: true}], 'W is down for the wait');
  gnome.addWindow({id: 2, app: firefox, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.loop.run();
  assert.deepEqual(gnome.state.typed.at(-1), {keysym: 0x77, pressed: false}, 'W released by the switch');
  gnome.loop.advance(3000);
  assert.equal(clicks(), 0, 'the click after the wait never comes');
  assert.equal(gnome.state.typed.length, 2, 'and nothing else is pressed');

  gnome.focus(launcher);
  gnome.press('F6');
  gnome.overview(true);
  gnome.loop.advance(3000);
  assert.equal(clicks(), 0, 'no click into the overview either');
  assert.deepEqual(events('automation.stopped_all').map((e) => e.data.reason), ['switched to another app', 'left the app']);
  gnome.overview(false);
});

test('a macro that holds nothing during its wait still stops when you switch apps or open the overview', () => {
  start({bindings: [
    {keys: 'f6', action: {op: 'sequence', operations: [{op: 'click', button: 'left'}, {op: 'wait', seconds: 2}, {op: 'click', button: 'left'}]}},
    {keys: 'f7', action: {op: 'sequence', operations: [{op: 'wait', seconds: 2}, {op: 'hold', input: 'key:w'}]}},
  ]});
  const launcher = gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F6');
  gnome.loop.run();
  assert.equal(clicks(), 1);
  const other = gnome.addWindow({id: 2, app: firefox, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.loop.advance(3000);
  assert.equal(clicks(), 1, 'the click after the wait never lands in Firefox');

  gnome.focus(launcher);
  gnome.press('F6');
  gnome.overview(true);
  gnome.loop.advance(3000);
  assert.equal(clicks(), 2, 'nor in the overview');
  gnome.overview(false);

  gnome.focus(launcher);
  gnome.press('F7');
  gnome.focus(other);
  gnome.loop.advance(60_000);
  assert.deepEqual(gnome.state.typed, [], 'W is never held down in Firefox');
  assert.deepEqual(status().automation.running, []);
  assert.deepEqual(events('automation.stopped_all').map((e) => e.data.reason), ['switched to another app', 'left the app', 'switched to another app']);
  assert.equal(events('automation.started').length, 0, 'a waiting macro isn’t listed as running');
});

test('going to sleep stops automations and drops waiting macros, as on the Mac', () => {
  start({bindings: [{keys: 'hyper+w', action: 'hold key:w'}, {keys: 'f6', action: 'sequence wait 2 | click left'}]});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press(`${HYPER}w`);
  gnome.press('F6');
  assert.equal(gnome.signals.loginManager.count('prepare-for-sleep'), 1, 'logind’s PrepareForSleep is followed');
  gnome.prepareForSleep(true);
  assert.deepEqual(gnome.state.typed.at(-1), {keysym: 0x77, pressed: false}, 'W released before the suspend');
  assert.equal(events('automation.stopped_all')[0].data.reason, 'sleep');
  gnome.loop.advance(3000);
  assert.equal(clicks(), 0, 'the macro’s click never comes after waking up');
  gnome.prepareForSleep(false);
  assert.equal(events('automation.stopped_all').length, 1, 'waking up stops nothing');
  runtime.stop();
  runtime = null;
  assert.equal(gnome.signals.loginManager.size, 0, 'disconnected on disable');
});

test('the time limit drops a waiting macro as well', () => {
  start({bindings: [{keys: 'f6', action: 'sequence wait 60 | click left'}], automation: {maxRunMinutes: 0.5}});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F6');
  gnome.loop.advance(61_000);
  assert.equal(clicks(), 0);
  assert.equal(events('automation.stopped_all')[0].data.reason, 'time limit reached');
});

test('the time limit drops the rest of a macro too', () => {
  start({bindings: [{keys: 'f6', action: walkThenClick}], automation: {maxRunMinutes: 0.01}});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F6');
  gnome.loop.advance(3000);
  assert.equal(events('automation.stopped_all')[0].data.reason, 'time limit reached');
  assert.deepEqual(gnome.state.typed.at(-1), {keysym: 0x77, pressed: false});
  assert.equal(clicks(), 0);
});

test('keys an auto-repeat queued while you held a modifier are dropped when it stops, not typed into the next app', () => {
  start({bindings: [{keys: 'f7', action: {op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.05}}]});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F7');
  gnome.loop.advance(500);
  assert.ok(gnome.state.typed.length >= 20, 'E typed in the game');
  gnome.state.modifiers = 8; // Alt held for Alt+Tab: keystrokes wait for it to be let go
  gnome.loop.advance(1000);
  gnome.addWindow({id: 2, app: firefox, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.state.modifiers = 0; // Alt let go: GNOME's switcher has focused Firefox
  const atSwitch = gnome.state.typed.length;
  gnome.loop.advance(2000);
  assert.equal(gnome.state.typed.length, atSwitch, 'no E reaches Firefox');
  assert.equal(events('automation.stopped_all')[0].data.reason, 'switched to another app');
});

test('keys an auto-repeat types don’t wait for a modifier Slated itself holds (sprinting with the Hold Shift recipe)', () => {
  start({bindings: [
    {keys: 'f8', action: {op: 'hold', input: 'key:shift'}},
    {keys: 'f7', action: {op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.05}},
  ]});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F8');
  gnome.state.modifiers = 1; // what GNOME reports while Slated's virtual keyboard holds Shift
  const es = () => gnome.state.typed.filter((t) => t.keysym === 0x65).length / 2;
  gnome.press('F7');
  gnome.loop.advance(1000);
  assert.ok(es() >= 20, `E is pressed at the repeat rate while sprinting (${es()})`);
  gnome.press('F7');
  const atOff = es();
  gnome.loop.advance(2000);
  assert.equal(es(), atOff, 'nothing queued up to come out after spamming stops');

  gnome.state.modifiers = 9; // you hold Alt yourself as well: that one is still waited for
  gnome.press('F7');
  assert.equal(es(), atOff);
  gnome.press('F7');
});

const typedKeys = (keysym) => gnome.state.typed.filter((t) => t.keysym === keysym && t.pressed).length;
const HYPER_HELD = 1 | 4 | 8 | 64; // Shift, Ctrl, Alt and Super, as keyd's Hyper sets them

test('an auto-repeat’s keys are skipped while you hold a modifier, never typed later', () => {
  start({bindings: [
    {keys: 'f7', action: {op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.05, times: 20}},
    {keys: 'hyper+e', action: {op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.05}},
  ]});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F7');
  gnome.loop.advance(200);
  const before = typedKeys(0x65);
  assert.equal(before, 5);
  gnome.state.modifiers = 8; // Alt held: the repeat finishes meanwhile
  gnome.loop.advance(1500);
  assert.equal(events('automation.stopped')[0].data.reason, 'finished');
  gnome.addWindow({id: 2, app: firefox, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.state.modifiers = 0;
  gnome.loop.advance(2000);
  assert.equal(typedKeys(0x65), before, 'no E reaches Firefox after the repeat finished');

  gnome.state.modifiers = HYPER_HELD; // ✦E pressed and held, then pressed again to toggle it off
  gnome.press(`${HYPER}e`);
  gnome.loop.advance(400);
  gnome.press(`${HYPER}e`);
  gnome.state.modifiers = 0;
  gnome.loop.advance(2000);
  assert.equal(events('automation.stopped')[1].data.reason, 'toggled off');
  assert.equal(typedKeys(0x65), before, 'and none after it was toggled off');
});

test('an auto-repeat sends nothing while Alt is held for Alt+Tab, however long (Q would quit apps in the switcher)', () => {
  start({bindings: [{keys: 'f8', action: {op: 'repeat', action: {op: 'keystroke', keys: 'q'}, interval: 0.05}}]});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F8');
  gnome.state.modifiers = 8;
  const atAlt = typedKeys(0x71);
  gnome.loop.advance(2500);
  assert.equal(typedKeys(0x71), atAlt);
  gnome.state.modifiers = 0;
  gnome.loop.advance(200);
  assert.ok(typedKeys(0x71) > atAlt, 'Q goes on once Alt is let go');
  gnome.press('F8');
});

test('a stop leaves your own shortcut’s keys alone: they’re typed once you let go of Hyper', () => {
  start({bindings: [{keys: 'hyper+f', action: autoClick}, {keys: 'hyper+c', action: {op: 'keystroke', keys: 'ctrl+c'}}]});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press(`${HYPER}f`);
  gnome.state.modifiers = HYPER_HELD;
  gnome.press(`${HYPER}c`); // waits for Hyper to be let go
  gnome.press(`${HYPER}Escape`);
  assert.equal(events('automation.stopped_all')[0].data.reason, 'stop shortcut');
  gnome.state.modifiers = 0;
  gnome.loop.advance(100);
  assert.deepEqual(gnome.state.typed, [{code: 29, pressed: true}, {keysym: 0x63, pressed: true}, {keysym: 0x63, pressed: false}, {code: 29, pressed: false}]);
});

test('a stop ends text an automation is still typing', () => {
  const long = {op: 'repeat', action: {op: 'insert-text', text: 'x'.repeat(400), method: 'type'}, interval: 10};
  start({bindings: [{keys: 'f9', action: long}]});
  const launcher = gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F9');
  gnome.loop.advance(50);
  gnome.press(`${HYPER}Escape`);
  const atStop = gnome.state.typed.length;
  assert.ok(atStop > 0 && atStop < 800);
  gnome.loop.advance(1000);
  assert.equal(gnome.state.typed.length, atStop, 'the stop shortcut ends it');

  gnome.focus(launcher);
  gnome.press('F9');
  gnome.loop.advance(50);
  gnome.addWindow({id: 2, app: firefox, frame: {x: 0, y: 0, width: 800, height: 600}});
  const atSwitch = gnome.state.typed.length;
  gnome.loop.advance(1000);
  assert.equal(gnome.state.typed.length, atSwitch, 'and so does switching apps: nothing more goes to Firefox');
});

test('a right Alt Slated holds doesn’t hide the Alt you hold (where right Alt is AltGr, Mutter drops Slated’s press)', () => {
  start({bindings: [{keys: 'f8', action: 'hold key:rightAlt'}, {keys: 'f7', action: {op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.05}}]});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press('F8');
  gnome.state.modifiers = 8; // only your own Alt: Mutter dropped Slated's Alt_R
  gnome.press('F7');
  gnome.loop.advance(1000);
  assert.equal(typedKeys(0x65), 0, 'no E goes out as Alt+E');
  gnome.press('F7');
  gnome.press('F8');
});

test('the time limit and stopOnAppSwitch come from config.json', () => {
  start({bindings: [{keys: 'hyper+f', action: autoClick}], automation: {maxRunMinutes: 0.01, stopOnAppSwitch: false, stopShortcut: null}});
  assert.ok(!gnome.accelerators().includes(`${HYPER}Escape`), 'stopShortcut null turns it off');
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.press(`${HYPER}f`);
  gnome.addWindow({id: 2, app: {id: 'firefox', name: 'Firefox'}, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.loop.advance(300);
  assert.ok(clicks() > 3, 'still clicking in another app');
  gnome.loop.advance(600);
  assert.equal(events('automation.stopped_all').at(-1).data.reason, 'time limit reached');
  assert.equal(status().automation.stopShortcut, null);
});

test('copies land in clipboard history, saved privately; the shortcut opens the switcher', () => {
  start({clipboard: {shortcut: 'ctrl+alt+v', excludedApps: ['org.keepassxc.KeePassXC']}});
  assert.ok(gnome.accelerators().includes('<Control><Alt>v'));
  gnome.addWindow({id: 1, app: {id: 'org.gnome.TextEditor', name: 'Text Editor'}, frame: {x: 0, y: 0, width: 800, height: 600}});
  gnome.copy('copied text');
  gnome.copy('a secret', ['text/plain', 'x-kde-passwordManagerHint']);
  assert.deepEqual(status().clipboard, {enabled: true, items: 1});
  gnome.loop.advance(1000);
  assert.equal(statSync(statePath('clipboard.json')).mode & 0o777, 0o600);
  assert.equal(JSON.parse(readFileSync(statePath('clipboard.json'), 'utf8')).items[0].text, 'copied text');
  assert.ok(!readFileSync(statePath('slated.log'), 'utf8').includes('copied text'), 'the log never has clipboard text');

  gnome.press('<Control><Alt>v');
  gnome.loop.run();
  assert.equal(gnome.state.modal.length, 1, 'the switcher is open');
  assert.equal(events('clipboard.switcher_opened')[0].data.items, 1);
});

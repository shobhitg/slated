// The runtime's wiring against a simulated GNOME Shell (fake-gnome.mjs): config → shortcuts, Hyper key,
// status.json and the event log; a hotkey moving a window; reacting to config edits; first runs; and
// disable() undoing everything.

import assert from 'node:assert/strict';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {after, beforeEach, test} from 'node:test';
import {fileURLToPath} from 'node:url';

import {fakeCore} from './fake-core.mjs';
import {createFakeGnome} from './fake-gnome.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {SlatedRuntime} = await import('../../gnome-extension/lib/platform/runtime.js');

// The log mirrors errors (and everything with SLATED_DEBUG=1) to the journal via console; keep test
// output readable. The JSON log file is what these tests check.
const journal = [];
console.error = (...args) => journal.push(args.join(' '));
console.log = (...args) => journal.push(args.join(' '));

const repo = join(dirname(fileURLToPath(import.meta.url)), '../../..');
const homes = [];
let home;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'slated-runtime-'));
  homes.push(home);
  Object.assign(gnome.state, {
    home,
    env: {},
    focused: null,
    windows: [],
    apps: [],
    settings: {'org.gnome.desktop.input-sources:xkb-options': ['compose:ralt', 'caps:escape']},
    taken: new Set(['<Super>a']),
    grabs: new Map(),
    allowed: {},
    locked: false,
  });
});

after(() => {
  for (const dir of homes) rmSync(dir, {recursive: true, force: true});
});

const configPath = () => join(home, '.config/slated/config.json');
const statePath = (name) => join(home, '.local/state/slated', name);

function writeConfig(config) {
  mkdirSync(dirname(configPath()), {recursive: true});
  writeFileSync(configPath(), JSON.stringify(config, null, 2));
}

function logEvents() {
  if (!existsSync(statePath('slated.log'))) return [];
  return readFileSync(statePath('slated.log'), 'utf8')
    .trim()
    .split('\n')
    .map((line) => JSON.parse(line));
}

const events = (name) => logEvents().filter((e) => e.event === name);
const status = () => JSON.parse(readFileSync(statePath('status.json'), 'utf8'));

function startRuntime() {
  const runtime = new SlatedRuntime({path: join(home, 'extension'), metadata: {'version-name': '0.1.0'}, uuid: 'slated@shobhit-aida.github.io', core: fakeCore});
  runtime.start();
  gnome.loop.run();
  return runtime;
}

const leftHalf = {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY'};
const config = {
  keyboard: {capsLock: 'hyper'},
  general: {loadSlateConfigs: false},
  bindings: [
    {name: 'Left half', keys: 'hyper+a', action: leftHalf},
    {name: 'Right half', keys: 'hyper+d', enabled: false, action: {op: 'push', direction: 'right'}},
    {name: 'GNOME owns this', keys: 'cmd+a', action: {op: 'push', direction: 'left'}},
    {name: 'Duplicate', keys: 'hyper+a', action: {op: 'push', direction: 'up'}},
  ],
};

test('start registers config shortcuts in xkb Hyper mode and publishes status and log events', () => {
  writeConfig(config);
  const runtime = startRuntime();

  assert.deepEqual(gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'], ['compose:ralt', 'caps:hyper']);
  assert.deepEqual(gnome.accelerators(), ['<Hyper>a']);
  const [action] = gnome.state.grabs.keys();
  assert.equal(gnome.state.allowed[`external-grab-${action}`], 3, 'allowed in NORMAL | OVERVIEW');
  assert.equal(gnome.state.grabs.get(action).flags, 16, 'non-repeating bindings ignore key repeat');

  const s = status();
  assert.equal(s.running, true);
  assert.equal(s.version, '0.1.0');
  assert.match(s.session, /^[0-9a-f]{8}$/);
  assert.deepEqual(s.hyper, {wanted: true, mode: 'xkb', active: true});
  assert.deepEqual(s.hotkeys, {
    'cmd+a': 'failed: GNOME refused <Super>a: another app or extension may already use it',
    'hyper+a': 'duplicate',
    'hyper+d': 'disabled',
  });
  assert.deepEqual(s.hotstrings, {engine: 'none', espansoInstalled: false, matchFile: null, count: 0});
  assert.equal(s.lastError, null);

  const [start] = events('app.start');
  assert.equal(start.level, 'notice');
  assert.deepEqual(
    {mode: start.data.mode, gnome: start.data.gnome, version: start.data.version, commit: start.data.commit},
    {mode: 'gnome-extension', gnome: '47.1', version: '0.1.0', commit: 'unknown'},
  );
  assert.equal(start.session, s.session);
  assert.equal(events('config.loaded')[0].data.bindings, 4);
  assert.equal(events('keyboard.state')[0].data.mode, 'xkb');
  assert.deepEqual(events('keyboard.xkb_option')[0].data, {added: 'caps:hyper', setAside: ['caps:escape']});
  assert.equal(events('hotkeys.registered')[0].level, 'error');
  runtime.stop();
});

test('a hotkey moves the focused window and logs one action event', () => {
  writeConfig(config);
  const runtime = startRuntime();
  const window = gnome.addWindow({id: 7, app: {id: 'firefox', name: 'Firefox'}, title: 'Private title', frame: {x: 100, y: 100, width: 800, height: 600}});
  assert.ok(gnome.press('<Hyper>a'));
  assert.deepEqual(window.frame, {x: 0, y: 32, width: 960, height: 1048});
  gnome.loop.advance(200); // the settle check
  assert.equal(window.moves.length, 1, 'no retry needed');

  const [done] = events('action.done');
  assert.equal(done.data.trigger, 'hotkey hyper+a');
  assert.equal(done.data.label, 'Left half');
  assert.equal(done.data.app, 'firefox');
  assert.equal(done.data.source, 'Slated');
  assert.equal(status().lastAction, 'Left half · Firefox');
  assert.ok(!readFileSync(statePath('slated.log'), 'utf8').includes('Private title'), 'titles never reach the log');
  runtime.stop();
});

test('without a focused window the action fails with a reason', () => {
  writeConfig(config);
  const runtime = startRuntime();
  gnome.press('<Hyper>a');
  gnome.loop.run();
  const [failed] = events('action.failed');
  assert.equal(failed.level, 'error');
  assert.equal(failed.data.error, 'No focused window to move');
  assert.equal(status().lastError, 'No focused window to move');
  runtime.stop();
});

test('editing config.json re-registers shortcuts and turns Hyper off', () => {
  writeConfig(config);
  const runtime = startRuntime();
  writeConfig({keyboard: {capsLock: 'off'}, general: {loadSlateConfigs: false}, bindings: [{keys: 'ctrl+alt+x', action: leftHalf}]});
  gnome.fileChanged(configPath());
  gnome.loop.advance(300);
  assert.deepEqual(gnome.accelerators(), ['<Control><Alt>x']);
  assert.deepEqual(gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'], ['compose:ralt', 'caps:escape']);
  assert.equal(events('config.changed_on_disk').length, 1);
  assert.deepEqual(status().hotkeys, {'ctrl+alt+x': 'active'});
  assert.deepEqual(status().hyper, {wanted: false, mode: 'off', active: false});
  runtime.stop();
});

test('a broken config.json is reported and the last good configuration stays', () => {
  writeConfig(config);
  const runtime = startRuntime();
  writeFileSync(configPath(), '{"bindings": [');
  gnome.fileChanged(configPath());
  gnome.loop.advance(300);
  assert.deepEqual(gnome.accelerators(), ['<Hyper>a']);
  assert.match(status().lastError, /^Couldn't read .*config\.json/);
  assert.equal(events('config.error')[0].level, 'error');
  runtime.stop();
});

test('stop() undoes everything: shortcuts, keyboard options, signals and timers', () => {
  writeConfig(config);
  const runtime = startRuntime();
  gnome.addWindow({id: 1, app: {id: 'firefox', name: 'Firefox'}, frame: {x: 0, y: 0, width: 400, height: 300}});
  gnome.press('<Hyper>a'); // leaves a settle timer pending
  runtime.stop();

  assert.deepEqual(gnome.accelerators(), []);
  assert.ok(Object.values(gnome.state.allowed).every((modes) => modes === 0), 'every keybinding disallowed again');
  assert.deepEqual(gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'], ['compose:ralt', 'caps:escape']);
  assert.equal(existsSync(statePath('hyper.json')), false);
  assert.equal(gnome.loop.pending, 0, 'no main loop sources left');
  assert.equal(gnome.signals.display.size, 0, 'no display signal handlers left');
  assert.equal(gnome.signals.layout.size, 0, 'no layout manager handlers left');
  assert.equal([...gnome.state.monitors.values()].reduce((n, set) => n + set.size, 0), 0, 'no file monitors left');
  assert.equal(status().running, false);
  const [quit] = events('app.quit');
  assert.equal(quit.data.reason, 'disabled');
});

test('first run with ~/.slate.js starts empty and loads the Slate file', () => {
  writeFileSync(join(home, '.slate.js'), readFileSync(join(repo, 'Tests/Smoke/fixtures/slate.js')));
  const runtime = startRuntime();
  assert.equal(events('config.created')[0].data.from, 'empty (Slate config is the default)');
  const created = JSON.parse(readFileSync(configPath(), 'utf8'));
  assert.deepEqual(created.bindings, []);
  const [loaded] = events('slate.loaded');
  assert.deepEqual({path: loaded.data.path, kind: loaded.data.kind, bindings: loaded.data.bindings}, {path: '~/.slate.js', kind: 'javascript', bindings: 4});
  assert.deepEqual(status().hotkeys, {'hyper+a': 'active', 'hyper+f': 'active', 'hyper+tab': 'active', 'hyper+w': 'active'});
  assert.deepEqual(status().sources[0], {path: '~/.slate.js', kind: 'javascript', exists: true, loaded: true, bindings: 4, diagnostics: []});

  const window = gnome.addWindow({id: 3, app: {id: 'org.gnome.Nautilus', name: 'Files'}, frame: {x: 300, y: 300, width: 500, height: 400}});
  // Hyper is off in an empty config, so Slate's ctrl,shift,alt,cmd bindings use all four modifiers.
  assert.ok(gnome.press('<Control><Alt><Shift><Super>a'));
  assert.deepEqual(window.frame, {x: 0, y: 32, width: 960, height: 1048});
  const [binding] = events('script.binding');
  assert.equal(binding.data.trigger, 'hotkey hyper+a');
  assert.equal(binding.data.source, '~/.slate.js');
  const [done] = events('action.done');
  assert.equal(done.data.trigger, 'script');
  assert.equal(done.data.source, '~/.slate.js');
  runtime.stop();
});

test('first run without a Slate config writes the starter bindings', () => {
  const runtime = startRuntime();
  assert.equal(events('config.created')[0].data.from, 'starter bindings');
  assert.equal(JSON.parse(readFileSync(configPath(), 'utf8')).bindings.length, 1);
  assert.deepEqual(status().hotkeys, {'hyper+a': 'active'});
  runtime.stop();
});

test('a Slate file edit reloads its bindings', () => {
  writeFileSync(join(home, '.slate.js'), 'slate.bind("a:ctrl", "push left");');
  writeConfig({general: {loadSlateConfigs: true}});
  const runtime = startRuntime();
  assert.deepEqual(gnome.accelerators(), ['<Control>a']);
  writeFileSync(join(home, '.slate.js'), 'slate.bind("b:ctrl", "push right");');
  gnome.fileChanged(join(home, '.slate.js'));
  gnome.loop.advance(400);
  assert.deepEqual(gnome.accelerators(), ['<Control>b']);
  runtime.stop();
});

test('hotstrings are written for espanso and kept only while the screen is locked', () => {
  mkdirSync(join(home, '.config/espanso'), {recursive: true});
  writeConfig({general: {loadSlateConfigs: false}, hotstrings: [{trigger: ';sig', replacement: 'secret signature text'}]});
  const matchFile = join(home, '.config/espanso/match/slated.yml');

  let runtime = startRuntime();
  assert.match(readFileSync(matchFile, 'utf8'), /trigger: ";sig"/);
  assert.deepEqual(status().hotstrings, {engine: 'espanso', espansoInstalled: true, matchFile, count: 1});
  assert.ok(!readFileSync(statePath('slated.log'), 'utf8').includes('secret signature'), 'replacements never reach the log');
  gnome.state.locked = true;
  runtime.stop();
  assert.ok(existsSync(matchFile), 'kept while locked');

  gnome.state.locked = false;
  runtime = startRuntime();
  runtime.stop();
  assert.ok(!existsSync(matchFile), 'removed when Slated is turned off');
});

test('with SLATED_DEBUG=1 the debug interface runs actions and reports windows without titles', () => {
  gnome.state.env.SLATED_DEBUG = '1';
  writeConfig(config);
  const runtime = startRuntime();
  assert.equal(gnome.state.dbus.exported, true);
  assert.equal(gnome.state.dbus.path, '/io/github/shobhit_aida/Slated');
  const dbus = gnome.state.dbus.implementation;
  gnome.addWindow({id: 9, app: {id: 'firefox', name: 'Firefox'}, title: 'Secret', frame: {x: 10, y: 10, width: 300, height: 200}});
  assert.deepEqual(dbus.RunAction('"push right bar-resize:screenSizeX/3"'), [true, '']);
  assert.deepEqual(JSON.parse(dbus.GetFocusedWindow()).frame, {x: 1280, y: 32, width: 640, height: 1048});
  assert.deepEqual(dbus.RunAction('{"op":"teleport"}'), [false, 'Unknown operation "teleport"']);
  assert.ok(!dbus.ListWindows().includes('Secret'));
  assert.equal(dbus.TriggerBinding('hyper+a'), true);
  assert.deepEqual(JSON.parse(dbus.GetFocusedWindow()).frame, {x: 0, y: 32, width: 960, height: 1048});
  assert.equal(JSON.parse(dbus.GetScreens()).length, 2);
  assert.equal(JSON.parse(dbus.GetStatus()).running, true);
  runtime.stop();
  assert.equal(gnome.state.dbus.exported, false);
});

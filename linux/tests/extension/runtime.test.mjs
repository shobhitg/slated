// The runtime's wiring against a simulated GNOME Shell (fake-gnome.mjs): config → shortcuts, Hyper key,
// status.json and the event log; a hotkey moving a window; reacting to edits of config.json and
// settings.json; first runs and the move from a version 1 config.json; and disable() undoing everything.

import assert from 'node:assert/strict';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {after, afterEach, beforeEach, test} from 'node:test';
import {fileURLToPath} from 'node:url';

import {configPathIn, settingsPathIn, writeConfigFiles} from './config-files.mjs';
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
    env: {SLATED_KEYD_CONF: join(home, 'etc/keyd/slated.conf')}, // never this computer's keyd
    programs: {},
    subprocesses: undefined,
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

afterEach(() => {
  assert.deepEqual(events('runtime.error'), [], 'no part of the runtime failed');
});

const configPath = () => configPathIn(home);
const settingsPath = () => settingsPathIn(home);
const statePath = (name) => join(home, '.local/state/slated', name);

/** config.json and settings.json, version 2, from one object. */
function writeConfig(config) {
  writeConfigFiles(home, config);
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
  const runtime = new SlatedRuntime({path: join(home, 'extension'), metadata: {'version-name': '0.1.0'}, uuid: 'slated@shobhitg.github.io', core: fakeCore});
  runtime.start();
  gnome.loop.run();
  return runtime;
}

const leftHalf = {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY'};
// Without the built-in clipboard and stop shortcuts, so only these bindings are registered.
const quiet = {clipboard: {shortcut: null}, automation: {stopShortcut: null}};
const config = {
  ...quiet,
  keyboard: {capsLock: 'hyper'},
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
  writeConfig({...quiet, keyboard: {capsLock: 'off'}, bindings: [{keys: 'ctrl+alt+x', action: leftHalf}]});
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
  assert.match(status().lastError, /^Couldn't read config\.json/);
  assert.equal(events('config.error')[0].level, 'error');
  runtime.stop();
});

test('a hand edit to settings.json is picked up; a broken one is reported by name', () => {
  writeConfig(config);
  const runtime = startRuntime();
  const settingsJSON = JSON.parse(readFileSync(settingsPath(), 'utf8'));
  writeFileSync(settingsPath(), JSON.stringify({...settingsJSON, automation: {stopShortcut: 'ctrl+alt+esc'}}));
  gnome.fileChanged(settingsPath());
  gnome.loop.advance(300);
  assert.deepEqual(gnome.accelerators(), ['<Control><Alt>Escape', '<Hyper>a']);
  writeFileSync(settingsPath(), '{"island": {"enabled": "yes"}}');
  gnome.fileChanged(settingsPath());
  gnome.loop.advance(300);
  assert.deepEqual(gnome.accelerators(), ['<Control><Alt>Escape', '<Hyper>a'], 'the last good configuration stays');
  assert.match(status().lastError, /^Couldn't read settings\.json: island\.enabled: /);
  assert.equal(readFileSync(settingsPath(), 'utf8'), '{"island": {"enabled": "yes"}}', 'and nothing is overwritten');
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
  assert.deepEqual(status().hyper, {wanted: true, mode: 'off', active: false}, 'caps:hyper is gone, and status.json says so');
  const [quit] = events('app.quit');
  assert.equal(quit.data.reason, 'disabled');
  assert.equal(quit.data.hyperRestored, true);
});

test('keyd is the Hyper key only while it runs and a keyd config maps Caps Lock, and Slated follows it live', () => {
  Object.assign(gnome.state, {programs: {systemctl: '/usr/bin/systemctl'}, subprocesses: []});
  const etc = join(home, 'etc/keyd');
  mkdirSync(etc, {recursive: true});
  writeFileSync(join(etc, 'mouse.conf'), '[ids]\nm:046d:c52b\n\n[main]\nmouse1 = f13\n'); // keyd only for the side buttons
  writeConfig(config);
  const runtime = startRuntime();
  const xkb = () => gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'];
  assert.deepEqual(gnome.state.subprocesses, [], 'no keyd config maps Caps Lock: systemd isn’t even asked');
  assert.deepEqual([gnome.accelerators(), xkb(), status().hyper], [['<Hyper>a'], ['compose:ralt', 'caps:hyper'], {wanted: true, mode: 'xkb', active: true}]);

  writeFileSync(join(etc, 'mouse.conf'), '[ids]\n*\n\n[main]\ncapslock = layer(hyper)\n'); // you map Caps Lock in keyd
  gnome.fileChanged(etc);
  gnome.state.subprocesses[0].exit(true); // keyd.service is active
  gnome.loop.run();
  assert.deepEqual(gnome.accelerators(), ['<Control><Alt><Shift><Super>a']);
  assert.deepEqual(xkb(), ['compose:ralt', 'caps:escape'], 'caps:hyper taken out, caps:escape back');
  assert.deepEqual(status().hyper, {wanted: true, mode: 'keyd', active: true});

  gnome.systemSignal('org.freedesktop.DBus.Properties.PropertiesChanged', ['org.freedesktop.systemd1.Unit', {ActiveState: 'inactive'}, []]); // keyd stops
  gnome.state.subprocesses[1].exit(false);
  gnome.loop.run();
  assert.deepEqual([gnome.accelerators(), xkb(), status().hyper], [['<Hyper>a'], ['compose:ralt', 'caps:hyper'], {wanted: true, mode: 'xkb', active: true}]);
  runtime.stop();
});

test('a caps:hyper you set yourself stays after disable, and the last status.json says Caps Lock is still Hyper', () => {
  gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'] = ['compose:ralt', 'caps:hyper']; // GNOME Tweaks
  writeConfig(config);
  const runtime = startRuntime();
  runtime.stop();
  assert.deepEqual(gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'], ['compose:ralt', 'caps:hyper'], 'not Slated’s to take out');
  assert.deepEqual(status().hyper, {wanted: true, mode: 'xkb', active: true});
  assert.equal(events('app.quit')[0].data.hyperRestored, false);
});

test('first run with ~/.slate.js imports it into config.json, and Slate files are never read again', () => {
  writeFileSync(join(home, '.slate.js'), readFileSync(join(repo, 'Tests/Smoke/fixtures/slate.js')));
  const runtime = startRuntime();
  const [created] = events('config.created');
  assert.deepEqual([created.data.by, created.data.from, created.data.slate], ['gnome-extension', 'Slate config', {files: 1, imported: 4, skipped: 0, unconvertible: 0}]);
  const written = JSON.parse(readFileSync(configPath(), 'utf8'));
  assert.deepEqual(written.bindings.map((b) => b.keys).sort(), ['hyper+a', 'hyper+f', 'hyper+tab', 'hyper+w']);
  assert.equal(written.version, 2);
  assert.ok(existsSync(settingsPath()), 'settings.json written too');
  const hotkeys = status().hotkeys;
  for (const key of ['hyper+a', 'hyper+f', 'hyper+tab', 'hyper+w']) assert.equal(hotkeys[key], 'active', key);
  const window = gnome.addWindow({id: 3, app: {id: 'org.gnome.Nautilus', name: 'Files'}, frame: {x: 300, y: 300, width: 500, height: 400}});
  // The import keeps Hyper off (a new config's default), so the ✦ bindings use all four modifiers.
  assert.ok(gnome.press('<Control><Alt><Shift><Super>a'));
  assert.deepEqual(window.frame, {x: 0, y: 32, width: 960, height: 1048});
  assert.equal(events('action.done')[0].data.source, 'Slated', 'a native shortcut now, not JavaScript');
  // Editing ~/.slate.js changes nothing: Slated doesn't read it any more.
  const before = gnome.accelerators();
  writeFileSync(join(home, '.slate.js'), 'slate.bind("b:ctrl", "push right");');
  gnome.fileChanged(join(home, '.slate.js'));
  gnome.loop.advance(400);
  assert.deepEqual(gnome.accelerators(), before);
  assert.equal(JSON.parse(readFileSync(statePath('config-migration.json'), 'utf8')).kind, 'first-run');
  runtime.stop();
});

test('a version 1 config.json is migrated at start: a backup, settings.json, the Slate file imported once', () => {
  writeFileSync(join(home, '.slate.js'), readFileSync(join(repo, 'Tests/Smoke/fixtures/slate.js')));
  // Version 1, with hyper+a and hyper+w imported while the file kept loading: deleted (hyper+a) and
  // moved to ctrl+alt+x (hyper+w) in the settings window since.
  const v1 = JSON.stringify({
    general: {loadSlateConfigs: true, importedSlateShortcuts: ['hyper+a', 'hyper+w']}, settings: {undoMaxStackSize: 3},
    ...quiet, island: {enabled: false}, bindings: [{keys: 'ctrl+alt+x', action: leftHalf}],
  });
  mkdirSync(dirname(configPath()), {recursive: true});
  writeFileSync(configPath(), v1);
  let runtime = startRuntime();
  assert.deepEqual(status().hotkeys, {'ctrl+alt+x': 'active', 'hyper+f': 'active', 'hyper+tab': 'active'});
  assert.equal(readFileSync(join(home, '.config/slated/config.v1.json'), 'utf8'), v1, 'config.v1.json keeps the file as it was');
  const settings = JSON.parse(readFileSync(settingsPath(), 'utf8'));
  assert.deepEqual([settings.windows, settings.island.enabled, settings.automation.stopShortcut], [{undoMaxStackSize: 3}, false, null]);
  const config = JSON.parse(readFileSync(configPath(), 'utf8'));
  assert.deepEqual([config.version, 'general' in config, 'settings' in config], [2, false, false]);
  const [migrated] = events('config.migrated');
  assert.deepEqual(migrated.data, {by: 'gnome-extension', from: 1, to: 2, settingsMoved: true, settingsKept: false, backup: true,
    slate: {files: 1, imported: 2, skipped: 2, unconvertible: 0}});
  assert.equal(migrated.level, 'notice');
  const record = JSON.parse(readFileSync(statePath('config-migration.json'), 'utf8'));
  assert.deepEqual([record.kind, record.by, record.noticeDismissed], ['migration', 'gnome-extension', false], 'for the settings window to tell you');
  runtime.stop();
  // Idempotent: the next start reads version 2.
  runtime = startRuntime();
  assert.equal(events('config.migrated').length, 1);
  assert.deepEqual(status().hotkeys, {'ctrl+alt+x': 'active', 'hyper+f': 'active', 'hyper+tab': 'active'});
  runtime.stop();
});

test('a broken version 1 config.json is reported and not migrated', () => {
  mkdirSync(dirname(configPath()), {recursive: true});
  writeFileSync(configPath(), '{"general": {"loadSlateConfigs": false}, "bindings": [');
  const runtime = startRuntime();
  assert.match(status().lastError, /^Couldn't read config\.json/);
  assert.ok(!existsSync(join(home, '.config/slated/config.v1.json')) && !existsSync(settingsPath()), 'nothing written');
  runtime.stop();
});

test("display defaults apply config.json's layout when the displays match", () => {
  const counts = [1, 2, 3, 4, 5, 6];
  writeConfig({
    windows: {checkDefaultsOnLoad: true},
    layouts: [{name: 'native'}],
    defaults: counts.map((count) => ({target: 'native', count})),
  });
  const runtime = startRuntime();
  assert.deepEqual(events('action.done').map((e) => e.data.action), ['layout native']);
  runtime.stop();
});

test('first run without a Slate config writes the starter bindings in both files', () => {
  const runtime = startRuntime();
  assert.equal(events('config.created')[0].data.from, 'starter bindings');
  assert.equal(JSON.parse(readFileSync(configPath(), 'utf8')).bindings.length, 21);
  assert.equal(JSON.parse(readFileSync(settingsPath(), 'utf8')).version, 2);
  assert.equal(status().hotkeys['hyper+a'], 'active');
  runtime.stop();
});

test('hotstrings are written for espanso and kept only while the screen is locked', () => {
  mkdirSync(join(home, '.config/espanso'), {recursive: true});
  writeConfig({hotstrings: [{trigger: ';sig', replacement: 'secret signature text'}]});
  const matchFile = join(home, '.config/espanso/match/slated.yml');

  let runtime = startRuntime();
  assert.match(readFileSync(matchFile, 'utf8'), /trigger: ";sig"/);
  assert.deepEqual(status().hotstrings, {engine: 'espanso', espansoInstalled: true, matchFile, count: 1});
  assert.ok(!readFileSync(statePath('slated.log'), 'utf8').includes('secret signature'), 'replacements never reach the log');
  gnome.state.locked = true;
  runtime.stop();
  assert.ok(existsSync(matchFile), 'kept while locked');
  assert.equal(status().hotstrings.count, 1, 'espanso still expands it');

  gnome.state.locked = false;
  runtime = startRuntime();
  runtime.stop();
  assert.ok(!existsSync(matchFile), 'removed when Slated is turned off');
  assert.equal(status().hotstrings.count, 0, 'and status.json says none are left');
});

test('with SLATED_DEBUG=1 the debug interface runs actions and reports windows without titles', () => {
  gnome.state.env.SLATED_DEBUG = '1';
  writeConfig(config);
  const runtime = startRuntime();
  assert.equal(gnome.state.dbus.exported, true);
  assert.equal(gnome.state.dbus.path, '/io/github/shobhitg/Slated');
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

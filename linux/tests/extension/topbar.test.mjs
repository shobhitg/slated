// Slated's icon in the top bar and its menu (statusIcon.js), Pause Slated, and opening the settings
// window: from the icon, from the menu, and on Get Started a few seconds after the first login. Against
// the simulated GNOME Shell (fake-gnome.mjs).

import assert from 'node:assert/strict';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, afterEach, beforeEach, test} from 'node:test';

import {configPathIn, settingsPathIn, writeConfigFiles} from './config-files.mjs';
import {fakeCore} from './fake-core.mjs';
import {createFakeGnome} from './fake-gnome.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {SlatedRuntime, GET_STARTED_DELAY_MS} = await import('../../gnome-extension/lib/platform/runtime.js');
const {MENU_ITEMS, statusWarnings, iconName} = await import('../../gnome-extension/lib/platform/statusIcon.js');
const {findSettingsWindow, setupFinished, shouldOfferGetStarted} = await import('../../gnome-extension/lib/platform/settingsWindow.js');

console.error = () => {};
console.log = () => {};

const UUID = 'slated@shobhitg.github.io';
const homes = [];
let home;
let opened;
let runtimes;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'slated-topbar-'));
  homes.push(home);
  opened = 0;
  runtimes = [];
  Object.assign(gnome.state, {
    home,
    env: {SLATED_KEYD_CONF: join(home, 'etc/keyd/slated.conf')},
    programs: {},
    subprocesses: undefined,
    focused: null,
    windows: [],
    apps: [],
    settings: {'org.gnome.desktop.input-sources:xkb-options': ['compose:ralt']},
    taken: new Set(['<Super>a']),
    grabs: new Map(),
    allowed: {},
    locked: false,
    statusArea: {},
    launched: [],
  });
});

afterEach(() => {
  for (const runtime of runtimes) runtime.stop();
  assert.deepEqual(events('runtime.error'), [], 'no part of the runtime failed');
});

after(() => {
  for (const dir of homes) rmSync(dir, {recursive: true, force: true});
});

const statePath = (name) => join(home, '.local/state/slated', name);
const events = (name) => {
  if (!existsSync(statePath('slated.log'))) return [];
  return readFileSync(statePath('slated.log'), 'utf8').trim().split('\n').map((line) => JSON.parse(line)).filter((e) => e.event === name);
};
const status = () => JSON.parse(readFileSync(statePath('status.json'), 'utf8'));
/** Get Started was finished in the settings window. */
const finishSetup = () => {
  mkdirSync(statePath(''), {recursive: true});
  writeFileSync(statePath('settings-window.json'), '{"setupFinished": true}\n');
};

/** Starts Slated as extension.js does: with a session object and openPreferences. */
function start(session = {paused: false, getStartedOpened: false}) {
  const runtime = new SlatedRuntime({
    path: join(home, 'extension'),
    metadata: {name: 'Slated', 'version-name': '0.1.0'},
    uuid: UUID,
    core: fakeCore,
    session,
    openPreferences: () => opened++,
  });
  runtime.start();
  gnome.loop.run();
  runtimes.push(runtime);
  return runtime;
}

function stop(runtime) {
  runtime.stop();
  runtimes = runtimes.filter((r) => r !== runtime);
}

const button = () => gnome.state.statusArea[UUID];
const items = () => button().menu.allItems();
const item = (text) => items().find((i) => i.label.text === text);
const iconFile = () => button().children[0].gicon.file.path;
const config = {
  clipboard: {shortcut: null},
  automation: {stopShortcut: null},
  keyboard: {capsLock: 'hyper'},
  bindings: [{name: 'Left half', keys: 'hyper+a', action: {op: 'push', direction: 'left'}}],
};

test('the icon is in the top bar while Slated runs, and goes with it', () => {
  finishSetup();
  writeConfigFiles(home, config);
  const runtime = start();
  assert.ok(button(), 'in the status area, under the extension’s uuid');
  assert.equal(button().accessible_name, 'Slated');
  assert.equal(iconFile(), join(home, 'extension/icons/slated-symbolic.svg'));
  assert.ok(existsSync(new URL('../../gnome-extension/icons/slated-symbolic.svg', import.meta.url)), 'the icon file ships with the extension');
  const shown = button();
  stop(runtime);
  assert.equal(button(), undefined, 'removed from the top bar');
  assert.ok(shown.destroyed);
});

test('a click opens the settings window; a right click or Ctrl+click opens the menu instead', () => {
  finishSetup();
  writeConfigFiles(home, config);
  start();
  button().click();
  assert.equal(opened, 1);
  assert.equal(button().menu.isOpen, false, 'no menu on a plain click');
  assert.deepEqual(events('menu.status_item_clicked').map((e) => e.data), [{result: 'opened'}]);

  button().click({button: 3});
  assert.equal(button().menu.isOpen, true);
  assert.equal(opened, 1);
  assert.equal(events('menu.opened').length, 1);
  button().menu.close();
  button().click({state: 4}); // Ctrl
  assert.equal(button().menu.isOpen, true);
  assert.equal(opened, 1);
});

test('an open settings window is brought forward, not opened again', () => {
  finishSetup();
  writeConfigFiles(home, config);
  start();
  const terminal = gnome.addWindow({id: 1, app: {id: 'org.gnome.Terminal', name: 'Terminal'}, title: 'Slated', frame: {x: 0, y: 0, width: 800, height: 600}});
  const prefs = gnome.addWindow({id: 2, app: {id: 'prefs', name: 'Extensions'}, title: 'Slated', frame: {x: 0, y: 0, width: 800, height: 600}, wmClass: 'org.gnome.Shell.Extensions'});
  gnome.focus(terminal);
  button().click();
  assert.equal(opened, 0);
  assert.equal(gnome.state.focused, prefs, 'Slated’s window, not another one titled Slated');
  assert.deepEqual(events('menu.status_item_clicked').map((e) => e.data), [{result: 'focused'}]);
  assert.equal(findSettingsWindow('Slated', [terminal]), null);
});

test('the menu has the Mac’s commands that apply on GNOME, in its order and with its names', () => {
  finishSetup();
  writeConfigFiles(home, config);
  start();
  assert.deepEqual(items().map((i) => i.label.text), [
    'Slated is running', '', MENU_ITEMS.open, MENU_ITEMS.hyper, MENU_ITEMS.pause, '',
    MENU_ITEMS.reload, MENU_ITEMS.config, MENU_ITEMS.settings, MENU_ITEMS.log,
  ]);
  assert.deepEqual([item(MENU_ITEMS.hyper).state, item(MENU_ITEMS.pause).state], [true, false]);
  assert.throws(() => item('Slated is running').activate(), /isn't clickable/);

  item(MENU_ITEMS.open).activate();
  assert.equal(opened, 1);
  assert.deepEqual(events('menu.settings').map((e) => e.data), [{result: 'opened'}]);

  item(MENU_ITEMS.config).activate();
  item(MENU_ITEMS.settings).activate();
  item(MENU_ITEMS.log).activate();
  assert.deepEqual(gnome.state.launched, [
    `file://${configPathIn(home)}`, `file://${settingsPathIn(home)}`, `file://${join(home, '.local/state/slated')}`,
  ]);
  for (const name of ['menu.open_config', 'menu.open_settings', 'menu.show_log']) assert.equal(events(name).length, 1, name);

  rmSync(settingsPathIn(home));
  item(MENU_ITEMS.settings).activate();
  assert.equal(gnome.state.launched.at(-1), `file://${join(home, '.config/slated')}`, 'no settings.json: its folder');

  item(MENU_ITEMS.reload).activate();
  gnome.loop.run();
  assert.equal(events('menu.reload').length, 1);
  assert.deepEqual(events('config.reload').map((e) => e.data.reason), ['menu']);
});

test('Caps Lock → Hyper Key turns the Hyper key off and on in config.json, and Slated follows', () => {
  finishSetup();
  writeConfigFiles(home, {...config, hotstrings: [{trigger: ';a', replacement: 'kept'}]});
  start();
  const xkb = () => gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'];
  assert.deepEqual(xkb(), ['compose:ralt', 'caps:hyper']);

  item(MENU_ITEMS.hyper).activate();
  gnome.loop.run();
  const saved = JSON.parse(readFileSync(configPathIn(home), 'utf8'));
  assert.equal(saved.keyboard.capsLock, 'off');
  assert.equal(saved.hotstrings[0].replacement, 'kept', 'the rest of config.json stays');
  assert.deepEqual(xkb(), ['compose:ralt']);
  assert.equal(item(MENU_ITEMS.hyper).state, false);
  assert.deepEqual(events('menu.toggle_hyper').map((e) => e.data), [{enable: false}]);

  item(MENU_ITEMS.hyper).activate();
  gnome.loop.run();
  assert.equal(JSON.parse(readFileSync(configPathIn(home), 'utf8')).keyboard.capsLock, 'hyper');
  assert.deepEqual(xkb(), ['compose:ralt', 'caps:hyper']);
  assert.equal(item(MENU_ITEMS.hyper).state, true);
});

test('Caps Lock → Hyper Key with a config.json that can’t be read: nothing written, and the switch goes back', () => {
  finishSetup();
  writeConfigFiles(home, config);
  start();
  writeFileSync(configPathIn(home), '{"keyboard": {"capsLock": "hyper"'); // a half-saved hand edit
  item(MENU_ITEMS.hyper).activate();
  gnome.loop.run();
  assert.equal(readFileSync(configPathIn(home), 'utf8'), '{"keyboard": {"capsLock": "hyper"', 'left as it is');
  assert.equal(events('config.save_failed').length, 1);
  assert.equal(item(MENU_ITEMS.hyper).state, true, 'the switch shows what Slated does');
});

test('Pause Slated lets go of shortcuts, the Hyper key and hotstrings until resumed, and shows on the icon', () => {
  finishSetup();
  mkdirSync(join(home, '.config/espanso'), {recursive: true});
  writeConfigFiles(home, {...config, hotstrings: [{trigger: ';sig', replacement: 'signature'}]});
  const matchFile = join(home, '.config/espanso/match/slated.yml');
  const session = {paused: false, getStartedOpened: false};
  let runtime = start(session);
  const xkb = () => gnome.state.settings['org.gnome.desktop.input-sources:xkb-options'];
  assert.deepEqual([gnome.accelerators(), xkb(), existsSync(matchFile)], [['<Hyper>a'], ['compose:ralt', 'caps:hyper'], true]);

  item(MENU_ITEMS.pause).activate();
  gnome.loop.run();
  assert.deepEqual([gnome.accelerators(), xkb(), existsSync(matchFile)], [[], ['compose:ralt'], false]);
  assert.equal(status().paused, true);
  assert.deepEqual(status().hotkeys, {});
  assert.equal(iconFile(), join(home, 'extension/icons/slated-paused-symbolic.svg'));
  assert.equal(items()[0].label.text, 'Slated is paused');
  assert.equal(item(MENU_ITEMS.pause).state, true);
  assert.deepEqual(events('menu.toggle_pause').map((e) => e.data), [{pause: true}]);
  assert.equal(events('app.paused').length, 1);

  // The screen locks and unlocks: GNOME disables and enables Slated, which stays paused.
  gnome.state.locked = true;
  stop(runtime);
  gnome.state.locked = false;
  runtime = start(session);
  assert.deepEqual([gnome.accelerators(), xkb(), status().paused], [[], ['compose:ralt'], true]);

  item(MENU_ITEMS.pause).activate();
  gnome.loop.run();
  assert.deepEqual([gnome.accelerators(), xkb(), existsSync(matchFile)], [['<Hyper>a'], ['compose:ralt', 'caps:hyper'], true]);
  assert.equal(status().paused, false);
  assert.equal(iconFile(), join(home, 'extension/icons/slated-symbolic.svg'));
  assert.equal(events('app.resumed').length, 1);
});

test('a shortcut GNOME refused shows as a warning on the icon and in the menu', () => {
  finishSetup();
  writeConfigFiles(home, {...config, bindings: [...config.bindings, {keys: 'cmd+a', action: {op: 'push', direction: 'up'}}]});
  start();
  assert.equal(iconFile(), join(home, 'extension/icons/slated-warning-symbolic.svg'));
  assert.equal(items()[1].label.text, "⚠ 1 shortcut couldn't be registered: GNOME or another app uses the keys");

  writeConfigFiles(home, config);
  gnome.fileChanged(configPathIn(home));
  gnome.loop.advance(300);
  assert.equal(iconFile(), join(home, 'extension/icons/slated-symbolic.svg'));
  assert.equal(items()[1].label.text, '', 'no warning left (the separator)');
});

test('warnings, and which icon wins', () => {
  assert.deepEqual(statusWarnings({}), []);
  assert.deepEqual(statusWarnings({loadError: `Couldn't read config.json: ${'x'.repeat(200)}`})[0].length, 90);
  assert.deepEqual(statusWarnings({hotkeys: {a: 'failed: taken', b: 'failed: taken', c: 'active'}}), ["2 shortcuts couldn't be registered: GNOME or another app uses the keys"]);
  assert.equal(iconName({paused: true, warnings: ['x']}), 'slated-paused-symbolic');
  assert.equal(iconName({warnings: ['x']}), 'slated-warning-symbolic');
  assert.equal(iconName({}), 'slated-symbolic');
});

test('Settings → General → Show Slated in the top bar takes the icon away and brings it back', () => {
  finishSetup();
  writeConfigFiles(home, {...config, general: {showStatusIcon: false}});
  start();
  assert.equal(button(), undefined);
  writeConfigFiles(home, {...config, general: {showStatusIcon: true}});
  gnome.fileChanged(settingsPathIn(home));
  gnome.loop.advance(300);
  assert.ok(button());
  writeConfigFiles(home, {...config, general: {showStatusIcon: false}});
  gnome.fileChanged(settingsPathIn(home));
  gnome.loop.advance(300);
  assert.equal(button(), undefined);
});

test('the first login opens Get Started a few seconds in, once a session, until it’s finished', () => {
  writeConfigFiles(home, config);
  const session = {paused: false, getStartedOpened: false};
  let runtime = start(session);
  assert.equal(opened, 0, 'not at once');
  gnome.loop.advance(GET_STARTED_DELAY_MS);
  assert.equal(opened, 1);
  assert.deepEqual(events('ui.get_started_opened').map((e) => e.data), [{result: 'opened'}]);

  // Closed without finishing, then the screen locks and unlocks: not again in this session.
  stop(runtime);
  runtime = start(session);
  gnome.loop.advance(GET_STARTED_DELAY_MS * 2);
  assert.equal(opened, 1);

  // The next login (a new session): again, until Get Started is finished.
  stop(runtime);
  runtime = start();
  gnome.loop.advance(GET_STARTED_DELAY_MS);
  assert.equal(opened, 2);
  stop(runtime);
  finishSetup();
  start();
  gnome.loop.advance(GET_STARTED_DELAY_MS * 2);
  assert.equal(opened, 2, 'finished: never again');
});

test('Get Started waits for an unlock, and isn’t opened when it was finished meanwhile', () => {
  writeConfigFiles(home, config);
  const session = {paused: false, getStartedOpened: false};
  const runtime = start(session);
  gnome.state.locked = true;
  gnome.loop.advance(GET_STARTED_DELAY_MS);
  assert.equal(opened, 0, 'not over the lock screen');
  stop(runtime);
  gnome.state.locked = false;
  start(session);
  finishSetup(); // finished in a window opened from the top bar meanwhile
  gnome.loop.advance(GET_STARTED_DELAY_MS);
  assert.equal(opened, 0);
});

test('settings-window.json and the first-login decision', () => {
  assert.equal(setupFinished(null), false);
  assert.equal(setupFinished('{broken'), false);
  assert.equal(setupFinished('{"setupFinished": true}'), true);
  assert.equal(shouldOfferGetStarted({stateText: null, alreadyOpened: false}), true);
  assert.equal(shouldOfferGetStarted({stateText: null, alreadyOpened: true}), false);
  assert.equal(shouldOfferGetStarted({stateText: null, alreadyOpened: false, locked: true}), false);
  assert.equal(shouldOfferGetStarted({stateText: '{"setupFinished": true}', alreadyOpened: false}), false);
});

// Window hints, the grid, the HUD and typed text, driven through the runtime against the simulated
// GNOME Shell (fake-gnome.mjs, with fake St/Clutter actors and events).

import assert from 'node:assert/strict';
import {existsSync, mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, beforeEach, test} from 'node:test';

import {writeConfigFiles} from './config-files.mjs';
import {fakeCore} from './fake-core.mjs';
import {createFakeGnome, fakeEvent} from './fake-gnome.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {SlatedRuntime} = await import('../../gnome-extension/lib/platform/runtime.js');
console.error = () => {};
console.log = () => {};

const homes = [];
let home;
let runtime;
let dbus;

beforeEach(() => {
  runtime?.stop();
  gnome.state.statusArea = {};
  home = mkdtempSync(join(tmpdir(), 'slated-overlays-'));
  homes.push(home);
  Object.assign(gnome.state, {
    home,
    env: {SLATED_DEBUG: '1'},
    focused: null,
    windows: [],
    apps: [],
    grabs: new Map(),
    allowed: {},
    chrome: new Set(),
    modal: [],
    typed: [],
    clipboard: 'previous clipboard',
  });
  // The island off: what a shortcut did shows in the bottom HUD (island.test.mjs covers the island).
  writeConfigFiles(home, {general: {showActionHUD: true}, island: {enabled: false}});
  runtime = new SlatedRuntime({path: home, metadata: {'version-name': '0.1.0'}, uuid: 'slated@shobhitg.github.io', core: fakeCore});
  runtime.start();
  gnome.loop.run();
  dbus = gnome.state.dbus.implementation;
});

after(() => {
  runtime?.stop();
  gnome.state.statusArea = {};
  for (const dir of homes) rmSync(dir, {recursive: true, force: true});
});

const logEvents = (name) =>
  existsSync(join(home, '.local/state/slated/slated.log'))
    ? readFileSync(join(home, '.local/state/slated/slated.log'), 'utf8')
        .trim()
        .split('\n')
        .map((line) => JSON.parse(line))
        .filter((e) => e.event === name)
    : [];

function overlayRoot() {
  const [root] = gnome.state.chrome;
  return root;
}

function twoWindows() {
  const files = gnome.addWindow({id: 2, app: {id: 'org.gnome.Nautilus', name: 'Files'}, frame: {x: 1000, y: 200, width: 600, height: 400}});
  const firefox = gnome.addWindow({id: 1, app: {id: 'firefox', name: 'Firefox'}, frame: {x: 100, y: 100, width: 800, height: 600}});
  return {firefox, files};
}

test('window hints put a letter on each window; typing one focuses it', () => {
  const {firefox, files} = twoWindows();
  assert.deepEqual(dbus.RunAction('{"op":"hint","characters":"AB"}'), [true, '']);
  const root = overlayRoot();
  assert.ok(root, 'overlay added as chrome');
  assert.equal(gnome.state.modal.length, 1, 'modal grab taken');
  assert.equal(gnome.state.modal[0].params.actionMode, 32);
  const letters = root.find((a) => a.text !== undefined).map((a) => a.text);
  assert.deepEqual(letters, ['A', 'B'], 'top window first');
  const [ringA] = root.children;
  assert.deepEqual([ringA.x, ringA.y], [100 + 400 - 48, 100 + 300 - 48], 'centered on the window');
  assert.equal(logEvents('hints.shown')[0].data.windows, 2);

  root.emit('key-press-event', fakeEvent({keysym: 0x62, unicode: 'b'}));
  assert.equal(gnome.state.focused, files);
  assert.equal(gnome.state.modal.length, 0, 'modal grab released');
  assert.equal(gnome.state.chrome.size, 0, 'overlay removed');
  assert.ok(root.destroyed);
  assert.equal(logEvents('hints.picked')[0].data.app, 'org.gnome.Nautilus');
  assert.notEqual(firefox, files);
});

test('a modifier alone keeps the hints; Escape dismisses them', () => {
  twoWindows();
  dbus.RunAction('{"op":"hint"}');
  const root = overlayRoot();
  root.emit('key-press-event', fakeEvent({keysym: 0xffe1})); // Shift_L
  assert.equal(gnome.state.modal.length, 1);
  root.emit('key-press-event', fakeEvent({keysym: 0xff1b}));
  assert.equal(gnome.state.modal.length, 0);
  assert.equal(logEvents('hints.dismissed').length, 1);
});

test('dragging across grid cells places the window, with undo', () => {
  const {firefox} = twoWindows();
  assert.deepEqual(dbus.RunAction('{"op":"grid","padding":4,"grids":{"0":{"width":6,"height":6}}}'), [true, '']);
  const root = overlayRoot();
  assert.equal(root.children.length, 2, 'one panel per screen');
  const panel = root.children[0];
  const title = panel.find((a) => typeof a.text === 'string')[0].text;
  assert.equal(title, 'Firefox — 6×6');
  const area = panel.children[1];
  const cells = area.find((a) => a.style_class === 'slated-grid-cell');
  assert.equal(cells.length, 36);
  assert.equal(area.find((a) => a.style_class === 'slated-grid-window').length, 1, 'outline of the current frame');

  // Stage coordinates of points inside the area: panel origin + area offset.
  const at = (fx, fy) => ({x: panel.x + area.x + fx * area.width, y: panel.y + area.y + fy * area.height});
  const start = at(0.05, 0.05);
  const end = at(0.45, 0.95);
  area.emit('button-press-event', fakeEvent({...start, actor: area}));
  area.emit('motion-event', fakeEvent({...end, actor: area}));
  assert.equal(cells.filter((c) => c.pseudoClasses.has('selected')).length, 18, '3×6 cells highlighted');
  area.emit('button-release-event', fakeEvent({...end, actor: area}));

  assert.deepEqual(firefox.frame, {x: 0, y: 32, width: 960, height: 1048});
  assert.equal(gnome.state.modal.length, 0);
  assert.equal(gnome.state.chrome.size, 0);
  assert.deepEqual(logEvents('grid.placed')[0].data, {app: 'firefox', frame: {x: 0, y: 32, width: 960, height: 1048}});

  assert.deepEqual(dbus.RunAction('{"op":"undo"}'), [true, '']);
  assert.deepEqual(firefox.frame, {x: 100, y: 100, width: 800, height: 600});
});

test('clicking outside the grid panels or pressing a key dismisses the grid', () => {
  twoWindows();
  dbus.RunAction('{"op":"grid"}');
  let root = overlayRoot();
  const panel = root.children[0];
  panel.emit('button-press-event', fakeEvent({actor: panel}));
  assert.equal(gnome.state.modal.length, 1, 'a click on a panel’s frame keeps it');
  root.emit('button-press-event', fakeEvent({actor: root}));
  assert.equal(gnome.state.modal.length, 0);
  assert.equal(logEvents('grid.dismissed').length, 1);

  dbus.RunAction('{"op":"grid"}');
  root = overlayRoot();
  root.emit('key-press-event', fakeEvent({keysym: 0x71, unicode: 'q'}));
  assert.equal(gnome.state.chrome.size, 0);
});

test('with the island off, the HUD shows what just happened near the bottom of the primary screen', () => {
  twoWindows();
  dbus.RunAction('{"op":"push","direction":"left","style":"bar-resize:screenSizeX/2"}');
  const hud = gnome.modules['resource:///org/gnome/shell/ui/main.js'].uiGroup.children.at(-1);
  const label = hud.children.find((c) => c.text !== undefined);
  assert.equal(label.text, 'push left bar-resize:screenSizeX/2 · Firefox');
  assert.equal(hud.style_class, 'slated-hud');
  assert.equal(hud.reactive, false);
  assert.equal(hud.y, 32 + 1048 - 36 - 72, 'above the bottom edge of the work area');
  assert.equal(hud.visible, false, 'faded out (instantly in the fake)');
});

/** "+k48" = keysym 0x48 pressed, "-c29" = evdev code 29 released. */
const presses = () => gnome.state.typed.map((k) => `${k.pressed ? '+' : '-'}${k.code !== undefined ? `c${k.code}` : `k${k.keysym.toString(16)}`}`);

test('insert-text types ASCII through the virtual keyboard and pastes the rest', () => {
  twoWindows();
  assert.deepEqual(dbus.RunAction('{"op":"insert-text","text":"Hi","method":"type"}'), [true, '']);
  gnome.loop.advance(50);
  assert.deepEqual(presses(), ['+k48', '-k48', '+k69', '-k69']);
  gnome.state.typed = [];
  assert.deepEqual(dbus.RunAction('{"op":"insert-text","text":"¯\\\\_(ツ)_/¯"}'), [true, '']);
  assert.equal(gnome.state.clipboard, '¯\\_(ツ)_/¯');
  assert.deepEqual(presses(), ['+c29', '+k76', '-k76', '-c29'], 'Ctrl+V');
  gnome.loop.advance(500);
  assert.equal(gnome.state.clipboard, 'previous clipboard', 'clipboard restored');
});

test('on a non-Latin layout text is pasted and Ctrl+V goes by key position', () => {
  twoWindows();
  gnome.state.inputSource = {type: 'xkb', id: 'ru', xkbId: 'ru'};
  try {
    assert.deepEqual(dbus.RunAction('{"op":"insert-text","text":"Hi","method":"type"}'), [true, '']);
    assert.equal(gnome.state.clipboard, 'Hi');
    assert.deepEqual(presses(), ['+c29', '+c47', '-c47', '-c29']);
    const [fallback] = logEvents('text.paste_fallback');
    assert.match(fallback.data.reason, /no Latin letters/);
    assert.equal(fallback.data.chars, 2);
  } finally {
    gnome.state.inputSource = {type: 'xkb', id: 'us', xkbId: 'us'};
  }
});

test('keystroke presses the combo with its modifiers', () => {
  twoWindows();
  assert.deepEqual(dbus.RunAction('{"op":"keystroke","keys":"cmd+shift+4"}'), [true, '']);
  assert.deepEqual(presses(), ['+c42', '+c125', '+k34', '-k34', '-c125', '-c42']);
  gnome.state.typed = [];
  assert.deepEqual(dbus.RunAction('{"op":"keystroke","keys":"ctrl+left"}'), [true, '']);
  assert.deepEqual(presses(), ['+c29', '+c105', '-c105', '-c29']);
});

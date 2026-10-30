// The island on GNOME (island.js, islandView.js, hyperHold.js) against the simulated shell: what it
// shows first, the Hyper cheat sheet's timing, the Stop button, the pill and HUD when it's off, and
// cleanup on disable. The runtime runs on the real engine (lib/core) in xkb Hyper mode.

import assert from 'node:assert/strict';
import {existsSync, mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, afterEach, beforeEach, mock, test} from 'node:test';

import * as realCore from '../../gnome-extension/lib/core/index.js';
import {writeConfigFiles} from './config-files.mjs';
import {createFakeGnome} from './fake-gnome.mjs';
import {leftHalf} from './fixtures.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {SlatedRuntime} = await import('../../gnome-extension/lib/platform/runtime.js');
const {IslandPresenter, cheatSheetDelayMs, islandSettings} = await import('../../gnome-extension/lib/platform/island.js');
const {HyperHoldWatcher, hyperMasks, IDLE_POLL_MS, ACTIVE_POLL_MS} = await import('../../gnome-extension/lib/platform/hyperHold.js');
const {automationDetail, elapsedText, iconFor, itemKeycap, sheetColumns} = await import('../../gnome-extension/lib/platform/islandView.js');
const {Timers} = await import('../../gnome-extension/lib/platform/timers.js');
console.error = () => {};
console.log = () => {};

const M = gnome.modules['gi://Clutter'].ModifierType;
const Main = gnome.modules['resource:///org/gnome/shell/ui/main.js'];
const homes = [];
let home;
let runtime;

// Automations, their timers and quick combos count in wall-clock time: follow the simulated clock.
const wallClock = Date.now();

beforeEach(() => {
  mock.method(Date, 'now', () => wallClock + gnome.loop.now);
  home = mkdtempSync(join(tmpdir(), 'slated-island-'));
  homes.push(home);
  Object.assign(gnome.state, {
    home,
    env: {SLATED_KEYD_CONF: join(home, 'etc/keyd/slated.conf')}, // never this computer's keyd
    programs: {},
    subprocesses: undefined,
    focused: null,
    windows: [],
    apps: [],
    settings: {'org.gnome.desktop.input-sources:xkb-options': []},
    taken: new Set(),
    grabs: new Map(),
    allowed: {},
    locked: false,
    buttons: [],
    typed: [],
    disposed: [],
    chrome: new Set(),
    chromeParams: new Map(),
    trackedChrome: new Map(),
    modal: [],
    modifiers: 0,
    overview: false,
  });
});

afterEach(() => {
  runtime?.stop();
  runtime = null;
  mock.restoreAll();
  assert.deepEqual(events('runtime.error'), [], 'no part of the runtime failed');
  assert.deepEqual(events('island.render_failed'), [], 'the island drew every presentation');
});

after(() => {
  for (const dir of homes) rmSync(dir, {recursive: true, force: true});
});

const configPath = () => join(home, '.config/slated/config.json');
const statePath = (name) => join(home, '.local/state/slated', name);

/** config.json and settings.json, version 2, from one object (Hyper on unless it says otherwise). */
function writeConfig(config) {
  writeConfigFiles(home, {keyboard: {capsLock: 'hyper'}, ...config});
}

function events(name) {
  if (!existsSync(statePath('slated.log'))) return [];
  return readFileSync(statePath('slated.log'), 'utf8')
    .trim()
    .split('\n')
    .map((line) => JSON.parse(line))
    .filter((e) => e.event === name);
}

function start(config) {
  writeConfig(config);
  runtime = new SlatedRuntime({path: join(home, 'extension'), metadata: {'version-name': '0.1.0'}, uuid: 'slated@shobhit-aida.github.io', core: realCore});
  runtime.start();
  gnome.loop.run();
  return runtime;
}

const autoClick = {op: 'repeat', action: {op: 'click', button: 'left'}, interval: 0.1};
const bindings = [
  {keys: 'hyper+a', name: 'Left half', action: leftHalf},
  {keys: 'hyper+right', action: {op: 'throw', screen: 'next'}},
  {keys: 'hyper+f', action: autoClick},
  {keys: 'h', modal: {keys: 'ctrl+e'}, action: 'undo'},
];
const firefox = {id: 'firefox', name: 'Firefox'};
const game = {id: 'org.prismlauncher.PrismLauncher', name: 'Prism Launcher'};

const holder = () => [...gnome.state.chrome].find((a) => a.name === 'slatedIslandHolder') ?? null;
const island = () => holder()?.children[0] ?? null;
const shown = () => !!(holder()?.visible && island()?.visible && island().opacity === 255);
/** Every text in the island, in order. */
const texts = (actor = island()) => (actor ? actor.find((a) => typeof a.text === 'string').map((a) => a.text) : []);
const byClass = (name, actor = island()) => actor?.find((a) => String(a.style_class ?? '').split(' ').includes(name)) ?? [];
const pill = () => Main.uiGroup.children.find((a) => a.style_class === 'slated-automation-pill');
const hud = () => Main.uiGroup.children.find((a) => a.style_class === 'slated-hud');
const clicks = () => gnome.state.buttons.filter((b) => b.pressed).length;

/** Holds the Hyper key (xkb: it shares Super's Mod4) until it's noticed. */
function holdHyper() {
  gnome.state.modifiers = M.MOD4_MASK;
  gnome.loop.advance(IDLE_POLL_MS);
}

function releaseHyper() {
  gnome.state.modifiers = 0;
  gnome.loop.advance(ACTIVE_POLL_MS);
}

// --- What shows first ------------------------------------------------------------------------------

/** Records what the presenter asks the view to draw. */
class RecordingView {
  constructor() {
    this.last = {kind: 'hidden'};
    this.ticks = 0;
  }
  render(presentation, state, options) {
    this.last = presentation;
    this.state = state;
    this.options = options;
  }
  tick(state) {
    this.ticks += 1;
    this.state = state;
  }
  destroy() {
    this.destroyed = true;
  }
}

function presenter(settings = {}) {
  const view = new RecordingView();
  const timers = new Timers();
  const presenterInstance = new IslandPresenter({timers, view, now: () => gnome.loop.now});
  presenterInstance.apply(settings);
  return {island: presenterInstance, view, timers};
}

const hyperSheet = realCore.hyperCheatSheet(bindings, ['ctrl', 'alt', 'shift', 'cmd']);
const modalSheet = realCore.modalCheatSheet('ctrl+e', bindings);
const running = [{id: 'hotkey hyper+f', title: 'Repeat click left every 100 ms', trigger: 'hotkey hyper+f', startedAt: 0, repetitions: 3}];

test('priority: the cheat sheet, then the modal key, then a banner, then running automations', () => {
  const {island, view, timers} = presenter();
  island.hyperSheet = () => hyperSheet;
  const kind = () => view.last.kind;
  assert.equal(kind(), 'hidden');

  island.automationsChanged(running, {stopLabel: '✦ Esc'});
  assert.deepEqual(view.last, {kind: 'automations', expanded: false});
  island.flash({title: 'Left half', app: 'Firefox', region: {x: 0, y: 0, width: 0.5, height: 1}, symbol: 'arrow.left.to.line'}, {monitor: 1});
  assert.equal(kind(), 'banner');
  assert.equal(view.options.monitor, 1, 'on the moved window’s monitor');
  island.modalChanged(modalSheet);
  assert.deepEqual([kind(), view.last.expanded], ['modal', false]);
  gnome.loop.advance(500);
  assert.deepEqual([kind(), view.last.expanded], ['modal', true], 'its keys after the delay');
  island.hyperPressed();
  gnome.loop.advance(499);
  assert.equal(kind(), 'modal');
  gnome.loop.advance(1);
  assert.equal(kind(), 'cheatSheet');
  assert.equal(view.options.focused, true, 'where you’re working');

  island.hyperReleased();
  assert.equal(kind(), 'modal');
  island.modalChanged(null);
  assert.equal(kind(), 'banner', 'the banner is still up');
  gnome.loop.advance(1300);
  assert.equal(kind(), 'automations', 'then the automations again');
  island.automationsChanged([]);
  assert.equal(kind(), 'hidden');
  island.destroy();
  timers.clearAll();
});

test('a combo that fires before the hold is noticed still counts as quick', () => {
  const {island, view, timers} = presenter();
  island.hyperSheet = () => hyperSheet;
  island.hyperUsed(); // Caps Lock+A, then the poll notices Caps Lock still down
  gnome.loop.advance(100);
  island.hyperPressed();
  gnome.loop.advance(1000);
  assert.equal(view.last.kind, 'hidden');
  island.hyperReleased();
  island.hyperPressed(); // a later hold, with no combo
  gnome.loop.advance(500);
  assert.equal(view.last.kind, 'cheatSheet');
  island.destroy();
  timers.clearAll();
});

test('failures show only with showFailures; a disabled island shows nothing and lets go of everything', () => {
  const {island, view, timers} = presenter({showFailures: false});
  island.flashFailure('No focused window to move');
  assert.equal(view.last.kind, 'hidden');
  island.apply({showFailures: true});
  island.flashFailure('No focused window to move');
  assert.deepEqual(view.last.banner, {kind: 'failed', message: 'No focused window to move'});
  gnome.loop.advance(2400);
  assert.equal(view.last.kind, 'hidden', 'failures stay up a little longer, then go');

  island.automationsChanged(running);
  island.modalChanged(modalSheet);
  island.apply({enabled: false});
  assert.equal(view.last.kind, 'hidden');
  island.flash({title: 'Left half', symbol: 'checkmark'});
  island.automationsChanged(running);
  island.hyperPressed();
  gnome.loop.advance(1000);
  assert.equal(view.last.kind, 'hidden');
  island.destroy();
  assert.equal(view.destroyed, true);
  timers.clearAll();
});

test('settings: defaults for a config without an island section, and the delay is kept between 0.15 and 3 s', () => {
  assert.deepEqual(islandSettings(undefined), {enabled: true, cheatSheet: true, cheatSheetDelay: 0.5, showFailures: true});
  assert.deepEqual(islandSettings({enabled: false, cheatSheetDelay: 1, bogus: 1}), {enabled: false, cheatSheet: true, cheatSheetDelay: 1, showFailures: true});
  assert.equal(cheatSheetDelayMs({cheatSheetDelay: 0}), 150);
  assert.equal(cheatSheetDelayMs({cheatSheetDelay: 0.5}), 500);
  assert.equal(cheatSheetDelayMs({cheatSheetDelay: 60}), 3000);
});

test('labels: elapsed time, automation details, keycaps in GNOME’s words, icons and columns', () => {
  assert.deepEqual([elapsedText(0), elapsedText(42_900), elapsedText(725_000), elapsedText(3_723_000)], ['0:00', '0:42', '12:05', '1:02:03']);
  const comboOf = (text) => realCore.parseKeyCombo(text);
  assert.equal(automationDetail(running[0], 42_000, comboOf), '✦ F · 3 times · 0:42');
  assert.equal(automationDetail({id: 'hold:key:w', title: 'Hold W', trigger: 'hotkey hyper+w', startedAt: 0, repetitions: 1}, 5000, comboOf), '✦ W · 0:05');
  const sheet = realCore.hyperCheatSheet([{keys: 'hyper+shift+h', action: 'undo'}, {keys: 'hyper+esc', action: 'stop-automations'}, {keys: 'fn+hyper+f1', action: 'undo'}]);
  assert.deepEqual(sheet.sections.flatMap((s) => s.items.map((item) => itemKeycap(item, sheet))), ['H', 'Fn F1', 'Esc']);
  const meh = realCore.hyperCheatSheet([{keys: 'ctrl+alt+shift+cmd+h', action: 'undo'}], ['ctrl', 'alt', 'shift']);
  assert.equal(itemKeycap(meh.sections[0].items[0], meh), 'Super H');
  const modal = realCore.modalCheatSheet('ctrl+e', [{keys: 'shift+k', modal: 'ctrl+e', action: 'undo'}]);
  assert.equal(itemKeycap(modal.sections[0].items[0], modal), 'Shift K');
  assert.equal(iconFor('arrow.uturn.backward'), 'edit-undo-symbolic');
  assert.equal(iconFor('no.such.symbol'), 'object-select-symbolic');
  assert.deepEqual([sheetColumns(6), sheetColumns(7), sheetColumns(36), sheetColumns(37)], [2, 3, 3, 4]);
});

// --- Reading the Hyper key ---------------------------------------------------------------------------

test('Hyper is read lightly while idle and at 20 Hz once a Hyper modifier is down, until it’s let go', () => {
  const timers = new Timers();
  let mods = 0;
  let reads = 0;
  const changes = [];
  const watcher = new HyperHoldWatcher({
    timers,
    readModifiers: () => {
      reads += 1;
      return mods;
    },
    onChange: (held) => changes.push(held),
  });
  const keyd = hyperMasks('keyd', ['ctrl', 'alt', 'shift', 'cmd'], M);
  watcher.watch(keyd);
  gnome.loop.advance(1500);
  assert.equal(reads, 10, 'every 150 ms while nothing is held');

  reads = 0;
  mods = M.CONTROL_MASK | M.MOD1_MASK; // keyd presses the modifiers one by one
  gnome.loop.advance(150);
  assert.deepEqual(changes, [], 'not all of Hyper yet');
  gnome.loop.advance(100);
  assert.equal(reads, 3, 'faster once a Hyper modifier is down');
  mods = M.CONTROL_MASK | M.MOD1_MASK | M.SHIFT_MASK | M.MOD4_MASK;
  gnome.loop.advance(50);
  assert.deepEqual(changes, [true]);
  mods = M.SHIFT_MASK;
  gnome.loop.advance(50);
  assert.deepEqual(changes, [true, false], 'let go as soon as one is up');

  watcher.stop();
  reads = 0;
  gnome.loop.advance(1000);
  assert.equal(reads, 0, 'stopped: nothing is read');
  watcher.destroy();
  timers.clearAll();
});

test('the Hyper modifiers: all four with keyd (or the hyperModifiers set), the Hyper/Super modifier with caps:hyper', () => {
  const keyd = hyperMasks('keyd', ['ctrl', 'alt', 'shift', 'cmd'], M);
  assert.deepEqual(keyd.required, [M.CONTROL_MASK, M.MOD1_MASK, M.SHIFT_MASK, M.MOD4_MASK | M.SUPER_MASK]);
  assert.deepEqual(hyperMasks('keyd', ['ctrl', 'alt', 'shift'], M).required, [M.CONTROL_MASK, M.MOD1_MASK, M.SHIFT_MASK], 'Meh');
  assert.deepEqual(hyperMasks('xkb', undefined, M).required, [M.MOD4_MASK | M.SUPER_MASK | M.HYPER_MASK]);
  assert.equal(hyperMasks('off', undefined, M), null);
});

// --- The cheat sheet ---------------------------------------------------------------------------------

test('holding Hyper past the delay lists every Hyper shortcut, grouped; letting go hides it', () => {
  start({bindings});
  holdHyper();
  gnome.loop.advance(400);
  assert.equal(shown(), false, 'not before the delay');
  gnome.loop.advance(150);
  assert.equal(shown(), true);
  const all = texts();
  for (const text of ['✦', 'Hyper', '4 shortcuts', 'Release Caps Lock to close', 'WINDOWS', 'DISPLAYS', 'AUTOMATION', 'Left half', 'Next Display', 'Repeat Click Left every 100 ms', 'Stop automations']) {
    assert.ok(all.includes(text), `lists ${text}: ${JSON.stringify(all)}`);
  }
  assert.ok(!all.includes('Undo'), 'not the modal key’s shortcut');
  assert.deepEqual(byClass('slated-island-cell').map((cell) => texts(cell)[0]), ['A', '→', 'F', 'Esc'], 'keycaps in keyboard order');
  assert.equal(byClass('slated-island-region').length, 1, 'Left half shows where it puts the window');
  assert.deepEqual([holder().x, holder().y, island().y], [0, 32, 0], 'hangs from the top bar of the primary monitor');
  assert.equal(island().reactive, false, 'takes no input');
  assert.deepEqual(gnome.state.chromeParams.get(holder()), {affectsInputRegion: false});
  assert.equal(events('island.cheat_sheet')[0].data.items, 4);

  releaseHyper();
  assert.equal(shown(), false);
});

test('a quick Hyper combo never shows the sheet; a shortcut pressed while it shows lights up', () => {
  start({bindings});
  gnome.addWindow({id: 1, app: firefox, frame: {x: 100, y: 100, width: 800, height: 600}});
  holdHyper();
  assert.ok(gnome.press('<Hyper>a'));
  gnome.loop.advance(1000);
  assert.equal(shown(), false, 'a shortcut while held: no sheet');
  releaseHyper();
  holdHyper();
  gnome.loop.advance(300);
  releaseHyper();
  gnome.loop.advance(1000);
  assert.equal(shown(), false, 'let go before the delay');

  holdHyper();
  gnome.loop.advance(500);
  assert.equal(shown(), true);
  assert.ok(gnome.press('<Hyper>a'));
  const lit = byClass('slated-island-cell').filter((cell) => cell.pseudoClasses.has('highlighted'));
  assert.deepEqual(lit.map((cell) => texts(cell).at(-1)), ['Left half']);
  gnome.loop.advance(700);
  assert.equal(byClass('slated-island-cell').filter((cell) => cell.pseudoClasses.has('highlighted')).length, 0);
  assert.equal(shown(), true, 'it stays up while Hyper is held');
  releaseHyper();
  assert.equal(shown(), false);
});

test('the sheet goes to the focused window’s monitor and leaves out other apps’ shortcuts', () => {
  start({bindings: [...bindings, {keys: 'hyper+g', onlyInApps: ['org.prismlauncher.PrismLauncher.desktop'], action: autoClick}]});
  gnome.addWindow({id: 1, app: firefox, frame: {x: 2000, y: 100, width: 800, height: 600}});
  gnome.state.windows[0].monitor = 1;
  gnome.state.windows[0].get_monitor = () => 1;
  holdHyper();
  gnome.loop.advance(500);
  assert.deepEqual([holder().x, holder().y], [1920, 0], 'the portrait monitor, which has no top bar');
  assert.ok(texts().includes('4 shortcuts'), 'the game’s shortcut isn’t live in Firefox');
  releaseHyper();
});

test('no Hyper key, cheat sheet off or nothing on Hyper: the modifiers aren’t read at all', () => {
  let reads = 0;
  const read = gnome.global.get_pointer;
  gnome.global.get_pointer = () => {
    reads += 1;
    return read();
  };
  try {
    const noHyperShortcut = {bindings: [{keys: 'ctrl+alt+t', action: 'undo'}], automation: {stopShortcut: null}};
    for (const config of [{keyboard: {capsLock: 'off'}, bindings}, {bindings, island: {cheatSheet: false}}, {bindings, island: {enabled: false}}, noHyperShortcut]) {
      start(config);
      reads = 0;
      gnome.loop.advance(2000);
      assert.equal(reads, 0, JSON.stringify(config));
      runtime.stop();
      runtime = null;
    }
  } finally {
    gnome.global.get_pointer = read;
  }
});

test('a modal key shows in the island, then its keys after the delay, and goes when it’s used', () => {
  start({bindings});
  assert.ok(gnome.press('<Control>e'));
  gnome.loop.run();
  assert.equal(shown(), true);
  assert.ok(texts().includes('Ctrl E'));
  gnome.loop.advance(500);
  const all = texts();
  for (const text of ['Ctrl E', 'then', '1 shortcut', 'Press a key, or Esc to cancel', 'H', 'Undo']) assert.ok(all.includes(text), `lists ${text}: ${JSON.stringify(all)}`);
  assert.ok(gnome.press('h'));
  gnome.loop.run();
  assert.equal(shown(), false);
});

// --- Banners -------------------------------------------------------------------------------------------

test('what a shortcut did shows as a banner where the window went; why one failed too, unless showFailures is off', () => {
  start({bindings, general: {showActionHUD: true}});
  gnome.addWindow({id: 1, app: firefox, frame: {x: 100, y: 100, width: 800, height: 600}});
  assert.ok(gnome.press('<Hyper>a'));
  assert.equal(shown(), true);
  assert.deepEqual(texts(), ['Left half', '·', 'Firefox']);
  const [fill] = byClass('slated-island-region-fill');
  assert.deepEqual([fill.x, fill.y, fill.width, fill.height], [2, 2, 11, 13], 'the left half of the screen glyph');
  assert.equal(hud(), undefined, 'not in the bottom HUD');
  gnome.loop.advance(1300);
  assert.equal(shown(), false);

  gnome.focus(null);
  assert.ok(gnome.press('<Hyper>a'));
  assert.deepEqual(texts(), ['No focused window to move']);
  assert.equal(byClass('slated-island-warning').length, 1);
  gnome.loop.advance(2400);
  assert.equal(shown(), false);
  runtime.stop();

  start({bindings, general: {showActionHUD: true}, island: {showFailures: false}});
  assert.ok(gnome.press('<Hyper>a'));
  assert.equal(shown(), false, 'showFailures off');
  assert.equal(events('action.failed').at(-1).data.error, 'No focused window to move', 'still logged');
});

// --- Automations ---------------------------------------------------------------------------------------

test('running automations show in the island; hovering opens it up and Stop stops them', () => {
  start({bindings});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  assert.ok(gnome.press('<Hyper>f'));
  gnome.loop.advance(250);
  assert.equal(clicks(), 3);
  assert.equal(shown(), true);
  assert.equal(pill()?.visible ?? false, false, 'not the pill');
  assert.equal(byClass('slated-island-dot').length, 1);
  assert.equal(texts().at(-1), '0:00');
  gnome.loop.advance(1000);
  assert.equal(texts().at(-1), '0:01', 'the timer counts up');
  assert.equal(island().reactive, true, 'takes the pointer while automations run');
  assert.deepEqual(gnome.state.trackedChrome.get(island()), {affectsInputRegion: true});

  island().hover = true;
  island().emit('notify::hover');
  const all = texts();
  for (const text of ['Repeat click left every 100 ms', 'or press', '✦ Esc']) assert.ok(all.includes(text), `shows ${text}: ${JSON.stringify(all)}`);
  assert.match(all.find((t) => t.startsWith('✦ F')), /^✦ F · \d+ times · 0:01$/);
  const [stop] = byClass('slated-island-stop');
  assert.equal(stop.label, 'Stop');
  assert.equal(stop.can_focus, false, 'never takes keyboard focus');
  stop.emit('clicked');
  const before = clicks();
  gnome.loop.advance(1000);
  assert.equal(clicks(), before, 'stopped');
  assert.equal(events('island.stop_clicked').length, 1);
  assert.equal(events('automation.stopped_all')[0].data.reason, 'stopped from the island');
  assert.equal(shown(), false);
  assert.equal(island().reactive, false);
  assert.equal(gnome.state.trackedChrome.size, 0, 'out of the input region again');
});

test('with the island off, the pill and the HUD come back; turning it on moves what runs into the island', () => {
  start({bindings, general: {showActionHUD: true}, island: {enabled: false}});
  const window = gnome.addWindow({id: 1, app: game, frame: {x: 100, y: 100, width: 800, height: 600}});
  assert.ok(gnome.press('<Hyper>a'));
  assert.equal(hud()?.style_class, 'slated-hud');
  assert.ok(gnome.press('<Hyper>f'));
  gnome.loop.advance(150);
  assert.equal(pill()?.visible, true);
  holdHyper();
  gnome.loop.advance(1000);
  releaseHyper();
  assert.equal(holder(), null, 'no island at all');

  writeConfig({bindings, general: {showActionHUD: true}});
  gnome.fileChanged(configPath());
  gnome.loop.advance(300);
  // A reload stops automations (safety); start one again.
  gnome.focus(window);
  assert.ok(gnome.press('<Hyper>f'));
  gnome.loop.advance(150);
  assert.equal(pill().visible, false);
  assert.equal(shown(), true);
  assert.equal(byClass('slated-island-dot').length, 1);
});

// --- Disable ---------------------------------------------------------------------------------------------

test('disabling removes the island, its timers, signal handlers and input region', () => {
  start({bindings, general: {showActionHUD: true}});
  gnome.addWindow({id: 1, app: game, frame: {x: 0, y: 0, width: 800, height: 600}});
  assert.ok(gnome.press('<Hyper>f'));
  gnome.loop.advance(150);
  island().hover = true;
  island().emit('notify::hover');
  holdHyper();
  gnome.loop.advance(500);
  assert.equal(shown(), true);
  const actor = island();
  const outer = holder();
  runtime.stop();
  runtime = null;
  assert.equal(gnome.state.chrome.size, 0, 'no chrome left');
  assert.equal(gnome.state.trackedChrome.size, 0);
  assert.equal(actor.destroyed && outer.destroyed, true, 'actors destroyed');
  assert.equal(actor.handlers.size, 0, 'hover handler disconnected');
  assert.equal(gnome.loop.pending, 0, 'no polling, tickers or banner timers left');
  assert.equal(gnome.signals.display.size, 0);
  gnome.state.modifiers = 0;
});

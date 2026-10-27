// Smoke test for the preferences UI (prefs.js and lib/prefs/ui), run under Node on mock GTK and
// libadwaita generated from the real GObject-introspection data (gi/api.json):
//
//   node linux/tests/prefs/ui.mjs
//
// It builds the window twice, once with only GNOME 46 API ("min") and once with GNOME 49 API
// reachable behind `in` checks ("new"), against a temporary home with a config, a status file, a
// ~/.slate.js and a log. Then it uses every page the way a person would: switching sections,
// editing and recording shortcuts, trying every action kind, presets and nested editors, hotstrings,
// clipboard and automation settings, recipes, app pickers, layouts, importing the Slate file, and
// closing the window. Any unknown GTK/libadwaita API, wrong
// argument count, GTK critical (removing a non-child, double parenting), unguarded newer API, or a
// JavaScript error in a handler fails the run. It doesn't check pixels: that's the manual checklist.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {register} from 'node:module';

import {createWorld, findAll, descendants, prop, MockError} from './gi/mock.mjs';

// Before anything imports the preferences modules: gi://, cairo and the engine go to the mocks.
register('./gi/hooks.mjs', import.meta.url);
const {decodeConfiguration} = await import('../../gnome-extension/lib/prefs/engine.js');
const {kindById} = await import('../../gnome-extension/lib/prefs/actions.js');

const here = path.dirname(new URL(import.meta.url).pathname);
const api = JSON.parse(fs.readFileSync(path.join(here, 'gi/api.json'), 'utf8'));
const author = fs.readFileSync(path.join(here, 'fixtures/slate-author-like.js'), 'utf8');
const UUID = 'slated@shobhit-aida.github.io';

// Fixture ids: config.json ids must be UUIDs (the engine rejects anything else, as Swift does).
const ID = Object.fromEntries(['HALF', 'CHAIN', 'ORIENT', 'LAYOUT', 'BAD', 'SYNTAX', 'OFF', 'SHRUG', 'SIG', 'CLICKER', 'MOUSE']
  .map((name, i) => [name, `00000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`]));

// Deprecated API the preferences can't avoid: GNOME Shell hands every extension an
// Adw.PreferencesWindow (deprecated in libadwaita 1.6; this test creates it in GNOME Shell's
// place), and Slated must add a page to it and turn its search off.
const ALLOWED_DEPRECATIONS = new Set([
  'Adw.PreferencesWindow', 'Adw.PreferencesWindow.add', 'Adw.PreferencesWindow.set_search_enabled',
  'Adw.PreferencesWindow.search-enabled',
]);

let failures = 0;
let passes = 0;
const fail = (what, error) => {
  failures++;
  console.log(`  ✘ ${what}`);
  console.log(`      ${String(error?.stack ?? error).split('\n').slice(0, 8).join('\n      ')}`);
};
const pass = what => {
  passes++;
  console.log(`  ✔ ${what}`);
};
const check = (condition, message) => {
  if (!condition) throw new Error(message);
};

function makeHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'slated-prefs-ui-'));
  const config = {
    keyboard: {capsLock: 'hyper'},
    bindings: [
      {id: ID.HALF, name: 'Left half', keys: 'hyper+a', action: {op: 'push', direction: 'left', style: 'bar-resize:screenSizeX/2'}},
      {id: ID.CHAIN, name: 'Cycle', keys: 'hyper+[', action: {op: 'chain', operations: [
        {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY'},
        {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/3', height: 'screenSizeY'},
      ]}},
      {id: ID.ORIENT, keys: 'hyper+f', action: {op: 'by-orientation',
        landscape: {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/3', height: 'screenSizeY'},
        portrait: {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX', height: 'screenSizeY/3'}}},
      {id: ID.LAYOUT, keys: 'hyper+1', action: {op: 'layout', name: 'Coding'}},
      {id: ID.BAD, name: 'Typo', keys: 'hyper+b', action: {op: 'move', x: 'screnOriginX', y: '0', width: '10', height: '10'}},
      {id: ID.SYNTAX, keys: 'hyper+s', action: 'push right bar-resize:screenSizeX/3'},
      {id: ID.OFF, keys: 'hyper+o', enabled: false, action: {op: 'undo'}},
      {id: ID.CLICKER, name: 'Auto-clicker', keys: 'f', onlyInApps: ['org.prismlauncher.PrismLauncher'],
        action: {op: 'repeat', action: {op: 'click', button: 'left'}, interval: 0.1}},
      {id: ID.MOUSE, keys: 'mouse4', action: {op: 'hold', input: 'mouse:right'}},
    ],
    layouts: [{name: 'Coding', apps: [{app: 'Firefox', operations: [{op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX', height: 'screenSizeY'}]}]}],
    hotstrings: [
      {id: ID.SHRUG, trigger: ';s', replacement: '¯\\_(ツ)_/¯'},
      {id: ID.SIG, trigger: ';sig', replacement: 'Thanks', onlyInApps: ['org.gnome.Evolution']},
    ],
    // Hand-edited values the Clipboard and Automation pages offer as their own choices and keep.
    clipboard: {maxItems: 42, shortcut: null},
    automation: {showIndicator: false},
    // The Mac's notch island: no GNOME page edits it, but a save must keep it for the Mac.
    island: {enabled: false, cheatSheetDelay: 0.8},
  };
  fs.mkdirSync(path.join(home, '.config/slated'), {recursive: true});
  fs.writeFileSync(path.join(home, '.config/slated/config.json'), JSON.stringify(config, null, 2));
  fs.mkdirSync(path.join(home, '.local/state/slated'), {recursive: true});
  const status = {
    session: 'abcd1234', version: '0.1.0', running: true, updatedAt: new Date().toISOString(),
    hyper: {wanted: true, mode: 'xkb', active: true},
    hotstrings: {engine: 'none', espansoInstalled: false, matchFile: null, count: 0},
    hotkeys: {'hyper+a': 'active', 'hyper+[': 'duplicate', 'hyper+f': 'failed: taken by GNOME', f: 'active',
      mouse4: "failed: GNOME can't use mouse buttons as shortcuts. Map the button to a key with keyd (for example mouse1 = f13), then bind that key (F13–F20)"},
    automation: {running: ['Repeat click left every 100 ms'], shortcuts: ['f'], stopShortcut: 'hyper+esc', whileHeld: 'key-repeat'},
    clipboard: {enabled: true, items: 12},
    recentApps: [{id: 'steam_app_1086940', name: 'steam_app_1086940'}, {id: 'org.mozilla.firefox', name: 'Firefox'}],
    sources: [{path: '~/.slate.js', kind: 'javascript', exists: true, loaded: true, bindings: 21, diagnostics: ['line 3: something odd']}],
    screens: [
      {displayID: 1, name: 'Laptop', frame: {x: 0, y: 0, width: 1920, height: 1080}, visibleFrame: {x: 0, y: 32, width: 1920, height: 1048}, isMain: true, scale: 1},
      {displayID: 2, name: 'Tall', frame: {x: 1920, y: 0, width: 1080, height: 1920}, visibleFrame: {x: 1920, y: 0, width: 1080, height: 1920}, isMain: false, scale: 1},
    ],
    lastAction: 'Left half · firefox', lastError: "Couldn't resize Calculator",
  };
  fs.writeFileSync(path.join(home, '.local/state/slated/status.json'), JSON.stringify(status));
  fs.writeFileSync(path.join(home, '.local/state/slated/slated.log'),
    `${JSON.stringify({ts: new Date().toISOString(), level: 'notice', event: 'app.start', session: 'abcd1234', data: {commit: 'abc1234'}})}\n`);
  fs.writeFileSync(path.join(home, '.slate.js'), author);
  const extension = path.join(home, '.local/share/gnome-shell/extensions', UUID);
  fs.mkdirSync(extension, {recursive: true});
  fs.writeFileSync(path.join(extension, 'build-info.json'), JSON.stringify({version: '0.1.0', commit: 'abc1234-dirty', builtAt: '2026-10-22T18:00:00Z'}));
  return {home, extension, configFile: path.join(home, '.config/slated/config.json'), statusFile: path.join(home, '.local/state/slated/status.json'),
    logFile: path.join(home, '.local/state/slated/slated.log')};
}

async function run(mode) {
  console.log(`\nPreferences UI on ${mode === 'min' ? 'GNOME 46 API only' : 'GNOME 49 API behind checks'}`);
  const files = makeHome();
  const shell = {state: 1, calls: []};
  const world = createWorld({
    api, home: files.home, mode,
    env: {apps: [{id: 'org.mozilla.firefox', name: 'Firefox'}, {id: 'org.gnome.TextEditor', name: 'Text Editor'},
      {id: 'org.keepassxc.KeePassXC', name: 'KeePassXC'}],
      keyNames: {97: {name: 'a', char: 'a'}, 65307: {name: 'Escape'}, 65288: {name: 'BackSpace'}, 65505: {name: 'Shift_L'}, 49: {name: '1', char: '1'},
        65515: {name: 'Super_L'}, 65517: {name: 'Hyper_L'}, 65475: {name: 'F6'}, 118: {name: 'v', char: 'v'}, 32: {name: 'space', char: ' '}}},
    dbus: method => {
      shell.calls.push(method);
      if (method === 'GetExtensionInfo') return [{state: shell.state, error: ''}];
      if (method === 'EnableExtension' || method === 'DisableExtension') return [true];
      return [];
    },
  });
  globalThis.__slatedWorld = world;
  const errors = [];
  globalThis.logError = (error, message) => errors.push(`${message}: ${error?.stack ?? error}`);
  const {Adw, Gtk, Gdk} = world.namespaces;
  // Like spinning the main loop: run due timers and idles, and let promise callbacks (D-Bus replies)
  // run in between.
  const settle = async () => {
    for (let i = 0; i < 5; i++) {
      world.runTimers({rounds: 20});
      await new Promise(resolve => setImmediate(resolve));
    }
  };
  const step = async (what, fn) => {
    try {
      await fn();
      await settle();
      if (errors.length) throw new Error(errors.splice(0).join('\n'));
      pass(what);
    } catch (error) {
      fail(what, error);
    }
  };

  const {default: SlatedPreferences} = await import('../../gnome-extension/prefs.js');
  const window = new Adw.PreferencesWindow();
  let settings;
  await step('builds the window and replaces its content with the sidebar layout', async () => {
    new SlatedPreferences({uuid: UUID, path: files.extension, name: 'Slated', 'version-name': '0.1.0'}).fillPreferencesWindow(window);
    settings = window._slated;
    check(settings, 'prefs.js keeps a reference to the settings');
    check(findAll(world, window, 'Adw.ToastOverlay').length === 1, 'the window shows Slated\'s own content');
    check(findAll(world, window, 'Adw.NavigationSplitView').length === 1, 'a split view');
  });
  if (!settings) return;

  const model = settings.model;
  const sidebar = findAll(world, window, 'Gtk.ListBox', (w, s) => (s.props.get('css-classes') ?? []).includes('navigation-sidebar'))[0];
  const rows = findAll(world, sidebar, 'Gtk.ListBoxRow', (w, s) => s.expandos._slatedId);
  const navOf = id => settings.panes.get(id).nav;
  const visible = id => navOf(id).get_visible_page();
  const activate = row => world.emit(row, 'activated');
  const click = button => world.emit(button, 'clicked');
  const rowsIn = (root, filter = () => true) => findAll(world, root, 'Adw.ActionRow', filter);
  const titled = (root, cls, title) => findAll(world, root, cls, (w, s) => s.props.get('title') === title);
  /** Buttons labeled `text`, directly or through an Adw.ButtonContent child. */
  const buttons = (root, text) => findAll(world, root, 'Gtk.Button', (w, s) =>
    s.props.get('label') === text || world.stateOf(s.slots.child ?? null)?.props.get('label') === text);
  const pop = id => navOf(id).pop();
  const recorderIn = row => findAll(world, row, 'Gtk.Button', (w, s) => (s.props.get('css-classes') ?? []).includes('slated-recorder'))[0];
  const press = (keyval, state = 0) => world.emit(findAll(world, window, 'Gtk.EventControllerKey')[0], 'key-pressed', keyval, keyval, state);
  /** Picks an operation in the editor's kind palette. */
  const pickKind = (page, id) => {
    const menu = findAll(world, page, 'Gtk.MenuButton', (w, s) => s.props.get('tooltip-text') === 'Choose an operation')[0];
    menu.popup();
    click(findAll(world, prop(world, menu, 'popover'), 'Gtk.Button').find(b => prop(world, b, 'tooltip-text') === kindById(id).explanation));
  };

  await step('reads status.json, GNOME Shell\'s state, build-info.json and the running commit', async () => {
    check(rows.length === 10, `10 sections in the sidebar, found ${rows.length}`);
    check(model.status.session === 'abcd1234', 'status.json was read');
    check(model.shell.state === 'active', `shell state from D-Bus, got ${JSON.stringify(model.shell)}`);
    check(model.build?.commit === 'abc1234-dirty', 'build-info.json was read');
    check(model.runningCommit === 'abc1234', 'the running commit comes from the log');
    check(model.summary().title === 'A newer build is installed', `headline: ${model.summary().title}`);
  });

  await step('every section opens', async () => {
    for (const row of rows) {
      sidebar.select_row(row);
      check(settings.current === world.stateOf(row).expandos._slatedId, 'selecting a row shows its section');
    }
  });

  await step('the Overview offers the right action for a stale build', async () => {
    settings.showPane('overview');
    const primary = findAll(world, visible('overview'), 'Gtk.Button', (w, s) => (s.props.get('css-classes') ?? []).includes('suggested-action'))[0];
    check(primary && prop(world, primary, 'label') === 'Log Out…', `primary action: ${primary && prop(world, primary, 'label')}`);
    click(primary);
    await settle();
    check(shell.calls.includes('Logout'), 'asks the session manager to log out');
  });

  await step('Windows lists Slated\'s and the Slate file\'s bindings with states', async () => {
    settings.showPane('windows');
    const root = visible('windows');
    const all = rowsIn(root, (w, s) => (s.handlers.get('activated')?.size ?? 0) > 0);
    check(all.length >= 7 + 21, `binding rows: ${all.length}`);
    const typo = rowsIn(root, (w, s) => s.props.get('title') === 'Typo')[0];
    check((prop(world, typo, 'css-classes') ?? []).includes('slated-invalid'), 'the invalid binding is flagged');
  });

  await step('editing a binding: name, recorded keys (Hyper), modal key, repeat', async () => {
    settings.navigate('windows', {binding: ID.HALF});
    const page = visible('windows');
    check(world.stateOf(page).expandos._slatedKey === `binding:${ID.HALF}`, 'the editor is open');
    const name = titled(page, 'Adw.EntryRow', 'Name')[0];
    name.set_text('Left Half!');
    const recorderButton = findAll(world, page, 'Gtk.Button', (w, s) => (s.props.get('css-classes') ?? []).includes('slated-recorder'))[0];
    click(recorderButton);
    const controller = findAll(world, window, 'Gtk.EventControllerKey')[0];
    check(controller, 'recording attaches a key controller to the window');
    world.emit(controller, 'modifiers', Gdk.ModifierType.HYPER_MASK);
    world.emit(controller, 'key-pressed', 97, 97, Gdk.ModifierType.HYPER_MASK);
    check(model.binding(ID.HALF).keys === 'hyper+a', `recorded ${model.binding(ID.HALF).keys}`);
    check(findAll(world, window, 'Gtk.EventControllerKey').length === 0, 'recording stops after a key');
    // A key without Ctrl/Alt/Super is refused for a global shortcut.
    click(recorderButton);
    const again = findAll(world, window, 'Gtk.EventControllerKey')[0];
    world.emit(again, 'key-pressed', 49, 49, 0);
    check(model.binding(ID.HALF).keys === 'hyper+a', 'a bare key is refused');
    world.emit(again, 'key-pressed', 65307, 65307, 0);
    check(findAll(world, window, 'Gtk.EventControllerKey').length === 0, 'Escape cancels');
    // Where caps:hyper shares Super's modifier, GTK may report both masks, or only Super: the key held decides.
    const shared = Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.HYPER_MASK;
    click(recorderButton);
    let keysController = findAll(world, window, 'Gtk.EventControllerKey')[0];
    world.emit(keysController, 'key-pressed', 65515, 65515, 0);
    world.emit(keysController, 'key-pressed', 97, 97, shared);
    check(model.binding(ID.HALF).keys === 'cmd+a', `Super+A records as Super, not ✦: ${model.binding(ID.HALF).keys}`);
    click(recorderButton);
    keysController = findAll(world, window, 'Gtk.EventControllerKey')[0];
    world.emit(keysController, 'key-pressed', 65515, 65515, 0);
    world.emit(keysController, 'key-released', 65515, 65515, shared);
    world.emit(keysController, 'key-pressed', 65517, 65517, 0);
    world.emit(keysController, 'key-pressed', 97, 97, Gdk.ModifierType.SUPER_MASK);
    check(model.binding(ID.HALF).keys === 'hyper+a', `Caps Lock+A records as ✦: ${model.binding(ID.HALF).keys}`);
    const modal = titled(page, 'Adw.SwitchRow', 'Press a modal key first')[0];
    modal.set_active(true);
    check(model.binding(ID.HALF).modal?.keys === 'ctrl+f4', 'modal key added');
    modal.set_active(false);
    const repeat = titled(page, 'Adw.ComboRow', 'Repeat while held')[0];
    repeat.set_selected(1);
    check(model.binding(ID.HALF).repeats === true, 'repeat while held');
    repeat.set_selected(0);
    check(model.binding(ID.HALF).repeats === undefined, 'default repeat');
    await settle();
    const saved = decodeConfiguration(fs.readFileSync(files.configFile, 'utf8'));
    check(saved.bindings.find(b => b.id === ID.HALF).name === 'Left Half!', 'saved to config.json after the pause');
    check(saved.clipboard.maxItems === 42 && saved.clipboard.shortcut === null && saved.automation.showIndicator === false,
      'the clipboard and automation sections were kept');
    check(saved.island.enabled === false && saved.island.cheatSheetDelay === 0.8 && saved.island.cheatSheet === true,
      'the Mac island section was kept');
  });

  await step('the action editor: every kind, its parameters, presets', async () => {
    const page = visible('windows');
    const pickerMenus = () => findAll(world, page, 'Gtk.MenuButton', (w, s) => s.props.get('tooltip-text') === 'Choose an operation');
    const kindIds = new Set();
    for (let round = 0; round < 40; round++) {
      const menu = pickerMenus()[0];
      menu.popup();
      const buttons = findAll(world, prop(world, menu, 'popover'), 'Gtk.Button');
      const next = buttons.find(b => !kindIds.has(prop(world, b, 'tooltip-text')) && prop(world, b, 'sensitive') !== false);
      if (!next) break;
      kindIds.add(prop(world, next, 'tooltip-text'));
      click(next);
      await settle();
      // Poke the parameter rows.
      for (const s of findAll(world, page, 'Adw.SwitchRow')) {
        if (prop(world, s, 'title') === 'Press a modal key first') continue;
        s.set_active(!s.get_active());
        s.set_active(!s.get_active());
      }
      for (const entry of findAll(world, page, 'Gtk.Entry', (w, st) => (st.props.get('css-classes') ?? []).includes('slated-mono'))) {
        const before = entry.get_text();
        entry.set_text('screenSizeX/4');
        entry.set_text('nope(');
        entry.set_text(before);
      }
      for (const combo of findAll(world, page, 'Adw.ComboRow')) {
        if (prop(world, combo, 'title') === 'Repeat while held') continue;
        const n = world.stateOf(prop(world, combo, 'model'))?.items?.length ?? 0;
        for (let i = 0; i < Math.min(n, 4); i++) combo.set_selected(i);
      }
      await settle();
    }
    check(kindIds.size === 34, `tried ${kindIds.size} of 34 kinds`);
    // Back to a window placement, then every preset.
    const menu = pickerMenus()[0];
    menu.popup();
    click(findAll(world, prop(world, menu, 'popover'), 'Gtk.Button')[0]);
    const presets = findAll(world, page, 'Gtk.Button', (w, s) => (s.props.get('css-classes') ?? []).includes('slated-preset'));
    check(presets.length === 20, `20 presets, found ${presets.length}`);
    for (const p of presets) click(p);
    check(model.binding(ID.HALF).action.op === 'throw', 'the last preset (Next Display, Maximized) applied');
  });

  await step('chains and by-orientation open nested editors', async () => {
    pop('windows');
    settings.navigate('windows', {binding: ID.CHAIN});
    let page = visible('windows');
    const step2 = rowsIn(page, (w, s) => String(s.props.get('title')).startsWith('Press 2'))[0];
    activate(step2);
    const nested = visible('windows');
    check(nested !== page, 'a step opens its own page');
    const entries = findAll(world, nested, 'Gtk.Entry', (w, s) => (s.props.get('css-classes') ?? []).includes('slated-mono'));
    entries[2].set_text('screenSizeX/5');
    check(model.binding(ID.CHAIN).action.operations[1].width === 'screenSizeX/5', 'nested edits reach the chain');
    pop('windows');
    // Remove the step from its menu: the list updates.
    page = visible('windows');
    const remove = findAll(world, page, 'Gtk.Button', (w, s) => s.props.get('label') === 'Remove')[1];
    click(remove);
    check(model.binding(ID.CHAIN).action.operations.length === 1, 'step removed');
    pop('windows');
    settings.navigate('windows', {binding: ID.ORIENT});
    page = visible('windows');
    const portrait = rowsIn(page, (w, s) => s.props.get('title') === 'Portrait displays')[0];
    activate(portrait);
    const branch = visible('windows');
    const presets = findAll(world, branch, 'Gtk.Button', (w, s) => (s.props.get('css-classes') ?? []).includes('slated-preset'));
    click(presets[2]);
    check(model.binding(ID.ORIENT).action.portrait.height === 'screenSizeY/2', 'the portrait branch took the Top Half preset');
    pop('windows');
    pop('windows');
  });

  await step('the Mouse & Keys editors: what repeats, how often, runs, humanizing, no repeat inside a repeat', async () => {
    settings.navigate('windows', {binding: ID.CLICKER});
    const page = visible('windows');
    const action = () => model.binding(ID.CLICKER).action;
    // An auto-clicker never touches a window: its editor shows no window preview.
    const previewGroups = findAll(world, page, 'Adw.PreferencesGroup', (w, s) => findAll(world, w, 'Gtk.Overlay',
      (o, os) => (os.props.get('css-classes') ?? []).includes('slated-preview')).length > 0);
    check(previewGroups.length === 1 && prop(world, previewGroups[0], 'visible') === false, 'no window preview for an auto-clicker');
    const what = titled(page, 'Adw.ComboRow', 'Repeat')[0];
    what.set_selected(1);
    check(action().action.op === 'keystroke' && action().action.keys === 'e', `repeats a key: ${JSON.stringify(action().action)}`);
    what.set_selected(0);
    check(action().action.op === 'click', 'back to a click');
    titled(page, 'Adw.SwitchRow', 'Double-click')[0].set_active(true);
    check(action().action.count === 2, 'double-clicks');
    titled(page, 'Adw.SwitchRow', 'Double-click')[0].set_active(false);
    click(buttons(page, '250 ms')[0]);
    check(action().interval === 0.25, `quick pick: ${action().interval}`);
    titled(page, 'Adw.SpinRow', 'Every')[0].set_value(50);
    check(action().interval === 0.05, `every 50 ms: ${action().interval}`);
    titled(page, 'Adw.SwitchRow', 'Stop after a number of runs')[0].set_active(true);
    check(action().times === 10, 'ten runs to start with');
    titled(page, 'Adw.SpinRow', 'Number of runs')[0].set_value(25);
    check(action().times === 25, 'then 25');
    titled(page, 'Adw.SwitchRow', 'Humanize timing')[0].set_active(true);
    check(action().jitter === 0.15, 'humanized ±15%');
    const runs = titled(page, 'Adw.ComboRow', 'Runs')[0];
    runs.set_selected(1);
    check(action().mode === 'while-held', 'while held');
    check(/key repeat/.test(prop(world, runs, 'subtitle')), `explains GNOME's key repeat: ${prop(world, runs, 'subtitle')}`);
    // Anything else repeats from its own page, where an auto-repeat isn't offered.
    activate(rowsIn(page, (w, s) => s.props.get('title') === 'Something else')[0]);
    const nested = visible('windows');
    check(nested !== page, 'what repeats opens its own page');
    const menu = findAll(world, nested, 'Gtk.MenuButton', (w, s) => s.props.get('tooltip-text') === 'Choose an operation')[0];
    menu.popup();
    const kinds = findAll(world, prop(world, menu, 'popover'), 'Gtk.Button');
    const kindButton = id => kinds.find(b => prop(world, b, 'tooltip-text') === kindById(id).explanation);
    check(prop(world, kindButton('repeat'), 'sensitive') === false, 'no repeat inside a repeat');
    click(kindButton('hold'));
    check(action().action.op === 'hold', `now holds: ${JSON.stringify(action().action)}`);
    // Hold a key: from the menu, a modifier key on its own (the recorder can't take one).
    const input = titled(nested, 'Adw.ComboRow', 'Hold down')[0];
    input.set_selected(3);
    check(action().action.input === 'key:w', `a key: ${action().action.input}`);
    const keyMenu = findAll(world, nested, 'Gtk.MenuButton', (w, s) => String(s.props.get('tooltip-text')).startsWith('Common keys'))[0];
    keyMenu.popup();
    click(findAll(world, prop(world, keyMenu, 'popover'), 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === 'Use Shift')[0]);
    check(action().action.input === 'key:shift', `holds Shift: ${action().action.input}`);
    pop('windows');
    check(rowsIn(visible('windows'), (w, s) => s.props.get('title') === 'Hold Shift').length === 1, 'the row names what repeats');
    model.setBinding(ID.CLICKER, b => {
      b.action = {op: 'repeat', action: {op: 'click', button: 'left'}, interval: 0.1};
    });
    pop('windows');
  });

  await step('Works In: only in some apps, from the apps used lately; then a plain key records', async () => {
    settings.navigate('windows', {binding: ID.CLICKER});
    const page = visible('windows');
    check(titled(page, 'Adw.ActionRow', 'org.prismlauncher.PrismLauncher').length === 1, 'the app it works in is listed');
    const add = titled(page, 'Adw.EntryRow', 'Add an app id or window class')[0];
    const picker = findAll(world, add, 'Gtk.MenuButton')[0];
    picker.popup();
    const list = findAll(world, prop(world, picker, 'popover'), 'Gtk.ListBox')[0];
    const apps = findAll(world, list, 'Gtk.ListBoxRow', (w, s) => s.expandos._slatedApp);
    check(world.stateOf(apps[0]).expandos._slatedApp.id === 'steam_app_1086940', 'apps used lately come first');
    world.emit(list, 'row-activated', apps[0]);
    check(model.binding(ID.CLICKER).onlyInApps.includes('steam_app_1086940'), 'picked from the list');
    add.set_text('org.gnome.TextEditor.desktop');
    world.emit(add, 'apply');
    check(model.binding(ID.CLICKER).onlyInApps.length === 3, 'typed in by id');
    const editorRow = titled(page, 'Adw.ActionRow', 'Text Editor')[0];
    click(findAll(world, editorRow, 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === 'Remove')[0]);
    check(!model.binding(ID.CLICKER).onlyInApps.includes('org.gnome.TextEditor.desktop'), 'removed again');
    // Limited to apps, a plain key is fine.
    const recorderButton = findAll(world, page, 'Gtk.Button', (w, s) => (s.props.get('css-classes') ?? []).includes('slated-recorder'))[0];
    click(recorderButton);
    world.emit(findAll(world, window, 'Gtk.EventControllerKey')[0], 'key-pressed', 97, 97, 0);
    check(model.binding(ID.CLICKER).keys === 'a', `a plain key: ${model.binding(ID.CLICKER).keys}`);
    titled(page, 'Adw.ComboRow', 'Works in')[0].set_selected(0);
    check(model.binding(ID.CLICKER).onlyInApps === undefined, 'everywhere again');
    const keysRow = titled(page, 'Adw.ActionRow', 'Keys')[0];
    check(/takes over typing A everywhere/.test(prop(world, keysRow, 'subtitle')), `then it warns about typing: ${prop(world, keysRow, 'subtitle')}`);
    model.setBinding(ID.CLICKER, b => {
      b.keys = 'f';
      b.onlyInApps = ['org.prismlauncher.PrismLauncher'];
    });
    click(buttons(page, 'Safety Settings')[0]);
    check(settings.current === 'automation', 'the safety note leads to the safety settings');
    settings.showPane('windows');
    pop('windows');
  });

  await step('a mouse-button shortcut says GNOME can\'t use it, with the keyd hint', async () => {
    settings.navigate('windows', {binding: ID.MOUSE});
    const page = visible('windows');
    check(findAll(world, page, 'Gtk.Label', (w, s) => /keyd \(for example mouse1 = f13\)/.test(String(s.props.get('label')))).length >= 1,
      'the keyd hint is on the page');
    pop('windows');
  });

  await step('the Mouse & Keys editors: recorded inputs, keys to repeat, waits, and where stopping is set up', async () => {
    settings.navigate('windows', {binding: ID.MOUSE});
    let page = visible('windows');
    const action = () => model.binding(ID.MOUSE).action;
    titled(page, 'Adw.ComboRow', 'Hold down')[0].set_selected(3);
    click(recorderIn(titled(page, 'Adw.ActionRow', 'Key')[0]));
    press(97);
    check(action().input === 'key:a', `holds a recorded key: ${action().input}`);
    // An auto-repeat that presses a key: recorded, or picked from the menu (which has no modifier keys).
    pickKind(page, 'repeat');
    titled(page, 'Adw.ComboRow', 'Repeat')[0].set_selected(1);
    const keyRow = titled(page, 'Adw.ActionRow', 'Key')[0];
    click(recorderIn(keyRow));
    press(49);
    check(action().action.keys === '1', `repeats 1: ${JSON.stringify(action().action)}`);
    const menu = findAll(world, keyRow, 'Gtk.MenuButton')[0];
    check(prop(world, menu, 'tooltip-text') === 'Common keys', 'a key to repeat is never a modifier on its own');
    menu.popup();
    click(findAll(world, prop(world, menu, 'popover'), 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === 'Use Space')[0]);
    check(action().action.keys === 'space', `repeats Space: ${JSON.stringify(action().action)}`);
    titled(page, 'Adw.SwitchRow', 'Humanize timing')[0].set_active(true);
    titled(page, 'Adw.SpinRow', 'Vary each interval by up to')[0].set_value(30);
    check(action().jitter === 0.3, `±30%: ${action().jitter}`);
    const runs = titled(page, 'Adw.ComboRow', 'Runs')[0];
    runs.set_selected(1);
    check(/works like a toggle/.test(prop(world, runs, 'subtitle')), `a repeat that presses keys can't be while-held on GNOME: ${prop(world, runs, 'subtitle')}`);
    pickKind(page, 'wait');
    titled(page, 'Adw.SpinRow', 'Seconds')[0].set_value(1.25);
    check(action().seconds === 1.25, `waits 1.25 s: ${action().seconds}`);
    click(buttons(page, '2 s')[0]);
    check(action().seconds === 2, 'a quick pick');
    check(model.issuesFor(`binding:${ID.MOUSE}`).some(i => /A wait on its own does nothing/.test(i.message)), 'a lone wait is pointless');
    pickKind(page, 'stop-automations');
    click(buttons(page, 'Automation Settings')[0]);
    check(settings.current === 'automation', 'Stop Automations points at the stop shortcut\'s settings');
    settings.navigate('windows', {binding: ID.MOUSE});
    page = visible('windows');
    pickKind(page, 'clipboard-history');
    click(buttons(page, 'Clipboard Settings')[0]);
    check(settings.current === 'clipboard', 'Clipboard History points at its settings');
    model.setBinding(ID.MOUSE, b => {
      b.action = {op: 'hold', input: 'mouse:right'};
    });
    settings.showPane('windows');
    pop('windows');
  });

  await step('read-only Slate bindings show what their function does, and copy into Slated', async () => {
    const root = visible('windows');
    const source = rowsIn(root, (w, s) => s.props.get('title') === 'JavaScript Function')[0];
    activate(source);
    const page = visible('windows');
    const copy = findAll(world, page, 'Gtk.Button', (w, s) => s.props.get('label') === 'Copy into Slated')[0];
    const before = model.configuration.bindings.length;
    click(copy);
    check(model.configuration.bindings.length === before + 1, 'copied');
    pop('windows');
  });

  await step('new shortcuts start recording; delete asks first', async () => {
    settings.navigate('windows', {newBinding: true});
    const page = visible('windows');
    check(findAll(world, window, 'Gtk.EventControllerKey').length === 1, 'recording right away');
    world.emit(findAll(world, window, 'Gtk.EventControllerKey')[0], 'key-pressed', 65307, 65307, 0);
    const id = world.stateOf(page).expandos._slatedKey.split(':')[1];
    const del = findAll(world, page, 'Gtk.Button', (w, s) => s.props.get('label') === 'Delete…')[0];
    click(del);
    const dialog = world.report.dialogs[world.report.dialogs.length - 1];
    world.emit(dialog, 'response', 'accept');
    check(!model.binding(id), 'deleted');
    check(visible('windows') !== page, 'the editor closed');
  });

  await step('switching sections stops a recording: the keys typed there aren\'t taken as a shortcut', async () => {
    const controllers = () => findAll(world, window, 'Gtk.EventControllerKey');
    const selectSection = id => sidebar.select_row(rows.find(r => world.stateOf(r).expandos._slatedId === id));
    settings.navigate('windows', {binding: ID.HALF});
    const before = model.binding(ID.HALF).keys;
    click(recorderIn(visible('windows')));
    check(controllers().length === 1, 'recording');
    // The editor stays on top of its section's own navigation, so it never gets "hidden".
    selectSection('hotstrings');
    check(controllers().length === 0, 'the window no longer captures every key once another section shows');
    check(model.binding(ID.HALF).keys === before, 'the shortcut is unchanged');
    selectSection('windows');
    pop('windows');
    settings.showPane('clipboard');
    click(recorderIn(titled(visible('clipboard'), 'Adw.ActionRow', 'Open the switcher')[0]));
    check(controllers().length === 1, 'recording the clipboard shortcut');
    selectSection('general');
    check(controllers().length === 0, 'stopped when General shows');
    // In a narrow window the sidebar replaces the content (the split view hides its content page).
    selectSection('clipboard');
    click(recorderIn(titled(visible('clipboard'), 'Adw.ActionRow', 'Open the switcher')[0]));
    world.emit(settings.contentPage, 'hidden');
    check(controllers().length === 0, 'stopped when the collapsed sidebar shows');
  });

  await step('Hotstrings: espanso guidance, editing, the try-it field', async () => {
    settings.showPane('hotstrings');
    const root = visible('hotstrings');
    const install = findAll(world, root, 'Gtk.Button', (w, s) => s.props.get('label') === 'Install espanso')[0];
    check(prop(world, install, 'visible') !== false, 'install guidance when espanso is missing');
    activate(rowsIn(root, (w, s) => (s.handlers.get('activated')?.size ?? 0) > 0)[0]);
    const page = visible('hotstrings');
    const tryEntry = findAll(world, page, 'Gtk.Entry').find(e => !findAll(world, page, 'Adw.EntryRow').includes(e));
    tryEntry.set_text(';');
    tryEntry.set_text(';s');
    check(tryEntry.get_text() === '¯\\_(ツ)_/¯', `the try-it field expanded: ${tryEntry.get_text()}`);
    const scope = titled(page, 'Adw.ComboRow', 'Expands')[0];
    scope.set_selected(1);
    const add = titled(page, 'Adw.EntryRow', 'Add a Mac app (bundle identifier)')[0];
    add.set_text('com.apple.mail');
    world.emit(add, 'apply');
    check(model.hotstring(ID.SHRUG).onlyInApps.includes('com.apple.mail'), 'app filter added');
    const where = findAll(world, page, 'Adw.PreferencesGroup', (w, s) => s.props.get('title') === 'Where It Works')[0];
    check(/Mac only/.test(prop(world, where, 'description') ?? ''), 'says app filters are Mac only on GNOME');
    const trigger = titled(page, 'Adw.EntryRow', 'Trigger')[0];
    trigger.set_text('');
    check(model.issues.some(i => i.target === `hotstring:${ID.SHRUG}` && i.severity === 'error'), 'an empty trigger is an error');
    trigger.set_text(';shrug');
    pop('hotstrings');
    const master = findAll(world, visible('hotstrings'), 'Gtk.Switch')[0];
    master.set_active(false);
    check(model.configuration.general.hotstringsEnabled === false, 'master switch');
    master.set_active(true);
  });

  await step('Layouts: edit a layout, add an app, preview', async () => {
    settings.showPane('layouts');
    activate(rowsIn(visible('layouts'), (w, s) => s.props.get('title') === 'Coding')[0]);
    const page = visible('layouts');
    const add = titled(page, 'Adw.EntryRow', 'Add an app by name')[0];
    add.set_text('Files');
    world.emit(add, 'apply');
    check(model.configuration.layouts[0].apps.length === 2, 'app added');
    const name = titled(page, 'Adw.EntryRow', 'Name')[0];
    name.set_text('Codin');
    check(visible('layouts') === page, 'the editor stays open while the name changes');
    name.set_text('Code');
    check(model.binding(ID.LAYOUT).action.name === 'Code', 'renaming keeps the shortcut pointing at it');
    check(visible('layouts') === page && prop(world, page, 'title') === 'Code', 'still open, under the new name');
    pop('layouts');
  });

  await step('Slate Compatibility: import into Slated', async () => {
    settings.showPane('slate');
    const importButton = findAll(world, visible('slate'), 'Gtk.Button', (w, s) => s.props.get('label') === 'Import…')[0];
    const before = model.configuration.bindings.length;
    click(importButton);
    const dialog = world.report.dialogs[world.report.dialogs.length - 1];
    world.emit(dialog, 'response', 'import');
    check(model.configuration.bindings.length > before, 'bindings imported');
  });

  await step('Keyboard and General edit config.json', async () => {
    settings.showPane('keyboard');
    // keyd's config is root's: in keyd mode the page says to rerun the installer; GNOME's option can't do a tap.
    const statusText = fs.readFileSync(files.statusFile, 'utf8');
    const withHyperMode = mode => model.setStatusText(JSON.stringify({...JSON.parse(statusText), hyper: {wanted: true, mode, active: true}}));
    const escapeRow = () => titled(visible('keyboard'), 'Adw.SwitchRow', 'Tap Caps Lock alone for Escape')[0];
    const pills = text => findAll(world, visible('keyboard'), 'Gtk.Label', (w, s) => s.props.get('label') === text).length;
    withHyperMode('keyd');
    check(/linux\/install\.sh --hyper-keyd again/.test(prop(world, escapeRow(), 'subtitle')), `keyd: ${prop(world, escapeRow(), 'subtitle')}`);
    check(pills('Recommended') === 0 && pills('In use') === 1, 'keyd in use: no "Recommended" pill');
    withHyperMode('xkb');
    check(/Needs keyd/.test(prop(world, escapeRow(), 'subtitle')), `xkb: ${prop(world, escapeRow(), 'subtitle')}`);
    check(pills('Recommended') === 1, 'with GNOME\'s option in use, keyd is marked recommended');
    const sends = titled(visible('keyboard'), 'Adw.ComboRow', 'Hyper key sends')[0];
    check(/always sends the Hyper modifier/.test(prop(world, sends, 'subtitle')), `xkb: ${prop(world, sends, 'subtitle')}`);
    model.setStatusText(statusText);
    titled(visible('keyboard'), 'Adw.SwitchRow', 'Use Caps Lock as Hyper')[0].set_active(false);
    check(model.configuration.keyboard.capsLock === 'off', 'Caps Lock as Hyper off');
    settings.showPane('general');
    titled(visible('general'), 'Adw.SwitchRow', 'Show what just happened')[0].set_active(true);
    check(model.configuration.general.showActionHUD === true, 'HUD on');
    titled(visible('general'), 'Adw.SwitchRow', 'Slated is on')[0].set_active(false);
    await settle();
    check(shell.calls.includes('DisableExtension'), 'turns the extension off over D-Bus');
    for (const b of findAll(world, visible('general'), 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === 'Copy')) click(b);
    check(world.report.clipboard.length >= 2, 'commands copy to the clipboard');
    click(findAll(world, visible('general'), 'Gtk.Button', (w, s) => s.props.get('label') === 'Open Log')[0]);
    check(world.report.launches.some(l => l.file === files.logFile), 'Open Log launches the log');
  });

  await step('the preview steps through a chain and starts from a clicked display', async () => {
    settings.navigate('windows', {binding: ID.CHAIN});
    const page = visible('windows');
    const drawnBefore = world.report.drawn;
    const stepButton = tooltip => findAll(world, page, 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === tooltip)[0];
    click(stepButton('Next press'));
    click(stepButton('Previous press'));
    const caption = () => findAll(world, page, 'Gtk.Label', (w, s) => String(s.props.get('label')).startsWith('960 × 1048') ||
      String(s.props.get('label')).startsWith('540 × 1920'))[0];
    check(caption(), 'the caption describes where the window lands on the laptop display');
    const area = findAll(world, page, 'Gtk.DrawingArea', (w, s) => s.controllers.length > 0)[0];
    const gesture = world.stateOf(area).controllers[0];
    // Canvas point (240, 60) lies on the tall display in a 320 × 200 preview.
    world.emit(gesture, 'pressed', 1, 240, 60);
    check(prop(world, caption(), 'label').startsWith('540 × 1920'), `the window now starts on the tall display: ${prop(world, caption(), 'label')}`);
    check(world.report.drawn > drawnBefore, 'the preview redrew');
    pop('windows');
  });

  await step('Overview buttons go where they say', async () => {
    shell.state = 2; // turned off
    settings._refreshShell();
    await settle();
    settings.showPane('overview');
    const root = visible('overview');
    const enable = findAll(world, root, 'Gtk.Button', (w, s) => s.props.get('label') === 'Turn On Slated')[0];
    check(enable, 'offers to turn Slated on');
    click(enable);
    await settle();
    check(shell.calls.includes('EnableExtension'), 'turns it on over D-Bus');
    shell.state = 1;
    for (const label of ['Edit', 'Details']) {
      const b = findAll(world, root, 'Gtk.Button', (w, s) => s.props.get('label') === label)[0];
      click(b);
      settings.showPane('overview');
    }
    for (const row of rowsIn(root, (w, s) => (s.handlers.get('activated')?.size ?? 0) > 0)) {
      activate(row);
      settings.showPane('overview');
    }
  });

  await step('Windows search and starting from a preset', async () => {
    settings.showPane('windows');
    const root = visible('windows');
    const search = findAll(world, root, 'Gtk.SearchEntry')[0];
    search.set_text('cycle');
    const matches = rowsIn(root, (w, s) => (s.handlers.get('activated')?.size ?? 0) > 0);
    check(matches.length === 1, `one match for "cycle", got ${matches.length}`);
    search.set_text('zzzz');
    search.set_text('');
    const presetMenu = findAll(world, page(), 'Gtk.MenuButton', (w, s) => s.props.get('label') === 'From Preset')[0];
    function page() {
      return navOf('windows').get_visible_page();
    }
    const before = model.configuration.bindings.length;
    click(findAll(world, prop(world, presetMenu, 'popover'), 'Gtk.Button')[4]);
    check(model.configuration.bindings.length === before + 1, 'a binding from the preset');
    world.emit(findAll(world, window, 'Gtk.EventControllerKey')[0], 'key-pressed', 65307, 65307, 0);
    pop('windows');
    // The automation recipes are presets too.
    const recipeButtons = findAll(world, prop(world, presetMenu, 'popover'), 'Gtk.Button');
    click(recipeButtons[recipeButtons.length - 1]);
    const macro = model.configuration.bindings[model.configuration.bindings.length - 1];
    check(macro.name === 'Macro: Walk, Then Click' && macro.action.op === 'sequence', `the macro recipe: ${JSON.stringify(macro)}`);
    world.emit(findAll(world, window, 'Gtk.EventControllerKey')[0], 'key-pressed', 65307, 65307, 0);
    check(rowsIn(visible('windows'), (w, s) => String(s.props.get('title')).startsWith('Step 2 · Wait 2 s')).length === 1, 'its steps are listed');
    check(findAll(world, visible('windows'), 'Gtk.CheckButton', (w, s) => s.props.get('label') === 'Same window').length === 0,
      '"same window" isn\'t offered for clicks, keys and waits');
    pop('windows');
    const automations = findAll(world, visible('windows'), 'Adw.PreferencesGroup', (w, s) => s.props.get('title') === 'Automation')[0];
    check(rowsIn(automations, (w, s) => s.props.get('title') === 'Macro: Walk, Then Click').length === 1, 'listed with the automations');
  });

  await step('Slate Compatibility: reload, paths, loading switch', async () => {
    settings.showPane('slate');
    const root = visible('slate');
    click(buttons(root, 'Add Path')[0]);
    check(model.configuration.general.slateConfigPaths.length === 3, 'a path added');
    const field = titled(visible('slate'), 'Adw.EntryRow', 'File 3')[0];
    field.set_text('~/.slate.extra.js');
    check(model.configuration.general.slateConfigPaths[2] === '~/.slate.extra.js', 'path edited');
    click(buttons(visible('slate'), 'Restore Defaults')[0]);
    check(model.configuration.general.slateConfigPaths.length === 2, 'defaults restored');
    click(buttons(visible('slate'), 'Reload')[0]);
    check(world.report.toasts.includes('Reloaded config.json and your Slate files'), 'reload confirms');
    titled(visible('slate'), 'Adw.SwitchRow', 'Load Slate config files')[0].set_active(false);
    check(model.configuration.general.loadSlateConfigs === false, 'Slate files off');
    titled(visible('slate'), 'Adw.SwitchRow', 'Load Slate config files')[0].set_active(true);
  });

  await step('General: open, show and reload the configuration', async () => {
    settings.showPane('general');
    const root = visible('general');
    for (const label of ['Open', 'Show in Files']) {
      for (const b of findAll(world, root, 'Gtk.Button', (w, s) => s.props.get('label') === label)) click(b);
    }
    check(world.report.launches.some(l => l.file === files.configFile && !l.folder), 'opens config.json');
    check(world.report.launches.some(l => l.file === files.configFile && l.folder), 'shows config.json in Files');
    click(findAll(world, root, 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === 'Reload config.json and your Slate files')[0]);
    await settle();
    check(world.report.toasts.includes('Configuration reloaded'), 'reload confirms');
  });

  await step('Hotstrings: new, duplicate and delete', async () => {
    settings.showPane('hotstrings');
    const before = model.configuration.hotstrings.length;
    settings.navigate('hotstrings', {newHotstring: true});
    check(model.configuration.hotstrings.length === before + 1, 'new hotstring');
    titled(visible('hotstrings'), 'Adw.EntryRow', 'Trigger')[0].set_text(';new');
    click(findAll(world, visible('hotstrings'), 'Gtk.Button', (w, s) => s.props.get('label') === 'Duplicate')[0]);
    check(model.configuration.hotstrings.some(h => h.trigger === ';new2'), 'duplicated');
    click(findAll(world, visible('hotstrings'), 'Gtk.Button', (w, s) => s.props.get('label') === 'Delete…')[0]);
    world.emit(world.report.dialogs[world.report.dialogs.length - 1], 'response', 'accept');
    check(!model.configuration.hotstrings.some(h => h.trigger === ';new2'), 'deleted');
    pop('hotstrings');
  });

  await step('Layouts: new layout, app options, remove app, delete', async () => {
    settings.showPane('layouts');
    click(findAll(world, visible('layouts'), 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === 'New Layout')[0]);
    const page = visible('layouts');
    const add = titled(page, 'Adw.EntryRow', 'Add an app by name')[0];
    add.set_text('Terminal');
    world.emit(add, 'apply');
    const layout = () => model.configuration.layouts.find(l => l.name === 'New Layout');
    check(layout().apps.length === 1, 'app added');
    titled(visible('layouts'), 'Adw.SwitchRow', 'Repeat the operations for extra windows')[0].set_active(true);
    check(layout().apps[0].options.repeat === true, 'option set');
    // The app's own Remove button (operation menus have flat "Remove" items too).
    click(buttons(visible('layouts'), 'Remove').filter(b => !(prop(world, b, 'css-classes') ?? []).includes('flat'))[0]);
    check(layout().apps.length === 0, 'app removed');
    click(findAll(world, visible('layouts'), 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === 'Delete Layout')[0]);
    world.emit(world.report.dialogs[world.report.dialogs.length - 1], 'response', 'accept');
    check(!layout(), 'layout deleted');
  });

  await step('typing another layout\'s name over a layout\'s name moves no shortcut', async () => {
    settings.showPane('layouts');
    const taken = model.binding(ID.LAYOUT).action.name;
    click(findAll(world, visible('layouts'), 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === 'New Layout')[0]);
    const page = visible('layouts');
    const id = model.addBinding({op: 'layout', name: 'New Layout'}, {keys: 'hyper+9'});
    const name = titled(page, 'Adw.EntryRow', 'Name')[0];
    const problem = titled(page, 'Adw.ActionRow', 'Not saved')[0];
    // Select all and start typing "<taken> 2": the name passes through the other layout's.
    name.set_text(taken);
    check(prop(world, problem, 'visible') !== false && prop(world, problem, 'subtitle') === 'Another layout already has this name.',
      `flagged: ${prop(world, problem, 'subtitle')}`);
    check(model.binding(id).action.name === 'New Layout', `its shortcut stays: ${model.binding(id).action.name}`);
    check(model.configuration.layouts.filter(l => l.name === taken).length === 1, 'no two layouts share a name');
    await settle();
    const onDisk = decodeConfiguration(fs.readFileSync(files.configFile, 'utf8'));
    check(onDisk.bindings.find(b => b.id === id).action.name === 'New Layout', 'nor on disk');
    check(name.get_text() === taken, 'the field keeps what was typed');
    name.set_text(`${taken} 2`);
    check(visible('layouts') === page, 'the editor stays open');
    check(prop(world, problem, 'visible') === false, 'fine again');
    check(model.binding(id).action.name === `${taken} 2` && model.binding(ID.LAYOUT).action.name === taken,
      'each shortcut applies its own layout');
    check(model.configuration.layouts.some(l => l.name === `${taken} 2` && !l.apps.length), 'the layout being edited got the name');
    model.deleteBinding(id);
    model.deleteLayout(`${taken} 2`);
  });

  await step('Automation: running now, your automations, recipes and the safety settings', async () => {
    settings.showPane('automation');
    const root = visible('automation');
    check(rowsIn(root, (w, s) => s.props.get('title') === 'Repeat click left every 100 ms').length === 1, 'running now, from status.json');
    const mine = rowsIn(root, (w, s) => s.props.get('title') === 'Auto-clicker')[0];
    check(mine, 'your automations list the auto-clicker');
    check(findAll(world, mine, 'Gtk.Label', (w, s) => s.props.get('label') === 'Running').length === 1, 'marked as running');
    check(/Only in org\.prismlauncher\.PrismLauncher/.test(prop(world, mine, 'subtitle')), `where it works: ${prop(world, mine, 'subtitle')}`);
    findAll(world, mine, 'Gtk.Switch')[0].set_active(false);
    check(model.binding(ID.CLICKER).enabled === false, 'turned off from the list');
    const again = rowsIn(visible('automation'), (w, s) => s.props.get('title') === 'Auto-clicker')[0];
    findAll(world, again, 'Gtk.Switch')[0].set_active(true);
    check(model.binding(ID.CLICKER).enabled === true, 'and on');
    activate(rowsIn(visible('automation'), (w, s) => s.props.get('title') === 'Auto-clicker')[0]);
    check(world.stateOf(visible('automation')).expandos._slatedKey === `binding:${ID.CLICKER}`, 'its editor opens in place');
    pop('automation');
    click(buttons(visible('automation'), 'New Automation')[0]);
    check(findAll(world, window, 'Gtk.EventControllerKey').length === 1, 'a new automation records its shortcut');
    press(65307);
    pop('automation');
    const before = model.configuration.bindings.length;
    const sprint = rowsIn(root, (w, s) => s.props.get('title') === 'Toggle Sprint (Shift)')[0];
    click(buttons(sprint, 'Add')[0]);
    check(model.configuration.bindings.length === before + 1, 'the recipe added a binding');
    const added = model.configuration.bindings[model.configuration.bindings.length - 1];
    check(added.name === 'Toggle Sprint (Shift)' && added.action.input === 'key:shift', JSON.stringify(added));
    const controller = findAll(world, window, 'Gtk.EventControllerKey')[0];
    check(controller, 'its editor records the shortcut right away');
    world.emit(controller, 'key-pressed', 65475, 65475, 0);
    check(model.binding(added.id).keys === 'f6', `recorded ${model.binding(added.id).keys}`);
    check(findAll(world, visible('automation'), 'Gtk.Label', (w, s) => /^✦ Esc stops everything · stops when you switch apps\./.test(String(s.props.get('label')))).length === 1,
      'the editor shows the safety rails');
    pop('automation');
    const recipes = findAll(world, visible('automation'), 'Adw.PreferencesGroup', (w, s) => s.props.get('title') === 'Recipes')[0];
    const done = rowsIn(recipes, (w, s) => s.props.get('title') === 'Toggle Sprint (Shift)')[0];
    check(buttons(done, 'Edit').length === 1, 'a recipe already set up offers Edit');
    const page = visible('automation');
    titled(page, 'Adw.SwitchRow', 'Stop when you switch apps')[0].set_active(false);
    check(model.configuration.automation.stopOnAppSwitch === false, 'stop on app switch off');
    titled(page, 'Adw.ComboRow', 'Time limit')[0].set_selected(2);
    check(model.configuration.automation.maxRunMinutes === 5, `time limit: ${model.configuration.automation.maxRunMinutes}`);
    titled(page, 'Adw.SwitchRow', 'Show an indicator')[0].set_active(true);
    check(model.configuration.automation.showIndicator === true, 'indicator on');
    const stopRow = titled(page, 'Adw.ActionRow', 'Stop shortcut')[0];
    click(findAll(world, stopRow, 'Gtk.Button', (w, s) => (s.props.get('css-classes') ?? []).includes('slated-recorder'))[0]);
    world.emit(findAll(world, window, 'Gtk.EventControllerKey')[0], 'key-pressed', 65288, 65288, 0);
    check(model.configuration.automation.stopShortcut === null, 'Backspace clears the stop shortcut');
    check(findAll(world, page, 'Gtk.Label', (w, s) => s.props.get('label') === 'No stop shortcut').some(l => prop(world, l, 'visible') !== false),
      'and the page says there is none');
    click(buttons(stopRow, 'Default')[0]);
    check(model.configuration.automation.stopShortcut === 'hyper+esc', 'the default again');
    activate(rowsIn(page, (w, s) => s.props.get('title') === 'Build Your Own')[0]);
    world.emit(findAll(world, window, 'Gtk.EventControllerKey')[0], 'key-pressed', 65307, 65307, 0);
    const own = model.configuration.bindings[model.configuration.bindings.length - 1];
    check(own.action.op === 'repeat' && !own.keys, 'build your own starts from an auto-clicker, waiting for its keys');
    const suggestion = findAll(world, titled(visible('automation'), 'Adw.ActionRow', 'Suggested')[0], 'Gtk.Button')[0];
    check(prop(world, suggestion, 'tooltip-text') === 'Use F7', `a free function key is suggested: ${prop(world, suggestion, 'tooltip-text')}`);
    click(suggestion);
    check(model.binding(own.id).keys === 'f7', 'one click takes it');
    pop('automation');
    await settle();
    const saved = decodeConfiguration(fs.readFileSync(files.configFile, 'utf8'));
    check(saved.automation.maxRunMinutes === 5 && saved.automation.stopOnAppSwitch === false, 'saved to config.json');
  });

  await step('Clipboard: the switch, the shortcut, history choices and excluded apps', async () => {
    settings.showPane('clipboard');
    const root = visible('clipboard');
    check(rowsIn(root, (w, s) => s.props.get('title') === 'Saved' && /12 items/.test(String(s.props.get('subtitle')))).length === 1, 'the item count from status.json');
    const remember = titled(root, 'Adw.ComboRow', 'Remember up to')[0];
    const labels = world.stateOf(prop(world, remember, 'model')).items;
    check(labels.includes('42 items'), `a hand-edited size is a choice of its own: ${labels.join(', ')}`);
    remember.set_selected(labels.indexOf('200 items'));
    check(model.configuration.clipboard.maxItems === 200, 'remember 200');
    titled(root, 'Adw.ComboRow', 'Forget items after')[0].set_selected(4);
    check(model.configuration.clipboard.retentionDays === 0, 'forever');
    titled(root, 'Adw.SwitchRow', 'Keep history across restarts')[0].set_active(false);
    check(model.configuration.clipboard.persist === false, 'not kept across restarts');
    titled(root, 'Adw.SwitchRow', 'Paste after picking')[0].set_active(false);
    check(model.configuration.clipboard.pasteAfterSelecting === false, 'only copies');
    titled(root, 'Adw.SwitchRow', 'Ignore passwords and other secrets')[0].set_active(false);
    check(model.configuration.clipboard.ignoreConcealed === false, 'records secrets (why would you)');
    titled(root, 'Adw.SwitchRow', 'Ignore passwords and other secrets')[0].set_active(true);
    const shortcutRow = titled(root, 'Adw.ActionRow', 'Open the switcher')[0];
    click(buttons(shortcutRow, 'Default')[0]);
    check(model.configuration.clipboard.shortcut === 'shift+cmd+v', 'the default shortcut again');
    click(recorderIn(shortcutRow));
    press(118, Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK);
    check(model.configuration.clipboard.shortcut === 'ctrl+alt+v', `recorded: ${model.configuration.clipboard.shortcut}`);
    const add = titled(root, 'Adw.EntryRow', 'Add an app id')[0];
    const picker = findAll(world, add, 'Gtk.MenuButton')[0];
    picker.popup();
    const list = findAll(world, prop(world, picker, 'popover'), 'Gtk.ListBox')[0];
    const first = findAll(world, list, 'Gtk.ListBoxRow', (w, s) => s.expandos._slatedApp)[0];
    check(world.stateOf(first).expandos._slatedApp.id === 'org.keepassxc.KeePassXC', 'password managers come first');
    world.emit(list, 'row-activated', first);
    check(model.configuration.clipboard.excludedApps.includes('org.keepassxc.KeePassXC'), 'excluded');
    add.set_text('com.example.Vault');
    world.emit(add, 'apply');
    check(model.configuration.clipboard.excludedApps.includes('com.example.Vault'), 'typed in by id');
    const keepass = titled(visible('clipboard'), 'Adw.ActionRow', 'KeePassXC')[0];
    check(keepass, 'listed by name');
    click(findAll(world, keepass, 'Gtk.Button', (w, s) => s.props.get('tooltip-text') === 'Remove')[0]);
    check(!model.configuration.clipboard.excludedApps.includes('org.keepassxc.KeePassXC'), 'removed again');
    check(titled(visible('clipboard'), 'Adw.ActionRow', 'Keychain Access (Mac)').length === 1, 'the Mac\'s password managers are named');
    const toggle = findAll(world, root, 'Gtk.Switch', (w, s) => s.props.get('tooltip-text') === 'Turn clipboard history on or off')[0];
    toggle.set_active(false);
    check(model.configuration.clipboard.enabled === false, 'off');
    settings._syncChrome();
    const badge = findAll(world, sidebar, 'Gtk.Label', (w, s) => (s.props.get('css-classes') ?? []).includes('slated-badge') && s.props.get('label') === 'Off');
    check(badge.length === 1, 'the sidebar says it\'s off');
    toggle.set_active(true);
    await settle();
    const saved = decodeConfiguration(fs.readFileSync(files.configFile, 'utf8'));
    check(saved.clipboard.maxItems === 200 && saved.clipboard.persist === false && saved.clipboard.enabled, 'saved to config.json');
    const events = fs.readFileSync(files.logFile, 'utf8').trim().split('\n').map(line => JSON.parse(line));
    const changes = events.filter(e => e.event === 'config.saved').flatMap(e => e.data.changes);
    check(changes.some(c => c.startsWith('clipboard: ')) && changes.some(c => c.startsWith('automation: ')), 'the log has the settings changes');
    check(events.some(e => e.event === 'ui.recipe_added' && e.data.recipe === 'toggle-sprint'), 'and the recipe');
  });

  await step('hand edits and status changes on disk are picked up', async () => {
    await settle();
    const text = fs.readFileSync(files.configFile, 'utf8');
    const config = JSON.parse(text);
    config.general.showActionHUD = false;
    fs.writeFileSync(files.configFile, JSON.stringify(config));
    world.touch(files.configFile);
    await settle();
    check(model.configuration.general.showActionHUD === false, 'hand edit adopted');
    fs.writeFileSync(files.statusFile, JSON.stringify({running: false}));
    world.touch(files.statusFile);
    await settle();
    check(!model.status.running, 'status change adopted');
  });

  await step('the About dialog has debug information', async () => {
    settings.showPane('about');
    activate(rowsIn(visible('about'), (w, s) => s.props.get('title') === 'Credits, links and debug information')[0]);
    const dialog = world.report.dialogs[world.report.dialogs.length - 1];
    check(String(prop(world, dialog, 'debug-info')).includes('abc1234-dirty'), 'debug info names the build');
  });

  await step('closing saves, logs and stops watching', async () => {
    model.update(config => {
      config.general.showActionHUD = true;
    });
    window.close();
    check(settings.closed, 'closed');
    check(world.monitors.every(m => m.cancelled), 'file monitors cancelled');
    const saved = decodeConfiguration(fs.readFileSync(files.configFile, 'utf8'));
    check(saved.general.showActionHUD === true, 'the pending edit was saved on close');
    const events = fs.readFileSync(files.logFile, 'utf8').trim().split('\n').map(line => JSON.parse(line));
    const names = new Set(events.map(e => e.event));
    for (const name of ['ui.settings_opened', 'ui.pane', 'config.saved', 'slate.imported', 'ui.settings_closed']) {
      check(names.has(name), `the log has ${name}`);
    }
    const opened = events.find(e => e.event === 'ui.settings_opened');
    const closed = events.find(e => e.event === 'ui.settings_closed');
    check(opened.session === 'abcd1234', 'while the extension runs, the preferences log under its session');
    check(/^[0-9a-f]{8}$/.test(closed.session) && closed.session !== 'abcd1234', 'without a running extension, under their own session');
  });

  await step('rows show text as typed: none parses markup', async () => {
    // libadwaita rows parse Pango markup by default, so a name like "Left & Right" or a Slate error
    // mentioning '<' would come out blank. Every row is built with use_markup: false.
    check(world.report.markupRows.length === 0, `rows with markup on: ${[...new Set(world.report.markupRows)].join(', ')}`);
  });

  await step('only unavoidable deprecated API is used', async () => {
    const unexpected = [...world.report.deprecated].filter(d => !ALLOWED_DEPRECATIONS.has(d));
    check(!unexpected.length, `deprecated API: ${unexpected.join(', ')}`);
  });

  fs.rmSync(files.home, {recursive: true, force: true});
}

/** The mocks must reject what they claim to catch, or a green run means nothing. */
function selfTest() {
  console.log('Mock GTK and libadwaita reject API mistakes');
  const rejects = (what, fn, pattern) => {
    try {
      fn();
    } catch (error) {
      if (!(error instanceof MockError) || (pattern && !pattern.test(error.message))) {
        fail(what, error);
        return;
      }
      pass(what);
      return;
    }
    fail(what, new Error('did not throw'));
  };
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'slated-prefs-mock-'));
  for (const mode of ['min', 'new']) {
    const world = createWorld({api, home, mode});
    const {Gtk, Adw, Gdk} = world.namespaces;
    const tag = `(${mode})`;
    rejects(`unknown method ${tag}`, () => new Gtk.Box().append_child(new Gtk.Label()), /no method or property "append_child"/);
    rejects(`unknown constructor property ${tag}`, () => new Gtk.Label({lable: 'x'}), /no property "lable"/);
    rejects(`unknown class ${tag}`, () => Adw.PreferencesRowGroup, /doesn't exist/);
    rejects(`unknown enum member ${tag}`, () => Gtk.Align.MIDDLE, /no member MIDDLE/);
    rejects(`unknown signal ${tag}`, () => new Gtk.Button().connect('click', () => {}), /no signal "click"/);
    rejects(`notify:: on a missing property ${tag}`, () => new Gtk.Switch().connect('notify::checked', () => {}), /no property "checked"/);
    rejects(`too few arguments ${tag}`, () => new Adw.AlertDialog().present(), /Too few arguments/);
    rejects(`removing a widget that isn't a child ${tag}`, () => new Gtk.Box().remove(new Gtk.Label()), /isn't a child/);
    rejects(`adding a widget that already has a parent ${tag}`, () => {
      const label = new Gtk.Label();
      new Gtk.Box().append(label);
      new Gtk.Box().append(label);
    }, /already inside/);
    rejects(`read-only properties ${tag}`, () => {
      new Adw.NavigationView().visible_page = null;
    }, /read-only/);
    rejects(`construct-only properties after construction ${tag}`, () => {
      new Gtk.KeyvalTrigger({keyval: 97}).keyval = 98;
    }, /can only be set at construction/);
    rejects(`unknown cairo methods ${tag}`, () => {
      const area = new Gtk.DrawingArea();
      area.set_draw_func((_a, cr) => cr.drawRoundedRectangle(0, 0, 1, 1));
    }, /Cairo.Context has no method/);
    new Adw.ActionRow({title: 'markup on'});
    new Adw.SwitchRow({use_markup: false, title: 'markup off'});
    check(world.report.markupRows.join() === 'Adw.ActionRow', `rows with markup on are reported ${tag}: ${world.report.markupRows}`);
    const manager = Adw.StyleManager.get_default();
    if (mode === 'min') {
      check(!('get_accent_color_rgba' in manager), 'GNOME 46 has no accent color API');
      check(!('ButtonRow' in Adw), 'GNOME 46 has no Adw.ButtonRow');
      rejects('newer API is missing on GNOME 46', () => manager.get_accent_color_rgba(), /doesn't exist on GNOME 46/);
      rejects('newer classes are missing on GNOME 46', () => Adw.WrapBox, /doesn't exist on GNOME 46/);
    } else {
      rejects('newer API needs an `in` check first', () => Adw.StyleManager.get_default().get_monospace_font_name(), /check `'get_monospace_font_name' in object`/);
      check('get_accent_color_rgba' in manager, 'GNOME 49 has the accent color API');
      manager.get_accent_color_rgba();
      pass('guarded newer API works on GNOME 49');
    }
    void Gdk;
  }
  fs.rmSync(home, {recursive: true, force: true});
}

/** Every symbolic icon the preferences name exists in the Adwaita themes of GNOME 46 and 49. */
function iconCheck() {
  console.log('\nIcons');
  const available = new Set(fs.readFileSync(path.join(here, 'gi/adwaita-icons.txt'), 'utf8').split('\n')
    .filter(line => line && !line.startsWith('#')));
  const roots = [path.resolve(here, '../../gnome-extension/prefs.js'), path.resolve(here, '../../gnome-extension/lib/prefs')];
  const sources = [];
  const walk = p => (fs.statSync(p).isDirectory() ? fs.readdirSync(p).forEach(f => walk(path.join(p, f))) : p.endsWith('.js') && sources.push(p));
  roots.forEach(walk);
  const missing = new Set();
  let count = 0;
  for (const file of sources) {
    for (const [, name] of fs.readFileSync(file, 'utf8').matchAll(/['"`]([a-z0-9-]+-symbolic)['"`]/g)) {
      count++;
      if (!available.has(name)) missing.add(`${name} (${path.basename(file)})`);
    }
  }
  if (missing.size) fail('icon names exist in Adwaita 46 and 49', new Error([...missing].join(', ')));
  else pass(`all ${count} icon references exist in Adwaita 46 and 49`);
}

selfTest();
iconCheck();
for (const mode of ['min', 'new']) {
  try {
    await run(mode);
  } catch (error) {
    fail(`run (${mode})`, error);
  }
}
console.log(`\n${passes} passed, ${failures} failed`);
process.exitCode = failures ? 1 : 0;

export {MockError, descendants};

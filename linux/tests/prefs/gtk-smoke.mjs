// Smoke test of the preferences window on the real GTK and libadwaita, under GJS:
//
//   dbus-run-session -- xvfb-run -a env G_DEBUG=fatal-criticals gjs -m linux/tests/prefs/gtk-smoke.mjs
//
// (CI runs it on Ubuntu 24.04: GTK 4.14 and libadwaita 1.5, GNOME 46's.) It builds the window the
// way GNOME Shell's extension preferences would, against a throwaway home with a version 1 config
// (migrated on open, importing ~/.slate.js) and a status file, then visits every section, opens a
// few editors, edits a binding and lets the main loop run between steps. Any JavaScript error makes it exit 1; G_DEBUG=fatal-criticals
// turns GTK criticals (bad API use) into crashes.
//
// It imports lib/prefs/ui/window.js directly: prefs.js imports GNOME Shell's ExtensionPreferences
// from a resource that only exists inside the Extensions app.

import Adw from 'gi://Adw?version=1';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk?version=4.0';
import System from 'system';

const here = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
const repo = GLib.build_filenamev([here, '..', '..', '..']);
const encoder = new TextEncoder();
let failures = 0;

function write(path, text) {
  GLib.mkdir_with_parents(GLib.path_get_dirname(path), 0o755);
  GLib.file_set_contents(path, encoder.encode(text));
}

function read(path) {
  return new TextDecoder().decode(GLib.file_get_contents(path)[1]);
}

function spin(ms = 150) {
  const context = GLib.MainContext.default();
  const until = GLib.get_monotonic_time() + ms * 1000;
  while (GLib.get_monotonic_time() < until) {
    while (context.pending()) context.iteration(false);
    GLib.usleep(5000);
  }
}

function step(name, fn) {
  try {
    fn();
    spin();
    print(`  ✔ ${name}`);
  } catch (error) {
    failures++;
    print(`  ✘ ${name}\n      ${error}\n${error.stack ?? ''}`);
  }
}

// GJS logs exceptions thrown in signal handlers instead of propagating them: count them as failures.
const realLogError = globalThis.logError;
globalThis.logError = (error, message) => {
  failures++;
  realLogError(error, message);
};

// A throwaway home: GLib reads $HOME when it starts, so this script must run with HOME set to it.
const home = GLib.get_home_dir();
if (!home.includes('slated-gtk-smoke')) {
  print('Run with HOME set to a temporary folder whose name contains "slated-gtk-smoke" (see linux/tests/prefs/run-gtk.sh).');
  System.exit(2);
}
const uuid = 'slated@shobhit-aida.github.io';
const extension = GLib.build_filenamev([home, '.local/share/gnome-shell/extensions', uuid]);
write(GLib.build_filenamev([extension, 'build-info.json']), JSON.stringify({version: '0.1.0', commit: 'test', builtAt: '2026-10-22T00:00:00Z'}));
// config.json ids must be UUIDs (the engine rejects anything else, as Swift does).
const B1 = '00000000-0000-4000-8000-000000000001';
const B2 = '00000000-0000-4000-8000-000000000002';
const B3 = '00000000-0000-4000-8000-000000000003';
const H1 = '00000000-0000-4000-8000-000000000101';
write(GLib.build_filenamev([home, '.config/slated/config.json']), JSON.stringify({
  keyboard: {capsLock: 'hyper'},
  bindings: [
    {id: B1, name: 'Left half', keys: 'hyper+a', action: {op: 'push', direction: 'left', style: 'bar-resize:screenSizeX/2'}},
    {id: B2, keys: 'hyper+[', action: {op: 'chain', operations: [{op: 'undo'}, {op: 'relaunch'}]}},
    {id: B3, keys: 'hyper+f', action: {op: 'by-orientation', landscape: {op: 'push', direction: 'left'}, portrait: {op: 'push', direction: 'up'}}},
  ],
  layouts: [{name: 'Coding', apps: [{app: 'Firefox', operations: [{op: 'undo'}]}]}],
  hotstrings: [{id: H1, trigger: ';s', replacement: 'shrug'}],
}));
write(GLib.build_filenamev([home, '.local/state/slated/status.json']), JSON.stringify({
  session: 'gtk00001', running: true, hyper: {wanted: true, mode: 'xkb', active: true},
  hotstrings: {engine: 'none', espansoInstalled: false, count: 0}, hotkeys: {'hyper+a': 'active'}, sources: [],
  screens: [{displayID: 1, name: 'Screen', frame: {x: 0, y: 0, width: 1920, height: 1080}, visibleFrame: {x: 0, y: 32, width: 1920, height: 1048}, isMain: true, scale: 1}],
}));
write(GLib.build_filenamev([home, '.slate.js']), read(GLib.build_filenamev([repo, 'linux/tests/prefs/fixtures/slate-author-like.js'])));

print('Preferences on the real GTK and libadwaita');
Adw.init();
const {SlatedSettings} = await import(`file://${GLib.build_filenamev([repo, 'linux/gnome-extension/lib/prefs/ui/window.js'])}`);
const window = new Adw.PreferencesWindow();
let settings = null;

step('builds the window', () => {
  window.add(new Adw.PreferencesPage({title: 'Slated', icon_name: 'preferences-system-symbolic'}));
  settings = new SlatedSettings(window, {path: extension, uuid, metadata: {uuid, name: 'Slated', 'version-name': '0.1.0'}});
  window.present();
});

if (settings) {
  for (const id of ['overview', 'windows', 'hotstrings', 'clipboard', 'automation', 'keyboard', 'layouts', 'general', 'about']) {
    step(`shows ${id}`, () => settings.showPane(id));
  }
  step('opens and edits a binding', () => {
    settings.navigate('windows', {binding: B1});
    settings.model.setBinding(B1, b => {
      b.action = {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/3', height: 'screenSizeY'};
    });
    spin(600);
    settings.panes.get('windows').nav.pop();
  });
  step('opens the chain and by-orientation editors', () => {
    settings.navigate('windows', {binding: B2});
    spin();
    settings.navigate('windows', {binding: B3});
    spin();
    settings.panes.get('windows').nav.pop();
  });
  step('starts a new shortcut, which records', () => {
    settings.navigate('windows', {newBinding: true});
    spin();
    settings.panes.get('windows').nav.pop();
  });
  step('opens a new hotstring', () => settings.navigate('hotstrings', {newHotstring: true}));
  step('adds an automation recipe, whose editor records its shortcut', () => {
    settings.navigate('automation', {recipe: 'auto-click-left'});
    spin();
    settings.panes.get('automation').nav.pop();
  });
  step('narrow windows collapse to one column', () => {
    window.set_default_size(400, 700);
    spin(300);
    window.set_default_size(1000, 700);
  });
  step('closes, saving the edits', () => {
    window.close();
    spin(300);
    const saved = JSON.parse(read(GLib.build_filenamev([home, '.config/slated/config.json'])));
    if (saved.bindings[0].action.op !== 'move') throw new Error('the edit was not saved');
  });
}

void Gio;
void Gtk;
print(failures ? `\n${failures} failed` : '\nall passed');
System.exit(failures ? 1 : 0);

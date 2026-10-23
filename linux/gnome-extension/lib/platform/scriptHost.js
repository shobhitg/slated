// Gives Slate JavaScript configs access to real windows, apps and screens (the host side of
// slateScript.js), and delivers `slate.on` events. A port of the macOS AppScriptHost.
//
// Scripts refer to windows by handle: Mutter's window id (`Meta.Window.get_id()`), stable while the
// window exists. Apps get small integer handles that scripts see as `app.pid()` / `win.pid()`: GNOME
// apps can span several processes, so these are Slated's own ids, keyed by the app id (desktop id or
// WM class) so they stay consistent within a session even when GNOME re-matches a window to its app.

import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {currentScreens} from './screens.js';
import {runShellCommandSync, startShellCommand} from './system.js';
import {stableStringify, truncate} from './util.js';
import * as Windows from './windows.js';

export class GnomeScriptHost {
  constructor({runner, log, home}) {
    this._runner = runner;
    this._log = log;
    this._home = home;
    this._appHandles = new Map();
    this._keysByHandle = new Map();
    this._nextApp = 1;
    /** Where the script being run comes from, for action logs ("~/.slate.js"). */
    this.source = 'JavaScript';
  }

  // --- Handles -----------------------------------------------------------------------------------

  windowHandle(window) {
    return window ? window.get_id() : null;
  }

  window(handle) {
    if (handle === null || handle === undefined) return null;
    return Windows.allWindows().find((w) => w.get_id() === handle) ?? null;
  }

  appHandle(app) {
    const key = Windows.appId(app);
    if (!this._appHandles.has(key)) {
      const handle = this._nextApp++;
      this._appHandles.set(key, handle);
      this._keysByHandle.set(handle, key);
    }
    return this._appHandles.get(key);
  }

  appInfo(app) {
    return {pid: this.appHandle(app), name: app.get_name(), bundleID: Windows.appId(app)};
  }

  /** The running Shell.App behind a script's app handle (looked up fresh: apps come and go). */
  shellApp(pid) {
    const key = this._keysByHandle.get(pid);
    if (key === undefined) return null;
    return Windows.runningApps().find((app) => Windows.appId(app) === key) ?? null;
  }

  // --- ScriptHost --------------------------------------------------------------------------------

  focusedWindow() {
    return this.windowHandle(Windows.focusedWindow());
  }

  windowInfo(handle) {
    const window = this.window(handle);
    if (!window) return null;
    const app = Windows.appOf(window);
    return {
      handle,
      title: window.get_title() ?? '',
      frame: Windows.frameOf(window),
      pid: app ? this.appHandle(app) : 0,
      isMinimizedOrHidden: window.minimized,
      isMain: Windows.isMainWindow(window),
      isMovable: typeof window.allows_move === 'function' ? window.allows_move() : true,
      isResizable: typeof window.allows_resize === 'function' ? window.allows_resize() : true,
    };
  }

  windows(pid) {
    const app = this.shellApp(pid);
    return app ? Windows.appWindows(app).map((w) => w.get_id()) : [];
  }

  mainWindow(pid) {
    return this.windows(pid)[0] ?? null;
  }

  windowAt(point) {
    for (const window of Windows.stackedWindows()) {
      const f = Windows.frameOf(window);
      if (point.x >= f.x && point.x < f.x + f.width && point.y >= f.y && point.y < f.y + f.height) return window.get_id();
    }
    return null;
  }

  frontmostApp() {
    const app = Shell.WindowTracker.get_default().focus_app;
    return app ? this.appInfo(app) : this.runningApps()[0] ?? null;
  }

  runningApps() {
    return Windows.runningApps().map((app) => this.appInfo(app));
  }

  app(pid) {
    const app = this.shellApp(pid);
    return app ? this.appInfo(app) : null;
  }

  screens() {
    return currentScreens();
  }

  setFrame(rect, handle) {
    const window = this.window(handle);
    return window ? Windows.moveResize(window, rect) : false;
  }

  focus(handle) {
    const window = this.window(handle);
    if (!window) return false;
    Windows.activate(window);
    return true;
  }

  perform(action, handle) {
    const window = handle === null || handle === undefined ? null : this.window(handle);
    return this._runner.run(action, {window, chainKey: `js:${stableStringify(action)}`, trigger: 'script', source: this.source});
  }

  /** `slate.shell`: with `wait` the script gets the output, so this blocks (briefly; see system.js). */
  runShell(command, wait, path) {
    const result = wait ? runShellCommandSync(command, {path, home: this._home}) : startShellCommand(command, {path, home: this._home});
    if (!result.ok) this._log?.error('script.shell_failed', result.error);
    return wait && result.ok ? result.output : null;
  }

  log(message) {
    this._log?.record('script.log', {message: truncate(message, 500)});
  }
}

// --- slate.on -------------------------------------------------------------------------------------

/** The `slate.on` events GNOME can deliver. GNOME has no hidden apps, so appHidden/appUnhidden can't fire. */
export const SUPPORTED_EVENTS = new Set([
  'windowOpened',
  'windowClosed',
  'windowMoved',
  'windowResized',
  'windowFocused',
  'windowTitleChanged',
  'appOpened',
  'appClosed',
  'appActivated',
  'appDeactivated',
  'screenConfigurationChanged',
]);

// windowClosed listens to `unmanaging`: by `unmanaged`, Shell.WindowTracker has already forgotten the
// window's app. (At `window-created` the app may not be known yet on Wayland: the app id arrives later.)
const PER_WINDOW = {
  windowClosed: 'unmanaging',
  windowMoved: 'position-changed',
  windowResized: 'size-changed',
  windowTitleChanged: 'notify::title',
};

/** Connects GNOME signals for the events scripts listen to, and turns them into script events. */
export class ScriptEvents {
  constructor({host, timers, dispatch}) {
    this._host = host;
    this._timers = timers;
    this._dispatch = dispatch;
    this._names = new Set();
    this._signals = [];
    this._windowSignals = new Map();
    this._debounce = new Map();
    this._focusApp = null;
  }

  /** Listens for exactly `names` (replacing what was watched before). Returns the unsupported ones. */
  watch(names) {
    this.stop();
    const wanted = new Set(names);
    this._names = new Set([...wanted].filter((n) => SUPPORTED_EVENTS.has(n)));
    if (this._names.size === 0) return [...wanted].filter((n) => !SUPPORTED_EVENTS.has(n));

    const display = global.display;
    const needsWindows = Object.keys(PER_WINDOW).some((n) => this._names.has(n)) || this._names.has('windowOpened');
    if (needsWindows) {
      this._connect(display, 'window-created', (_display, window) => {
        if (!Windows.isManaged(window)) return;
        this._watchWindow(window);
        // Let the window finish appearing (app, title, frame) before scripts look at it.
        if (this._names.has('windowOpened')) this._timers.idle(() => this._emit({name: 'windowOpened', window: window.get_id()}));
      });
      for (const window of Windows.allWindows()) this._watchWindow(window);
    }
    if (this._names.has('windowFocused')) {
      this._connect(display, 'notify::focus-window', () => {
        const window = Windows.focusedWindow();
        if (window) this._emit({name: 'windowFocused', window: window.get_id()});
      });
    }
    if (this._names.has('appOpened') || this._names.has('appClosed')) {
      this._connect(Shell.AppSystem.get_default(), 'app-state-changed', (_system, app) => {
        const state = app.get_state();
        if (state === Shell.AppState.RUNNING && this._names.has('appOpened')) this._emit({name: 'appOpened', app: this._host.appInfo(app)});
        if (state === Shell.AppState.STOPPED && this._names.has('appClosed')) this._emit({name: 'appClosed', app: this._host.appInfo(app)});
      });
    }
    if (this._names.has('appActivated') || this._names.has('appDeactivated')) {
      const tracker = Shell.WindowTracker.get_default();
      this._focusApp = tracker.focus_app;
      this._connect(tracker, 'notify::focus-app', () => {
        const previous = this._focusApp;
        const next = tracker.focus_app;
        this._focusApp = next;
        if (previous === next) return;
        if (previous && this._names.has('appDeactivated')) this._emit({name: 'appDeactivated', app: this._host.appInfo(previous)});
        if (next && this._names.has('appActivated')) this._emit({name: 'appActivated', app: this._host.appInfo(next)});
      });
    }
    if (this._names.has('screenConfigurationChanged')) {
      this._connect(Main.layoutManager, 'monitors-changed', () => this._emit({name: 'screenConfigurationChanged'}));
    }
    return [...wanted].filter((n) => !SUPPORTED_EVENTS.has(n));
  }

  stop() {
    for (const {object, id} of this._signals) object.disconnect(id);
    this._signals = [];
    for (const [window, ids] of this._windowSignals) for (const id of ids) window.disconnect(id);
    this._windowSignals.clear();
    for (const id of this._debounce.values()) this._timers.clear(id);
    this._debounce.clear();
    this._focusApp = null;
  }

  destroy() {
    this.stop();
    this._dispatch = null;
  }

  _connect(object, signal, callback) {
    this._signals.push({object, id: object.connect(signal, callback)});
  }

  _watchWindow(window) {
    if (this._windowSignals.has(window)) return;
    const ids = [];
    for (const [name, signal] of Object.entries(PER_WINDOW)) {
      // Always connected: it also drops this window's handlers.
      if (!this._names.has(name) && name !== 'windowClosed') continue;
      ids.push(
        window.connect(signal, () => {
          if (name === 'windowClosed') {
            const app = Windows.appOf(window);
            this._forget(window);
            if (this._names.has('windowClosed') && app) this._emit({name, app: this._host.appInfo(app)});
            return;
          }
          if (name === 'windowTitleChanged') {
            this._emit({name, window: window.get_id()});
            return;
          }
          // Moves and resizes arrive continuously while dragging: report once things settle.
          const key = `${name}:${window.get_id()}`;
          this._timers.clear(this._debounce.get(key));
          this._debounce.set(
            key,
            this._timers.timeout(150, () => {
              this._debounce.delete(key);
              this._emit({name, window: window.get_id()});
            }),
          );
        }),
      );
    }
    this._windowSignals.set(window, ids);
  }

  _forget(window) {
    const ids = this._windowSignals.get(window) ?? [];
    for (const id of ids) window.disconnect(id);
    this._windowSignals.delete(window);
  }

  _emit(event) {
    this._dispatch?.(event);
  }
}

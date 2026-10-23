// What the action runner (actions.js) and the snapshot store need from GNOME, in one object. Windows
// are Meta.Window objects and apps are Shell.App objects; the runner treats both as opaque.

import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

import {currentScreens} from './screens.js';
import {openURL, startShellCommand} from './system.js';
import * as Windows from './windows.js';

/** How long to wait before checking where a moved window ended up (Wayland apps resize asynchronously). */
const SETTLE_MS = 150;
/** The longest a `shell` action with `wait` holds up the steps after it (the command keeps running). */
const SHELL_WAIT_LIMIT_MS = 10_000;

export class GnomePlatform {
  constructor({timers, input, home}) {
    this._timers = timers;
    this._input = input;
    this._home = home;
  }

  now() {
    return GLib.get_monotonic_time() / 1000;
  }

  // --- Windows -----------------------------------------------------------------------------------

  focusedWindow() {
    return Windows.focusedWindow();
  }

  frame(window) {
    try {
      return Windows.frameOf(window);
    } catch {
      return null;
    }
  }

  screens() {
    return currentScreens();
  }

  setFrame(window, rect) {
    try {
      return Windows.moveResize(window, rect);
    } catch {
      return false;
    }
  }

  isMaximizedOrFullscreen(window) {
    try {
      return Windows.isMaximized(window) || window.is_fullscreen();
    } catch {
      return false;
    }
  }

  afterSettle(window, callback) {
    this._timers.timeout(SETTLE_MS, () => {
      if (Windows.isAlive(window)) callback();
    });
  }

  sameWindow(a, b) {
    return a === b;
  }

  isAlive(window) {
    return Windows.isAlive(window);
  }

  focus(window) {
    Windows.activate(window);
  }

  windowsOnWorkspace() {
    return Windows.stackedWindows();
  }

  windowTitle(window) {
    return window.get_title() ?? '';
  }

  isMainWindow(window) {
    return Windows.isMainWindow(window);
  }

  // --- Apps --------------------------------------------------------------------------------------

  appOfWindow(window) {
    return Windows.appOf(window);
  }

  appInfo(app) {
    return app ? {id: Windows.appId(app), name: Windows.appName(app)} : null;
  }

  focusedApp() {
    return Shell.WindowTracker.get_default().focus_app ?? Windows.appOf(Windows.focusedWindow());
  }

  runningApps() {
    return Windows.runningApps();
  }

  appMatches(app, name) {
    return Windows.appMatches(app, name);
  }

  findApp(name) {
    return this.runningApps().find((app) => Windows.appMatches(app, name)) ?? null;
  }

  appWindows(app) {
    return Windows.appWindows(app);
  }

  hideApp(app) {
    Windows.hideApp(app);
  }

  showApp(app) {
    Windows.showApp(app);
  }

  isAppHidden(app) {
    return Windows.isAppHidden(app);
  }

  activateApp(app) {
    Windows.activateApp(app);
  }

  // --- Everything else ---------------------------------------------------------------------------

  /**
   * Starts a command. With `wait`, also returns `wait`: a promise that settles when it exits or after
   * SHELL_WAIT_LIMIT_MS, whichever comes first (never on its own after disable: timers are cleared).
   */
  runShell(command, {wait = false, path = null} = {}) {
    const result = startShellCommand(command, {path, home: this._home});
    if (!result.ok || !wait) return {ok: result.ok, error: result.error};
    const limit = new Promise((resolve) => this._timers.timeout(SHELL_WAIT_LIMIT_MS, resolve));
    return {ok: true, wait: Promise.race([result.exited, limit])};
  }

  openURL(url) {
    return openURL(url);
  }

  insertText(text, method) {
    try {
      return this._input.insertText(text, method);
    } catch (e) {
      return {ok: false, error: `Couldn't type: ${e.message}`};
    }
  }

  pressKeys(combo) {
    try {
      return this._input.pressKeys(combo);
    } catch (e) {
      return {ok: false, error: `Couldn't press keys: ${e.message}`};
    }
  }

  /** Every window with its app and frame, for snapshots. */
  snapshotWindows() {
    return Windows.allWindows().map((window) => ({
      window,
      app: Windows.appId(Windows.appOf(window), window),
      title: window.get_title() ?? '',
      frame: Windows.frameOf(window),
    }));
  }
}

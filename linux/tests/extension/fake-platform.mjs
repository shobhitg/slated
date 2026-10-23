// A pretend GNOME desktop for ActionRunner and SnapshotStore tests: windows with frames and apps, two
// screens, and recordings of everything that would touch the system.

import {screens as defaultScreens} from './fixtures.mjs';

export class FakeWindow {
  constructor({id, app, title = '', frame, minimized = false, minSize = null, maximized = false, restoreSize = null}) {
    this.id = id;
    this.app = app;
    this.title = title;
    this.frame = {...frame};
    this.minimized = minimized;
    this.minSize = minSize;
    /** A maximized window first settles at `restoreSize` when moved (like a Wayland app leaving maximized). */
    this.maximized = maximized;
    this.restoreSize = restoreSize;
    this.closed = false;
  }
}

export class FakePlatform {
  constructor({windows = [], apps = [], screens = defaultScreens} = {}) {
    this.windows = windows; // stacking order, top first
    this.apps = new Map(apps.map((a) => [a.id, {...a, hidden: false}]));
    this.screenList = screens;
    this.focused = windows.find((w) => !w.minimized) ?? null;
    this.time = 1000;
    this.settles = [];
    this.calls = [];
    this.refuseMoves = new Set();
    this.pendingShells = [];
  }

  now() {
    this.time += 5;
    return this.time;
  }

  focusedWindow() {
    return this.focused;
  }

  frame(window) {
    return window && !window.closed ? {...window.frame} : null;
  }

  screens() {
    return this.screenList;
  }

  setFrame(window, rect) {
    if (this.refuseMoves.has(window.id)) return false;
    this.calls.push(['setFrame', window.id, {...rect}]);
    if (window.maximized && window.restoreSize) {
      window.maximized = false;
      window.frame = {x: rect.x, y: rect.y, ...window.restoreSize};
      return true;
    }
    window.maximized = false;
    const width = window.minSize ? Math.max(rect.width, window.minSize.width) : rect.width;
    const height = window.minSize ? Math.max(rect.height, window.minSize.height) : rect.height;
    window.frame = {x: rect.x, y: rect.y, width, height};
    return true;
  }

  isMaximizedOrFullscreen(window) {
    return !!window.maximized;
  }

  afterSettle(window, callback) {
    this.settles.push(callback);
  }

  /** Runs pending settle checks, as the main loop would a moment later. */
  settle() {
    const pending = this.settles;
    this.settles = [];
    for (const callback of pending) callback();
  }

  sameWindow(a, b) {
    return a === b;
  }

  isAlive(window) {
    return !!window && !window.closed;
  }

  focus(window) {
    this.focused = window;
    this.calls.push(['focus', window.id]);
  }

  windowsOnWorkspace() {
    return this.windows.filter((w) => !w.minimized && !w.closed);
  }

  windowTitle(window) {
    return window.title;
  }

  isMainWindow(window) {
    return this.appWindows(this.apps.get(window.app))[0] === window;
  }

  appOfWindow(window) {
    return window ? this.apps.get(window.app) ?? null : null;
  }

  appInfo(app) {
    return app ? {id: app.id, name: app.name} : null;
  }

  focusedApp() {
    return this.appOfWindow(this.focused);
  }

  runningApps() {
    return [...this.apps.values()];
  }

  appMatches(app, name) {
    const n = name.toLowerCase();
    return app.name.toLowerCase() === n || app.id.toLowerCase() === n;
  }

  findApp(name) {
    return this.runningApps().find((app) => this.appMatches(app, name)) ?? null;
  }

  appWindows(app) {
    return app ? this.windows.filter((w) => w.app === app.id && !w.minimized && !w.closed) : [];
  }

  hideApp(app) {
    app.hidden = true;
    this.calls.push(['hide', app.id]);
  }

  showApp(app) {
    app.hidden = false;
    this.calls.push(['show', app.id]);
  }

  isAppHidden(app) {
    return app.hidden;
  }

  activateApp(app) {
    this.calls.push(['activate', app.id]);
  }

  /** Waiting commands stay pending until the test calls `finishShells()`. */
  runShell(command, options) {
    this.calls.push(['shell', command, options]);
    if (command === 'false') return {ok: false, error: 'exit status 1'};
    if (!options.wait) return {ok: true};
    return {ok: true, wait: new Promise((resolve) => this.pendingShells.push(resolve))};
  }

  /** Lets waiting shell commands "exit"; resolves once the continuations ran. */
  async finishShells() {
    const pending = this.pendingShells;
    this.pendingShells = [];
    for (const resolve of pending) resolve();
    await new Promise((resolve) => setImmediate(resolve));
  }

  openURL(url) {
    this.calls.push(['openURL', url]);
    return url.includes(':') ? {ok: true} : {ok: false, error: `Invalid URL ${url}`};
  }

  insertText(text, method) {
    this.calls.push(['insertText', text, method]);
    return {ok: true};
  }

  pressKeys(combo) {
    this.calls.push(['pressKeys', combo]);
    return {ok: true};
  }

  click(button, count) {
    this.calls.push(['click', button, count]);
    return {ok: true};
  }

  /** Main-loop timeouts (a macro's `wait`), run by `advance(ms)`. */
  after(ms, callback) {
    this.timeouts ??= [];
    this.clock ??= 0;
    this.timeouts.push({due: this.clock + ms, callback});
    return this.timeouts.length;
  }

  advance(ms) {
    this.clock = (this.clock ?? 0) + ms;
    for (;;) {
      const due = (this.timeouts ?? []).filter((t) => t.due <= this.clock).sort((a, b) => a.due - b.due)[0];
      if (!due) return;
      this.timeouts.splice(this.timeouts.indexOf(due), 1);
      due.callback();
    }
  }

  snapshotWindows() {
    return this.windows.map((w) => ({window: w, app: w.app, title: w.title, frame: {...w.frame}}));
  }
}

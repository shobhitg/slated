// Runs Slate JavaScript configs (`~/.slate.js`) with Slate's JavaScript API, in GJS.
// A port of the macOS SlatedScript module (Sources/SlatedScript: ScriptPrelude, ScriptNatives,
// ScriptOperations, ScriptInfo, SlateScriptEngine).
//
// The script gets the `slate` and `S` objects (with Slate's short aliases), `window` (the script's
// global object, as in Slate's web view) and `_` (a small built-in subset of underscore.js). Plain
// operations come out as Action JSON that the action runner performs; anything that needs JavaScript
// at run time (bound functions, layout steps, event handlers) stays here and runs through `invoke`,
// `run` and `dispatch`. Mistakes never escape: exceptions and API misuse become diagnostics with file
// and line, and the rest of the file still loads.
//
// Everything outside JavaScript goes through `host` (see scriptHost.js for GNOME, and the fake hosts
// in linux/tests/extension), so this file has no GNOME imports:
//
//   focusedWindow() → handle | null              windowInfo(handle) → {handle, title, frame, pid,
//   windows(pid) → [handle] (front to back)         isMinimizedOrHidden, isMain, isMovable, isResizable} | null
//   runningApps() → [{pid, name, bundleID}]      screens() → [ScreenInfo] (OS order)
//   setFrame(rect, handle) → bool                focus(handle) → bool
//   perform(action, handle | null) → bool        runShell(command, wait, path) → string | null
//   log(message)
//   optional: mainWindow(pid), windowAt(point), frontmostApp(), app(pid)
//
// Differences from the macOS engine, all due to running inside GNOME Shell:
// - Scripts run in GNOME Shell's own JavaScript context (GJS has no separate contexts), wrapped in a
//   function so `var`/`let`/function declarations stay private. A name assigned without
//   `let`/`const`/`var` would become a shell global: Slated warns about it, removes it on reload, and
//   puts back any shell global a script overwrote.
// - A script stuck in an endless loop freezes GNOME Shell, as it froze Slate (JavaScript can't be
//   interrupted from inside the same thread). Keep `~/.slate.js` simple.

import * as Core from '../core/index.js';

import {bindingKey, comboOf, modalOf} from './combos.js';
import {expandHome, orderedLeftToRight, screenContaining, truthyText} from './util.js';

export const EVENT_NAMES = Object.freeze([
  'windowOpened',
  'windowClosed',
  'windowMoved',
  'windowResized',
  'windowFocused',
  'windowTitleChanged',
  'appOpened',
  'appClosed',
  'appHidden',
  'appUnhidden',
  'appActivated',
  'appDeactivated',
  'screenConfigurationChanged',
]);

/** Slate's operations plus Slated's own, with the parameters each understands. */
export const OPERATION_PARAMETERS = Object.freeze({
  move: new Set(['x', 'y', 'width', 'height', 'screen']),
  resize: new Set(['width', 'height', 'anchor']),
  push: new Set(['direction', 'style', 'screen']),
  nudge: new Set(['x', 'y']),
  throw: new Set(['screen', 'width', 'height']),
  corner: new Set(['direction', 'width', 'height', 'screen']),
  chain: new Set(['operations']),
  sequence: new Set(['operations']),
  layout: new Set(['name']),
  focus: new Set(['direction', 'app']),
  snapshot: new Set(['name', 'save', 'stack']),
  'delete-snapshot': new Set(['name', 'all']),
  'activate-snapshot': new Set(['name', 'delete']),
  hint: new Set(['characters']),
  grid: new Set(['padding', 'grids']),
  hide: new Set(['app']),
  show: new Set(['app']),
  toggle: new Set(['app']),
  shell: new Set(['command', 'wait', 'path']),
  undo: new Set(),
  relaunch: new Set(),
  // Slate's app switcher took key names as parameters; Slated parses but doesn't run it.
  switch: new Set(['back', 'quit', 'force-quit', 'hide']),
  'insert-text': new Set(['text', 'method']),
  'open-url': new Set(['url']),
  keystroke: new Set(['keys']),
});

// --- Locating script lines in stack traces --------------------------------------------------------

// Code made with `new Function` shows up in stacks as
//   SpiderMonkey (GJS):  name@file:///…/slateScript.js line 412 > Function:12:9
//   V8 (Node tests):     at name (eval at evaluate (file:///…/slateScript.js:412:12), <anonymous>:12:9)
const SPIDERMONKEY_FRAME = /> Function:(\d+):(\d+)/;
const V8_FRAME = /<anonymous>:(\d+):(\d+)\)$/;

/** The line of the innermost frame running code created with `new Function`, or null. */
export function functionFrameLine(stack) {
  for (const raw of String(stack ?? '').split('\n')) {
    const line = raw.trim();
    const match = SPIDERMONKEY_FRAME.exec(line) ?? (line.includes('eval at') ? V8_FRAME.exec(line) : null);
    if (match) return Number(match[1]);
  }
  return null;
}

/** How many lines the engine's `new Function` wrapper adds before the script's first line. */
function probeLineOffset() {
  try {
    // eslint-disable-next-line no-new-func
    const error = new Function('return new Error("probe");')();
    const line = functionFrameLine(error.stack);
    return line ? line - 1 : 2;
  } catch {
    return 2;
  }
}

// --- Parameter helpers ----------------------------------------------------------------------------

const isNullish = (value) => value === undefined || value === null;

/** Slate read flags with Objective-C's `boolValue`. */
export function truthy(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value === 'string') return truthyText(value);
  return Boolean(value);
}

/** Slate accepted strings and numbers where a flag or count was expected, so Slated does too. */
export function coerceParameter(value, key) {
  switch (key) {
    case 'wait':
    case 'save':
    case 'stack':
    case 'all':
    case 'delete':
      if (typeof value === 'string') return truthyText(value);
      if (typeof value === 'number') return value !== 0;
      return value;
    case 'padding':
      if (typeof value === 'string' && /^\s*-?\d+\s*$/.test(value)) return Number(value.trim());
      return value;
    case 'grids': {
      if (!value || typeof value !== 'object' || Array.isArray(value)) return value;
      const out = {};
      for (const [screen, size] of Object.entries(value)) {
        if (!size || typeof size !== 'object') {
          out[screen] = size;
          continue;
        }
        const copy = {...size};
        for (const dimension of ['width', 'height']) {
          if (typeof copy[dimension] === 'string' && /^\s*-?\d+\s*$/.test(copy[dimension])) {
            copy[dimension] = Number(copy[dimension].trim());
          }
        }
        out[screen] = copy;
      }
      return out;
    }
    default:
      return value;
  }
}

/** The core's error text without the wrapper path `normalizeAction` adds. */
function cleanDecodeError(error) {
  return String(error?.message ?? error)
    .replace(/\s*\(at bindings\[0\]\.action\.?([^)]*)\)/g, (_m, rest) => (rest ? ` (at ${rest})` : ''))
    .replace(/bindings\[0\]\.action\.?/g, '');
}

/**
 * Validates and canonicalizes an Action object with the core's own decoder: the action is decoded as
 * part of a one-binding configuration, which fills defaults and normalizes values exactly as
 * config.json actions are. Throws with the decoder's message when the action is invalid.
 */
export function normalizeAction(core, action) {
  let config;
  try {
    config = core.decodeConfiguration(JSON.stringify({bindings: [{keys: 'f19', action}]}));
  } catch (e) {
    throw new Error(cleanDecodeError(e));
  }
  const decoded = config?.bindings?.[0]?.action;
  if (!decoded || typeof decoded !== 'object') throw new Error('not a valid operation');
  return decoded;
}

/** Converts a coordinate the way Slate handed numbers to scripts: truncated toward zero. */
function integer(value) {
  if (!Number.isFinite(value)) return 0;
  return Math.trunc(Math.min(Math.max(value, -1e15), 1e15));
}

function errorText(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}

function staticTargets(targets) {
  const actions = targets.map((t) => (t.kind === 'action' ? t.action : null));
  return actions.every(Boolean) ? actions : null;
}

/** A script layout as a plain config.json Layout, when no step needs JavaScript; otherwise null. */
export function staticLayout(layout) {
  const before = staticTargets(layout.before);
  const after = staticTargets(layout.after);
  if (!before || !after) return null;
  const apps = [];
  for (const app of layout.apps) {
    const operations = staticTargets(app.operations);
    if (!operations) return null;
    apps.push({app: app.app, operations, options: app.options});
  }
  return {name: layout.name, apps, before, after};
}

function emptyResult(path = null) {
  return {
    path,
    bindings: [],
    settings: {},
    layouts: [],
    defaults: [],
    events: [],
    sourcedFiles: [],
    diagnostics: [],
    hasErrors: false,
  };
}

// --- The engine -----------------------------------------------------------------------------------

export class SlateScriptEngine {
  /**
   * @param {object} options
   * @param {object} options.host  See the contract at the top of this file.
   * @param {object} [options.core]  The engine API (lib/core/index.js); tests may pass a fake.
   * @param {(path: string) => string|null} [options.readFile]  For `load` and `slate.source`.
   * @param {string} [options.home]  The home directory (`~` and relative `slate.source` paths).
   */
  constructor({host, core = Core, readFile = () => null, home = ''}) {
    this.host = host;
    this.core = core;
    this.readFile = readFile;
    this.home = home;
    /** What the last `load` registered. */
    this.result = emptyResult();
    // Never reset, so IDs from an earlier load can't be confused with new ones.
    this._nextCallbackId = 1;
    this._nextOperationId = 1;
    this._lineOffset = probeLineOffset();
    this._addedGlobals = new Set();
    this._runningFile = null;
    this._reset();
  }

  // --- Loading -----------------------------------------------------------------------------------

  /** Loads a config file (`~` is expanded), replacing everything from the previous load. */
  load(path) {
    const expanded = expandHome(path, this.home);
    if (this._busy()) return this._refuseReload(expanded);
    const source = this.readFile(expanded);
    if (source === null || source === undefined) {
      this._reset();
      this._diagnostics.push({
        severity: 'error',
        message: `Couldn't read ${path}. Check that the file exists and is readable.`,
        file: expanded,
      });
      return this._finishLoad(expanded);
    }
    return this.loadSource(source, expanded);
  }

  /** Loads a script from a string, replacing everything from the previous load. */
  loadSource(source, path = null) {
    if (this._busy()) return this._refuseReload(path);
    this._reset();
    this._isLoading = true;
    if (path) this._loadingFiles.push(path);
    try {
      this._evaluate(source, path);
    } finally {
      this._loadingFiles = [];
      this._isLoading = false;
    }
    return this._finishLoad(path);
  }

  /** Slate settings with `slate.config` functions evaluated now. */
  evaluatedSettings() {
    let values = {...this._settings};
    this._activity(() => {
      values = this._settingsEvaluatingFunctions();
      return true;
    });
    return values;
  }

  layout(name) {
    return this._layouts.find((l) => l.name === name) ?? null;
  }

  /** Removes everything the last load created (shell globals included). */
  destroy() {
    this._cleanupGlobals();
    this._callbacks = new Map();
    this._eventHandlers = new Map();
    this.result = emptyResult();
  }

  // --- Running -----------------------------------------------------------------------------------

  /** Runs a binding on the focused window, as when its hotkey is pressed. */
  invoke(binding) {
    return this.run(binding.target, this.host.focusedWindow(), {file: binding.file});
  }

  /** Runs a binding target, layout step or default on `window` (null: no window). */
  run(target, window = null, {file = null} = {}) {
    return this._activity(() => {
      if (target.kind === 'action') return this.host.perform(target.action, window);
      return this._runCallback(target.id, window);
    }, file);
  }

  /**
   * Calls the `slate.on` handlers for `event`: `{name, window?, app?}` where `window` is a handle and
   * `app` is `{pid, name, bundleID}`.
   */
  dispatch(event) {
    return this._activity(() => {
      const handlers = this._eventHandlers.get(event.name) ?? [];
      if (handlers.length === 0) return true;
      const payload = this._eventPayload(event);
      let success = true;
      for (const handler of handlers) {
        try {
          handler(event.name, payload);
        } catch (e) {
          this._recordException(e);
          success = false;
        }
      }
      return success;
    });
  }

  // --- State -------------------------------------------------------------------------------------

  _reset() {
    this._cleanupGlobals();
    this._isLoading = false;
    this._loadingFiles = [];
    this._pending = [];
    this._settings = {};
    this._configFunctions = new Map();
    this._layouts = [];
    this._defaults = [];
    this._eventHandlers = new Map();
    this._callbacks = new Map();
    this._chainPositions = new Map();
    this._sourcedFiles = [];
    this._diagnostics = [];
    this._windowContext = [];
    this._depth = 0;
    this._api = this._makeAPI();
  }

  _busy() {
    return this._isLoading || this._depth > 0 || this._windowContext.length > 0;
  }

  /** Replacing the API while JavaScript runs would pull it out from under the running script. */
  _refuseReload(path) {
    const result = emptyResult(path);
    result.diagnostics = [
      {
        severity: 'error',
        message: "Slated can't reload the config while it is running part of it. Reload again in a moment.",
        file: path ?? undefined,
      },
    ];
    result.hasErrors = true;
    return result;
  }

  _finishLoad(path) {
    this._settings = this._settingsEvaluatingFunctions();
    const repeatOps = String(this._settings.repeatOnHoldOps ?? 'resize,nudge')
      .split(',')
      .map((s) => s.trim());
    const bindings = this._pending.map((pending) => ({
      ...pending.binding,
      repeats: pending.explicitRepeat ?? repeatOps.includes(pending.operationName),
    }));
    this.result = {
      path,
      bindings,
      settings: {...this._settings},
      layouts: [...this._layouts],
      defaults: [...this._defaults],
      events: [...this._eventHandlers.keys()],
      sourcedFiles: [...this._sourcedFiles],
      diagnostics: [...this._diagnostics],
      hasErrors: this._diagnostics.some((d) => d.severity === 'error'),
    };
    return this.result;
  }

  _settingsEvaluatingFunctions() {
    const values = {...this._settings};
    for (const name of [...this._configFunctions.keys()].sort()) {
      const fn = this._configFunctions.get(name);
      let value;
      try {
        value = fn();
      } catch (e) {
        this._recordException(e);
        continue;
      }
      const setting = this._settingValue(value);
      if (setting === null) {
        this._report(
          'error',
          `The function for config "${name}" returned ${this._describe(value)}; expected a string, number or boolean.`,
          {file: this._currentFile(), line: null},
        );
      } else {
        values[name] = setting;
      }
    }
    return values;
  }

  // --- Evaluating scripts --------------------------------------------------------------------------

  /** Runs `source` with the API in scope. Returns false if it threw. */
  _evaluate(source, path) {
    const before = this._globalsSnapshot();
    let fn;
    try {
      // eslint-disable-next-line no-new-func
      fn = new Function('slate', 'S', 'window', '_', String(source));
    } catch (e) {
      this._recordException(e, path);
      return false;
    }
    const api = this._api;
    try {
      fn.call(api.scriptGlobal, api.slate, api.slate, api.scriptGlobal, api._);
      return true;
    } catch (e) {
      this._recordException(e, path);
      return false;
    } finally {
      this._checkGlobals(before, path);
    }
  }

  /**
   * Wraps work started from outside JavaScript: collects the diagnostics it produced and reports
   * failure if any of them is an error.
   */
  _activity(body, file = null) {
    const start = this._diagnostics.length;
    const before = this._isLoading ? null : this._globalsSnapshot();
    const savedFile = this._runningFile;
    if (file) this._runningFile = file;
    this._depth += 1;
    let success = false;
    try {
      success = body() !== false;
    } catch (e) {
      this._recordException(e);
      success = false;
    } finally {
      this._depth -= 1;
      if (before) this._checkGlobals(before, this._currentFile());
      this._runningFile = savedFile;
    }
    const found = this._diagnostics.slice(start);
    if (!this._isLoading) this._diagnostics.length = start;
    return {success: success && !found.some((d) => d.severity === 'error'), diagnostics: found};
  }

  _withWindow(window, body) {
    this._windowContext.push(window ?? null);
    try {
      return body();
    } finally {
      this._windowContext.pop();
    }
  }

  /** The window `slate.window()` refers to: the one JavaScript is running for, else the focused one. */
  _currentWindow() {
    if (this._windowContext.length > 0) return this._windowContext[this._windowContext.length - 1];
    return this.host.focusedWindow();
  }

  _currentFile() {
    return this._loadingFiles[this._loadingFiles.length - 1] ?? this._runningFile ?? this.result.path ?? null;
  }

  // --- Shell globals ---------------------------------------------------------------------------------

  _globalsSnapshot() {
    const names = new Set(Object.getOwnPropertyNames(globalThis));
    const values = new Map();
    for (const name of names) {
      const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
      if (descriptor && 'value' in descriptor) values.set(name, descriptor.value);
    }
    return {names, values};
  }

  _checkGlobals(before, file) {
    for (const name of Object.getOwnPropertyNames(globalThis)) {
      if (!before.names.has(name)) {
        if (this._addedGlobals.has(name)) continue;
        this._addedGlobals.add(name);
        this._diagnostics.push({
          severity: 'warning',
          message: `"${name}" was assigned without let, const or var, so it became a GNOME Shell global. Declare it with let.`,
          file: file ?? undefined,
        });
        continue;
      }
      if (!before.values.has(name)) continue;
      const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
      // Object.is: NaN is a global whose value never equals itself.
      if (descriptor && 'value' in descriptor && !Object.is(descriptor.value, before.values.get(name))) {
        try {
          globalThis[name] = before.values.get(name);
        } catch {
          // Read-only now; nothing more to do.
        }
        this._diagnostics.push({
          severity: 'warning',
          message: `The config replaced GNOME Shell's global "${name}"; Slated put it back. Use a different name.`,
          file: file ?? undefined,
        });
      }
    }
  }

  _cleanupGlobals() {
    for (const name of this._addedGlobals ?? []) {
      try {
        delete globalThis[name];
      } catch {
        // Not configurable; leave it.
      }
    }
    this._addedGlobals = new Set();
  }

  // --- Diagnostics ---------------------------------------------------------------------------------

  _report(severity, message, location = null) {
    const where = location ?? this._callerLocation();
    const diagnostic = {severity, message};
    if (where.file) diagnostic.file = where.file;
    if (where.line) diagnostic.line = where.line;
    this._diagnostics.push(diagnostic);
  }

  /** The innermost script line on the stack (the line that called into the API). */
  _callerLocation() {
    const line = functionFrameLine(new Error().stack);
    return {file: this._currentFile(), line: line ? Math.max(line - this._lineOffset, 1) : null};
  }

  _hasError(location) {
    if (!location.line) return false;
    return this._diagnostics.some((d) => d.severity === 'error' && d.file === location.file && d.line === location.line);
  }

  _recordException(error, file = null) {
    let line = null;
    if (error instanceof Error) {
      const frame = functionFrameLine(error.stack);
      if (frame) line = frame - this._lineOffset;
      else if (typeof error.lineNumber === 'number' && String(error.fileName ?? '').includes('> Function')) {
        // A SyntaxError from `new Function` in SpiderMonkey: the line is in the wrapper's source.
        line = error.lineNumber - this._lineOffset;
      }
    }
    const message = error instanceof Error ? String(error) : `Uncaught ${String(error)}`;
    const diagnostic = {severity: 'error', message};
    const where = file ?? this._currentFile();
    if (where) diagnostic.file = where;
    if (line && line > 0) diagnostic.line = line;
    this._diagnostics.push(diagnostic);
  }

  /** For error messages: "undefined", "the number 3", "a function"… */
  _describe(value) {
    if (value === undefined) return 'undefined';
    if (value === null) return 'null';
    if (typeof value === 'boolean') return value ? 'true' : 'false';
    if (typeof value === 'number') return `the number ${value}`;
    if (typeof value === 'string') return `the string "${value.length > 40 ? `${value.slice(0, 40)}…` : value}"`;
    if (typeof value === 'function') return 'a function';
    if (this._isOperation(value)) return 'an operation';
    if (Array.isArray(value)) return 'an array';
    const {SlateWindow, SlateApplication, SlateScreen} = this._api.classes;
    if (value instanceof SlateWindow) return 'a window';
    if (value instanceof SlateApplication) return 'an app';
    if (value instanceof SlateScreen) return 'a screen';
    return 'an object';
  }

  // --- Value helpers -------------------------------------------------------------------------------

  _isWrapper(value) {
    if (value === null || typeof value !== 'object') return false;
    const {SlateOperation, SlateWindow, SlateApplication, SlateScreen} = this._api.classes;
    return [SlateOperation, SlateWindow, SlateApplication, SlateScreen].some((c) => value instanceof c);
  }

  /** An object literal (or similar), as opposed to arrays, functions and API objects. */
  _isPlainObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value) && !this._isWrapper(value);
  }

  _isOperation(value) {
    return value instanceof this._api.classes.SlateOperation;
  }

  _staticAction(operation) {
    return this._isOperation(operation) && operation.__kind === 'action' ? operation.__action : null;
  }

  /** A JavaScript number as an integer, or null for non-numbers and values too large to be an index. */
  _intValue(value) {
    if (typeof value !== 'number' || !Number.isFinite(value) || Math.abs(value) >= 9007199254740992) return null;
    return Math.trunc(value);
  }

  /** Slate stores config values as text; arrays become `;`-separated lists. */
  _settingValue(value) {
    if (typeof value === 'boolean' || typeof value === 'string') return value;
    if (typeof value === 'number') return Number.isFinite(value) ? value : null;
    if (Array.isArray(value)) return value.map((v) => String(v ?? '')).join(';');
    return null;
  }

  _format(action) {
    try {
      return this.core.formatOperation(action);
    } catch {
      return action?.op ?? 'operation';
    }
  }

  _register(callback) {
    const id = this._nextCallbackId++;
    this._callbacks.set(id, callback);
    return id;
  }

  // --- The API objects -------------------------------------------------------------------------------

  _makeAPI() {
    const engine = this;
    const defineHidden = (object, key, value) => Object.defineProperty(object, key, {value});
    // Slate's short names, e.g. `S.op` for `S.operation` or `win.tl()` for `win.topLeft()`.
    const addAliases = (target, aliases, enumerable) => {
      for (const short of Object.keys(aliases)) {
        Object.defineProperty(target, short, {
          value: target[aliases[short]],
          enumerable: !!enumerable,
          writable: true,
          configurable: true,
        });
      }
    };

    class SlateOperation {
      constructor(name) {
        Object.defineProperty(this, 'name', {value: name, enumerable: true});
      }
      run() {
        return engine._runOperation(this, engine.host.focusedWindow());
      }
      dup(params) {
        return engine._dupOperation(this, params);
      }
      toString() {
        return `[SlateOperation ${this.name}]`;
      }
    }

    class SlateWindow {
      constructor(handle) {
        defineHidden(this, '__handle', handle);
      }
      title() {
        return engine._windowInfo(this.__handle)?.title;
      }
      topLeft() {
        const info = engine._windowInfo(this.__handle);
        return info ? {x: integer(info.frame.x), y: integer(info.frame.y)} : undefined;
      }
      size() {
        const info = engine._windowInfo(this.__handle);
        return info ? {width: integer(info.frame.width), height: integer(info.frame.height)} : undefined;
      }
      rect() {
        const info = engine._windowInfo(this.__handle);
        return info ? engine._rectObject(info.frame) : undefined;
      }
      pid() {
        return engine._windowInfo(this.__handle)?.pid;
      }
      focus() {
        return engine._windowInfo(this.__handle) ? !!engine.host.focus(this.__handle) : false;
      }
      isMinimizedOrHidden() {
        return !!engine._windowInfo(this.__handle)?.isMinimizedOrHidden;
      }
      isMain() {
        return !!engine._windowInfo(this.__handle)?.isMain;
      }
      isMovable() {
        const info = engine._windowInfo(this.__handle);
        return !!info && info.isMovable !== false;
      }
      isResizable() {
        const info = engine._windowInfo(this.__handle);
        return !!info && info.isResizable !== false;
      }
      move(point) {
        return engine._windowMove(this.__handle, point);
      }
      resize(size) {
        return engine._windowResize(this.__handle, size);
      }
      screen() {
        const info = engine._windowInfo(this.__handle);
        return info ? engine._screenObjectContaining(info.frame) : undefined;
      }
      app() {
        const info = engine._windowInfo(this.__handle);
        return info ? engine._appObject(engine._hostApp(info.pid) ?? {pid: info.pid, name: ''}) : undefined;
      }
      doOperation(operation, params) {
        return engine._windowDoOperation(this.__handle, operation, params);
      }
    }
    addAliases(SlateWindow.prototype, {
      tl: 'topLeft',
      hidden: 'isMinimizedOrHidden',
      main: 'isMain',
      movable: 'isMovable',
      resizable: 'isResizable',
      doop: 'doOperation',
    });

    class SlateApplication {
      constructor(pid, name) {
        defineHidden(this, '__pid', pid);
        defineHidden(this, '__name', name);
      }
      pid() {
        return this.__pid;
      }
      name() {
        return engine._hostApp(this.__pid)?.name ?? this.__name;
      }
      eachWindow(callback) {
        return engine._appEachWindow(this.__pid, callback);
      }
      mainWindow() {
        const handle = engine._hostMainWindow(this.__pid);
        return isNullish(handle) ? undefined : engine._windowObject(handle);
      }
      toString() {
        return String(this.name());
      }
    }
    addAliases(SlateApplication.prototype, {ewindow: 'eachWindow', mwindow: 'mainWindow'});

    class SlateScreen {
      constructor(id) {
        defineHidden(this, '__id', id);
      }
      id() {
        return this.__id;
      }
      rect() {
        const screen = engine._screenWithId(this.__id);
        return screen ? engine._rectObject(screen.frame) : undefined;
      }
      visibleRect() {
        const screen = engine._screenWithId(this.__id);
        return screen ? engine._rectObject(screen.visibleFrame) : undefined;
      }
      isMain() {
        return !!engine._screenWithId(this.__id)?.isMain;
      }
      toString() {
        return String(this.__id);
      }
    }
    addAliases(SlateScreen.prototype, {vrect: 'visibleRect', main: 'isMain'});

    // Questions about windows, apps and screens. Slate offers them as `S.info` and directly on `S`.
    const info = {
      window() {
        const handle = engine._currentWindow();
        return isNullish(handle) ? undefined : engine._windowObject(handle);
      },
      app() {
        const app = engine._currentApp();
        return app ? engine._appObject(app) : undefined;
      },
      screen() {
        const handle = engine._currentWindow();
        const frame = isNullish(handle) ? null : engine.host.windowInfo(handle)?.frame ?? null;
        return engine._screenObjectContaining(frame);
      },
      eachApp(callback) {
        return engine._eachApp(callback);
      },
      windowUnderPoint(point) {
        return engine._windowUnderPoint(point);
      },
      screenUnderPoint(point) {
        return engine._screenUnderPoint(point);
      },
      isRectOffScreen(rect) {
        return engine._isRectOffScreen(rect);
      },
      isPointOffScreen(point) {
        return engine._isPointOffScreen(point);
      },
      screenForRef(ref) {
        return engine._screenForRef(ref);
      },
      screenCount() {
        return engine.host.screens().length;
      },
      eachScreen(callback) {
        return engine._eachScreen(callback);
      },
    };
    addAliases(
      info,
      {
        eapp: 'eachApp',
        wup: 'windowUnderPoint',
        sup: 'screenUnderPoint',
        rectoff: 'isRectOffScreen',
        pntoff: 'isPointOffScreen',
        screenr: 'screenForRef',
        screenc: 'screenCount',
        escreen: 'eachScreen',
      },
      true,
    );

    const slate = Object.assign(
      {
        log(...parts) {
          engine.host.log(parts.map((p) => String(p)).join(' '));
        },
        config(name, value) {
          engine._config(name, value);
        },
        configAll(values) {
          engine._configAll(values);
        },
        bind(keystroke, target, repeat) {
          engine._bind(keystroke, target, repeat);
        },
        bindAll(bindings) {
          engine._bindAll(bindings);
        },
        operation(name, params) {
          return engine._operation(name, params);
        },
        operationFromString(text) {
          if (typeof text !== 'string') {
            engine._report('error', `slate.operationFromString needs a string like "push left bar", got ${engine._describe(text)}.`);
            return undefined;
          }
          return engine._operationFromString(text) ?? undefined;
        },
        doOperation(name, params) {
          const operation = engine._operationArgument(name, params, 'slate.doOperation');
          return operation ? engine._runOperation(operation, engine.host.focusedWindow()) : false;
        },
        source(path) {
          return engine._source(path);
        },
        layout(name, apps) {
          return engine._layout(name, apps);
        },
        default(screens, target) {
          engine._default(screens, target);
        },
        shell(command, wait, path) {
          return engine._shell(command, wait, path);
        },
        on(event, callback) {
          engine._on(event, callback);
        },
        info,
      },
      info,
    );
    addAliases(
      slate,
      {
        cfg: 'config',
        cfga: 'configAll',
        bnd: 'bind',
        bnda: 'bindAll',
        op: 'operation',
        opstr: 'operationFromString',
        doop: 'doOperation',
        src: 'source',
        lay: 'layout',
        def: 'default',
        sh: 'shell',
      },
      true,
    );

    // Slate ran configs in a web view, where the global object is `window`, and preloaded underscore.js.
    const scriptGlobal = {slate, S: slate, _: makeUnderscore()};
    scriptGlobal.window = scriptGlobal;
    return {slate, _: scriptGlobal._, scriptGlobal, classes: {SlateOperation, SlateWindow, SlateApplication, SlateScreen}};
  }

  _windowObject(handle) {
    return new this._api.classes.SlateWindow(handle);
  }

  _appObject(app) {
    return new this._api.classes.SlateApplication(app.pid, app.name ?? '');
  }

  _screenObject(id) {
    return new this._api.classes.SlateScreen(id);
  }

  _rectObject(rect) {
    return {x: integer(rect.x), y: integer(rect.y), width: integer(rect.width), height: integer(rect.height)};
  }

  _windowInfo(handle) {
    if (isNullish(handle)) return null;
    return this.host.windowInfo(handle) ?? null;
  }

  // --- Host defaults (like the Swift ScriptHost protocol extension) --------------------------------

  _hostApp(pid) {
    if (typeof this.host.app === 'function') return this.host.app(pid) ?? null;
    return this.host.runningApps().find((a) => a.pid === pid) ?? null;
  }

  _hostMainWindow(pid) {
    if (typeof this.host.mainWindow === 'function') return this.host.mainWindow(pid);
    const windows = this.host.windows(pid);
    return windows.find((w) => this.host.windowInfo(w)?.isMain) ?? windows[0] ?? null;
  }

  _hostFrontmostApp() {
    if (typeof this.host.frontmostApp === 'function') return this.host.frontmostApp();
    const focused = this.host.focusedWindow();
    const info = isNullish(focused) ? null : this.host.windowInfo(focused);
    return (info && this._hostApp(info.pid)) ?? this.host.runningApps()[0] ?? null;
  }

  _hostWindowAt(point) {
    if (typeof this.host.windowAt === 'function') return this.host.windowAt(point);
    for (const app of this.host.runningApps()) {
      for (const window of this.host.windows(app.pid)) {
        const info = this.host.windowInfo(window);
        if (!info || info.isMinimizedOrHidden) continue;
        const f = info.frame;
        if (point.x >= f.x && point.x < f.x + f.width && point.y >= f.y && point.y < f.y + f.height) return window;
      }
    }
    return null;
  }

  /** `slate.app()`: the current window's app, else the frontmost app. */
  _currentApp() {
    const window = this._currentWindow();
    const info = isNullish(window) ? null : this.host.windowInfo(window);
    if (info) {
      const app = this._hostApp(info.pid);
      if (app) return app;
    }
    return this._hostFrontmostApp();
  }

  // --- Screens -------------------------------------------------------------------------------------

  /** Screens numbered the way scripts see them: left to right unless `orderScreensLeftToRight` is off. */
  _orderedScreens() {
    const screens = this.host.screens();
    const leftToRight = this._settings.orderScreensLeftToRight;
    return leftToRight === undefined || truthy(leftToRight) ? orderedLeftToRight(screens) : screens;
  }

  _screenWithId(value) {
    const id = this._intValue(value);
    if (id === null) return null;
    const screens = this._orderedScreens();
    return id >= 0 && id < screens.length ? screens[id] : null;
  }

  _screenObjectFor(screen) {
    const index = this._orderedScreens().findIndex((s) => s.displayID === screen.displayID);
    return index >= 0 ? this._screenObject(index) : undefined;
  }

  /** The screen holding most of `frame`; the main screen when there is no frame. */
  _screenObjectContaining(frame) {
    const screen = screenContaining(this.host.screens(), frame);
    return screen ? this._screenObjectFor(screen) : undefined;
  }

  _resolveScreen(ref, frame) {
    try {
      return this.core.resolveScreen(ref, {frame, screens: this.host.screens(), settings: this._settings}) ?? null;
    } catch (e) {
      this._report('error', `Can't resolve the screen "${ref}": ${errorText(e)}`);
      return null;
    }
  }

  static _isOnScreen(point, screens) {
    // Edges count as on screen, as in Slate.
    return screens.some(
      (s) => point.x >= s.frame.x && point.x <= s.frame.x + s.frame.width && point.y >= s.frame.y && point.y <= s.frame.y + s.frame.height,
    );
  }

  _eachScreen(callback) {
    if (typeof callback !== 'function') {
      this._report('error', `slate.eachScreen needs a function, got ${this._describe(callback)}.`);
      return;
    }
    const count = this._orderedScreens().length;
    for (let id = 0; id < count; id++) callback(this._screenObject(id));
  }

  _screenForRef(value) {
    let text;
    const number = this._intValue(value);
    if (number !== null) text = String(number);
    else if (typeof value === 'string') text = value;
    else {
      this._report('error', `slate.screenForRef needs a screen reference like "0", "right" or "1920x1080", got ${this._describe(value)}.`);
      return undefined;
    }
    const handle = this._currentWindow();
    const frame = (isNullish(handle) ? null : this.host.windowInfo(handle)?.frame) ?? {x: 0, y: 0, width: 0, height: 0};
    const screen = this._resolveScreen(text, frame);
    return screen ? this._screenObjectFor(screen) : undefined;
  }

  _windowUnderPoint(point) {
    const window = this._windowInfo(this._currentWindow());
    const xy = this._numbers(point, ['x', 'y'], window, 'slate.windowUnderPoint');
    if (!xy) return undefined;
    const handle = this._hostWindowAt({x: xy[0], y: xy[1]});
    return isNullish(handle) ? undefined : this._windowObject(handle);
  }

  _screenUnderPoint(point) {
    const xy = this._numbers(point, ['x', 'y'], this._windowInfo(this._currentWindow()), 'slate.screenUnderPoint');
    if (!xy) return undefined;
    const screen = this.host.screens().find((s) => SlateScriptEngine._isOnScreen({x: xy[0], y: xy[1]}, [s]));
    return screen ? this._screenObjectFor(screen) : undefined;
  }

  _isPointOffScreen(point) {
    const xy = this._numbers(point, ['x', 'y'], this._windowInfo(this._currentWindow()), 'slate.isPointOffScreen');
    if (!xy) return false;
    return !SlateScriptEngine._isOnScreen({x: xy[0], y: xy[1]}, this.host.screens());
  }

  _isRectOffScreen(rect) {
    const window = this._windowInfo(this._currentWindow());
    const xy = this._numbers(rect, ['x', 'y'], window, 'slate.isRectOffScreen');
    if (!xy) return false;
    const size = this._numbers(rect, ['width', 'height'], window, 'slate.isRectOffScreen');
    if (!size) return false;
    const [x, y] = xy;
    const [w, h] = size;
    const screens = this.host.screens();
    // Off screen when any corner is outside every screen.
    return [
      {x, y},
      {x: x + w, y},
      {x, y: y + h},
      {x: x + w, y: y + h},
    ].some((corner) => !SlateScriptEngine._isOnScreen(corner, screens));
  }

  // --- Apps ----------------------------------------------------------------------------------------

  _eachApp(callback) {
    if (typeof callback !== 'function') {
      this._report('error', `slate.eachApp needs a function, got ${this._describe(callback)}.`);
      return;
    }
    for (const app of this.host.runningApps()) callback(this._appObject(app));
  }

  _appEachWindow(pid, callback) {
    if (typeof pid !== 'number') return;
    const windows = this.host.windows(pid);
    const operation = this._operationObject(callback, 'app.eachWindow');
    if (!operation) return;
    for (const window of windows) this._runOperation(operation, window);
  }

  // --- Windows -------------------------------------------------------------------------------------

  _windowMove(handle, point) {
    const info = this._windowInfo(handle);
    if (!info) return false;
    const xy = this._numbers(point, ['x', 'y'], info, 'win.move');
    if (!xy) return false;
    return !!this.host.setFrame({x: xy[0], y: xy[1], width: info.frame.width, height: info.frame.height}, handle);
  }

  _windowResize(handle, size) {
    const info = this._windowInfo(handle);
    if (!info) return false;
    const wh = this._numbers(size, ['width', 'height'], info, 'win.resize');
    if (!wh) return false;
    return !!this.host.setFrame({x: info.frame.x, y: info.frame.y, width: wh[0], height: wh[1]}, handle);
  }

  _windowDoOperation(handle, operation, params) {
    if (isNullish(handle)) return false;
    const resolved = this._operationArgument(operation, params, 'win.doOperation');
    return resolved ? this._runOperation(resolved, handle) : false;
  }

  /**
   * Reads two numbers from an object like `{x: 10, y: "screenOriginY+20"}`: numbers, or Slate
   * expressions evaluated against `window` and its screen (or the object's `screen` reference).
   */
  _numbers(value, keys, window, caller) {
    if (!this._isPlainObject(value)) {
      this._report('error', `${caller} needs an object like {${keys[0]}: 0, ${keys[1]}: 0}, got ${this._describe(value)}.`);
      return null;
    }
    let variables = null;
    const number = (key) => {
      const item = value[key];
      let result = null;
      if (typeof item === 'number') {
        result = item;
      } else if (typeof item === 'string') {
        variables ??= this._expressionVariables(window, value.screen);
        try {
          result = this.core.evaluateExpression(item, variables);
        } catch (e) {
          this._report('error', `${caller}: can't evaluate "${item}": ${errorText(e)}`);
          return null;
        }
      }
      if (typeof result !== 'number' || !Number.isFinite(result)) {
        this._report('error', `${caller} needs "${key}" as a number or an expression, got ${this._describe(item)}.`);
        return null;
      }
      return result;
    };
    const first = number(keys[0]);
    if (first === null) return null;
    const second = number(keys[1]);
    if (second === null) return null;
    return [first, second];
  }

  /** Slate's expression variables: the screen's visible frame and the window's frame. */
  _expressionVariables(window, screenRef) {
    const screens = this.host.screens();
    const frame = window?.frame ?? {x: 0, y: 0, width: 0, height: 0};
    let screen = screenContaining(screens, frame);
    if (!isNullish(screenRef)) {
      const text = this._intValue(screenRef) !== null ? String(this._intValue(screenRef)) : String(screenRef);
      screen = this._resolveScreen(text, frame) ?? screen;
    }
    const visible = screen?.visibleFrame ?? {x: 0, y: 0, width: 0, height: 0};
    return {
      screenOriginX: integer(visible.x),
      screenOriginY: integer(visible.y),
      screenSizeX: integer(visible.width),
      screenSizeY: integer(visible.height),
      windowTopLeftX: integer(frame.x),
      windowTopLeftY: integer(frame.y),
      windowSizeX: integer(frame.width),
      windowSizeY: integer(frame.height),
      newWindowSizeX: integer(frame.width),
      newWindowSizeY: integer(frame.height),
    };
  }

  // --- config --------------------------------------------------------------------------------------

  _config(name, value) {
    if (typeof name !== 'string') {
      this._report('error', `slate.config needs a setting name (a string), got ${this._describe(name)}.`);
      return;
    }
    this._setConfig(name, value);
  }

  _configAll(values) {
    if (!this._isPlainObject(values)) {
      this._report('error', `slate.configAll needs an object like {"defaultToCurrentScreen": true}, got ${this._describe(values)}.`);
      return;
    }
    for (const name of Object.keys(values)) this._setConfig(name, values[name]);
  }

  _setConfig(name, value) {
    if (typeof value === 'function') {
      // Like Slate, a function is asked for the value whenever the setting is read.
      this._configFunctions.set(name, value);
      return;
    }
    const setting = this._settingValue(value);
    if (setting === null) {
      this._report('error', `slate.config("${name}", …) needs a string, number, boolean, array or function, got ${this._describe(value)}.`);
      return;
    }
    this._configFunctions.delete(name);
    this._settings[name] = setting;
  }

  // --- bind ----------------------------------------------------------------------------------------

  _bind(keystroke, target, repeat) {
    if (!this._isLoading) {
      this._report('warning', 'slate.bind only works while the config loads, so this binding was ignored.');
      return;
    }
    if (typeof keystroke !== 'string') {
      this._report('error', `slate.bind needs a keystroke like "a:ctrl,shift", got ${this._describe(keystroke)}.`);
      return;
    }
    let keys;
    let modal;
    try {
      const parsed = this.core.parseKeystroke(keystroke);
      keys = comboOf(parsed.keys, this.core);
      modal = parsed.modal ? modalOf(parsed.modal, this.core) : null;
    } catch (e) {
      this._report('error', `Can't bind "${keystroke}": ${errorText(e)}`);
      return;
    }
    if (!keys) {
      this._report('error', `Can't bind "${keystroke}": unknown key`);
      return;
    }
    const resolved = this._scriptTarget(target, `slate.bind("${keystroke}", …)`);
    if (!resolved) return;
    const location = this._callerLocation();
    const id = bindingKey(keys, modal, this.core);
    const earlier = this._pending.find((p) => p.id === id);
    if (earlier) {
      const place = earlier.binding.line ? ` (first on line ${earlier.binding.line})` : '';
      this._report('warning', `"${keystroke}" is bound more than once${place}.`, location);
    }
    this._pending.push({
      id,
      binding: {
        id,
        keystroke,
        keys,
        modal,
        target: resolved.target,
        summary: resolved.summary,
        file: location.file ?? undefined,
        line: location.line ?? undefined,
      },
      explicitRepeat: isNullish(repeat) ? null : truthy(repeat),
      operationName: resolved.operationName,
    });
  }

  _bindAll(bindings) {
    if (!this._isPlainObject(bindings)) {
      this._report('error', `slate.bindAll needs an object mapping keystrokes to operations, got ${this._describe(bindings)}.`);
      return;
    }
    for (const keystroke of Object.keys(bindings)) {
      const value = bindings[keystroke];
      // [operation] or [operation, repeat]
      if (Array.isArray(value)) this._bind(keystroke, value[0], value.length > 1 ? value[1] : undefined);
      else this._bind(keystroke, value, undefined);
    }
  }

  // --- Operations ----------------------------------------------------------------------------------

  _operation(name, params) {
    if (typeof name !== 'string') {
      this._report('error', `slate.operation needs an operation name like "move", got ${this._describe(name)}.`);
      return undefined;
    }
    return this._makeOperation(name, params) ?? undefined;
  }

  _newOperation(name, kind, params = null) {
    const operation = new this._api.classes.SlateOperation(name);
    const hide = (key, value) => Object.defineProperty(operation, key, {value});
    hide('__id', this._nextOperationId++);
    hide('__kind', kind.kind);
    if (kind.kind === 'action') hide('__action', kind.action);
    if (kind.kind === 'function') hide('__function', kind.fn);
    if (kind.kind === 'chain') hide('__items', kind.items);
    if (kind.kind === 'sequence') hide('__groups', kind.groups);
    if (!isNullish(params)) hide('__params', params);
    return operation;
  }

  /**
   * `slate.operation(name, params)`: validates the parameters by decoding them into an Action, the
   * same JSON shape Slated's own config uses.
   */
  _makeOperation(name, rawParams, ignoring = new Set()) {
    const known = OPERATION_PARAMETERS[name];
    if (!known) {
      this._report('error', `Unknown operation "${name}".`);
      return null;
    }
    let params;
    if (isNullish(rawParams)) params = {};
    else if (this._isPlainObject(rawParams)) params = rawParams;
    else {
      this._report('error', `The parameters of "${name}" must be an object like {"direction": "left"}, got ${this._describe(rawParams)}.`);
      return null;
    }
    const entries = Object.keys(params)
      .filter((key) => !ignoring.has(key))
      .map((key) => [key, params[key]]);
    for (const [key] of entries) {
      if (!known.has(key)) this._report('warning', `"${name}" has no parameter "${key}", so it was ignored.`);
    }
    if (name === 'chain') return this._makeChain(params);
    if (name === 'sequence') return this._makeSequence(params);
    if (entries.some(([, value]) => typeof value === 'function')) {
      // Slate evaluates function parameters each time the operation runs.
      return this._newOperation(name, {kind: 'dynamic'}, params);
    }
    try {
      return this._newOperation(name, {kind: 'action', action: this._decodeAction(name, entries)}, params);
    } catch (e) {
      this._report('error', `Invalid "${name}" operation: ${errorText(e)}.`);
      return null;
    }
  }

  _makeChain(params) {
    const list = params.operations;
    if (!Array.isArray(list) || list.length === 0) {
      this._report('error', `"chain" needs "operations": an array of operations, got ${this._describe(list)}.`);
      return null;
    }
    const items = [];
    for (const [index, value] of list.entries()) {
      const item = this._operationObject(value, `Chain operation ${index + 1}`);
      if (!item) return null;
      items.push(item);
    }
    const actions = items.map((item) => this._staticAction(item));
    if (actions.every(Boolean)) return this._newOperation('chain', {kind: 'action', action: {op: 'chain', operations: actions}}, params);
    return this._newOperation('chain', {kind: 'chain', items}, params);
  }

  /**
   * Slate's JavaScript sequences list steps; a step that is an array runs its operations on the same
   * window, like `>` in Slate's operation syntax.
   */
  _makeSequence(params) {
    const list = params.operations;
    if (!Array.isArray(list) || list.length === 0) {
      this._report('error', `"sequence" needs "operations": an array of operations, got ${this._describe(list)}.`);
      return null;
    }
    const groups = [];
    for (const [index, value] of list.entries()) {
      const group = [];
      for (const member of Array.isArray(value) ? value : [value]) {
        const item = this._operationObject(member, `Sequence step ${index + 1}`);
        if (!item) return null;
        group.push(item);
      }
      if (group.length) groups.push(group);
    }
    const steps = [];
    for (const group of groups) {
      for (const [index, item] of group.entries()) {
        const action = this._staticAction(item);
        if (!action) return this._newOperation('sequence', {kind: 'sequence', groups}, params);
        steps.push({action, keepWindow: index > 0});
      }
    }
    const action = steps.every((s) => !s.keepWindow)
      ? {op: 'sequence', operations: steps.map((s) => s.action)}
      : {op: 'sequence', steps};
    return this._newOperation('sequence', {kind: 'action', action}, params);
  }

  /** `slate.operationFromString`: Slate's operation syntax, parsed by the core. */
  _operationFromString(text) {
    try {
      const action = this.core.parseOperation(text);
      return this._newOperation(action.op, {kind: 'action', action});
    } catch (e) {
      this._report('error', `Can't parse the operation "${text}": ${errorText(e)}`);
      return null;
    }
  }

  /**
   * Accepts what Slated treats as an operation: an operation object, a function, a string in Slate's
   * operation syntax, or an object with an `op` name and parameters.
   */
  _operationObject(value, caller) {
    if (this._isOperation(value)) return value;
    if (typeof value === 'function') return this._newOperation('js', {kind: 'function', fn: value});
    if (typeof value === 'string') return this._operationFromString(value);
    if (this._isPlainObject(value) && typeof value.op === 'string') return this._makeOperation(value.op, value, new Set(['op']));
    const location = this._callerLocation();
    // Usually `slate.operation(...)` failed on this same line and already said why.
    if (isNullish(value) && this._hasError(location)) return null;
    this._report('error', `${caller} needs an operation or a function, got ${this._describe(value)}.`, location);
    return null;
  }

  /** `doOperation(op)`, `doOperation("push", {...})`, or `doOperation("push left")`. */
  _operationArgument(value, params, caller) {
    if (typeof value === 'string') {
      if (!isNullish(params) || OPERATION_PARAMETERS[value]) return this._makeOperation(value, params);
      return this._operationFromString(value);
    }
    return this._operationObject(value, caller);
  }

  /** What a binding, layout step or default runs. */
  _scriptTarget(value, caller) {
    const operation = this._operationObject(value, caller);
    if (!operation) return null;
    switch (operation.__kind) {
      case 'action':
        return {
          target: {kind: 'action', action: operation.__action},
          summary: this._format(operation.__action),
          operationName: operation.__action.op,
        };
      case 'function':
        return {
          target: {kind: 'callback', id: this._register({kind: 'function', fn: operation.__function})},
          summary: 'JavaScript function',
          operationName: 'js',
        };
      default:
        return {
          target: {kind: 'callback', id: this._register({kind: 'operation', operation})},
          summary: `${operation.name} (with JavaScript)`,
          operationName: operation.name,
        };
    }
  }

  /** Runs an operation on `window` (null: no window). Returns false if it failed. */
  _runOperation(operation, window) {
    if (!this._isOperation(operation)) {
      this._report('error', `Expected an operation, got ${this._describe(operation)}.`);
      return false;
    }
    switch (operation.__kind) {
      case 'action':
        return !!this.host.perform(operation.__action, window ?? null);
      case 'function':
        return this._callFunction(operation.__function, window);
      case 'chain': {
        const items = operation.__items;
        if (!items.length) return false;
        const positions = this._chainPositions.get(operation.__id) ?? new Map();
        const key = window ?? null;
        const index = (positions.get(key) ?? 0) % items.length;
        positions.set(key, (index + 1) % items.length);
        this._chainPositions.set(operation.__id, positions);
        return this._runOperation(items[index], window);
      }
      case 'sequence': {
        let success = true;
        for (const group of operation.__groups) {
          // Like Slate, each step acts on whatever is focused when it starts.
          const target = this.host.focusedWindow();
          for (const item of group) success = this._runOperation(item, target) && success;
        }
        return success;
      }
      case 'dynamic': {
        const action = this._resolveDynamic(operation.name, operation.__params ?? {}, window);
        return action ? !!this.host.perform(action, window ?? null) : false;
      }
      default:
        return false;
    }
  }

  /** Calls a function the way Slate calls bound functions and layout steps: with the window object. */
  _callFunction(fn, window) {
    return this._withWindow(window, () => {
      fn(isNullish(window) ? undefined : this._windowObject(window));
      return true;
    });
  }

  _resolveDynamic(name, params, window) {
    const entries = [];
    for (const key of Object.keys(params)) {
      if (key === 'op') continue;
      let value = params[key];
      if (typeof value === 'function') {
        const fn = value;
        value = this._withWindow(window, () => fn());
      }
      entries.push([key, value]);
    }
    try {
      return this._decodeAction(name, entries);
    } catch (e) {
      this._report('error', `Invalid "${name}" operation: ${errorText(e)}.`);
      return null;
    }
  }

  _dupOperation(operation, changes) {
    if (!this._isOperation(operation)) {
      this._report('error', 'dup only works on operations.');
      return undefined;
    }
    if (!this._isPlainObject(changes)) {
      this._report(
        'error',
        `operation.dup needs an object with the parameters to change, like {"width": "screenSizeX/3"}, got ${this._describe(changes)}.`,
      );
      return undefined;
    }
    let base;
    if (operation.__params && typeof operation.__params === 'object') base = operation.__params;
    else if (operation.__kind === 'action') base = operation.__action; // Made from a string: its JSON form.
    else {
      this._report('error', "This operation is a JavaScript function, so it can't be duplicated.");
      return undefined;
    }
    return this._makeOperation(operation.name, Object.assign({}, base, changes), new Set(['op'])) ?? undefined;
  }

  /** Builds `{op: name, ...params}` and has the core decode it. */
  _decodeAction(name, entries) {
    const known = OPERATION_PARAMETERS[name] ?? new Set();
    const object = {op: name};
    for (const [key, value] of entries) {
      if (!known.has(key)) continue;
      const json = this._jsonValue(value, key);
      if (json === undefined) continue;
      object[key] = coerceParameter(json, key);
    }
    return normalizeAction(this.core, object);
  }

  /** A JSON value for a parameter, or undefined to leave it out (`undefined`, `null`). */
  _jsonValue(value, key, depth = 0) {
    if (depth >= 32) throw new Error(`"${key}" is nested too deeply`);
    if (isNullish(value)) return undefined;
    if (typeof value === 'boolean' || typeof value === 'string') return value;
    if (typeof value === 'number') {
      // Also keeps the decoder away from numbers it can't convert.
      if (!Number.isFinite(value) || Math.abs(value) >= 1e15) throw new Error(`"${key}" is out of range`);
      return value;
    }
    if (this._isOperation(value)) {
      const action = this._staticAction(value);
      if (!action) throw new Error(`"${key}" can't hold an operation that runs JavaScript`);
      return action;
    }
    if (typeof value === 'function') throw new Error(`"${key}" can't be a function here`);
    const {SlateWindow, SlateApplication, SlateScreen} = this._api.classes;
    // Slate passes screens by their ID and apps by their name.
    if (value instanceof SlateScreen) return value.__id;
    if (value instanceof SlateApplication) return value.__name;
    if (value instanceof SlateWindow) throw new Error(`"${key}" can't be a window`);
    if (Array.isArray(value)) {
      return value.slice(0, 10_000).map((item) => this._jsonValue(item, key, depth + 1)).filter((item) => item !== undefined);
    }
    if (typeof value === 'object') {
      const out = {};
      for (const name of Object.keys(value)) {
        const json = this._jsonValue(value[name], name, depth + 1);
        if (json !== undefined) out[name] = json;
      }
      return out;
    }
    return String(value);
  }

  // --- source --------------------------------------------------------------------------------------

  _source(raw) {
    if (typeof raw !== 'string') {
      this._report('error', `slate.source needs a file path (a string), got ${this._describe(raw)}.`);
      return false;
    }
    // Slate resolves relative paths against the home folder.
    const path = raw.startsWith('/') ? raw : expandHome(raw.startsWith('~') ? raw : `~/${raw}`, this.home);
    if (this._loadingFiles.includes(path)) {
      this._report('error', `${raw} is already loading, so slate.source skipped it to avoid a loop.`);
      return false;
    }
    const text = this.readFile(path);
    if (text === null || text === undefined) {
      this._report('warning', `Couldn't read ${raw}, so slate.source skipped it.`);
      return false;
    }
    if (!this._sourcedFiles.includes(path)) this._sourcedFiles.push(path);
    if (path.endsWith('.js')) {
      this._loadingFiles.push(path);
      try {
        return this._evaluate(text, path);
      } finally {
        this._loadingFiles.pop();
      }
    }
    let file;
    try {
      file = this.core.parseSlateConfig(text, {path, readFile: this.readFile, homeDirectory: this.home});
    } catch (e) {
      this._report('error', `Couldn't read ${raw}: ${errorText(e)}`);
      return false;
    }
    this._merge(file, path);
    return !(file.diagnostics ?? []).some((d) => d.severity === 'error');
  }

  /** Adds what a classic `.slate` file defines. */
  _merge(file, path) {
    Object.assign(this._settings, file.settings ?? {});
    for (const binding of file.bindings ?? []) {
      if (binding.enabled === false) continue;
      let keys;
      let modal;
      try {
        keys = comboOf(binding.keys, this.core);
        modal = binding.modal ? modalOf(binding.modal, this.core) : null;
      } catch {
        continue;
      }
      if (!keys) continue;
      const id = bindingKey(keys, modal, this.core);
      this._pending.push({
        id,
        binding: {
          id,
          keystroke: id,
          keys,
          modal,
          target: {kind: 'action', action: binding.action},
          summary: this._format(binding.action),
          file: path,
        },
        explicitRepeat: typeof binding.repeats === 'boolean' ? binding.repeats : null,
        operationName: binding.action?.op ?? '',
      });
    }
    for (const layout of file.layouts ?? []) {
      this._addLayout({
        name: layout.name,
        apps: (layout.apps ?? []).map((app) => ({
          app: app.app,
          operations: (app.operations ?? []).map((action) => ({kind: 'action', action})),
          options: app.options ?? {},
        })),
        before: (layout.before ?? []).map((action) => ({kind: 'action', action})),
        after: (layout.after ?? []).map((action) => ({kind: 'action', action})),
      });
    }
    for (const entry of file.defaults ?? []) {
      if (typeof entry?.target === 'string') this._defaults.push({condition: entry.condition, target: {name: entry.target}});
    }
    this._diagnostics.push(...(file.diagnostics ?? []));
  }

  // --- layout --------------------------------------------------------------------------------------

  _layout(name, apps) {
    if (typeof name !== 'string') {
      this._report('error', `slate.layout needs a layout name (a string), got ${this._describe(name)}.`);
      return undefined;
    }
    if (!this._isPlainObject(apps)) {
      this._report('error', `slate.layout("${name}", …) needs an object mapping app names to {"operations": …}, got ${this._describe(apps)}.`);
      return undefined;
    }
    const layout = {name, apps: [], before: [], after: []};
    for (const app of Object.keys(apps)) {
      const entry = apps[app];
      const operations = this._isPlainObject(entry) ? entry.operations : undefined;
      if (isNullish(operations)) {
        this._report('warning', `Layout "${name}": "${app}" has no "operations", so it was skipped.`);
        continue;
      }
      const values = Array.isArray(operations) ? operations : [operations];
      const targets = values
        .map((value, index) => this._scriptTarget(value, `Layout "${name}", "${app}" operation ${index + 1}`)?.target)
        .filter(Boolean);
      if (targets.length === 0) continue;
      if (app === '_before_') layout.before = targets;
      else if (app === '_after_') layout.after = targets;
      else layout.apps.push({app, operations: targets, options: this._layoutOptions(entry)});
    }
    this._addLayout(layout);
    return name;
  }

  _addLayout(layout) {
    const index = this._layouts.findIndex((l) => l.name === layout.name);
    if (index >= 0) this._layouts[index] = layout;
    else this._layouts.push(layout);
  }

  _layoutOptions(entry) {
    const flag = (key) => !isNullish(entry[key]) && truthy(entry[key]);
    const strings = (key) => {
      const value = entry[key];
      if (Array.isArray(value)) return value.filter((v) => typeof v === 'string');
      if (typeof value === 'string') return value.split(';').filter((v) => v.length > 0);
      return undefined;
    };
    const options = {
      ignoreFail: flag('ignore-fail'),
      repeat: flag('repeat'),
      repeatLast: flag('repeat-last'),
      mainFirst: flag('main-first'),
      mainLast: flag('main-last'),
      sortTitle: flag('sort-title'),
    };
    const titleOrder = strings('title-order');
    const titleOrderRegex = strings('title-order-regex');
    if (titleOrder) options.titleOrder = titleOrder;
    if (titleOrderRegex) options.titleOrderRegex = titleOrderRegex;
    return options;
  }

  // --- default -------------------------------------------------------------------------------------

  _default(screens, target) {
    let condition;
    if (typeof screens === 'number') {
      condition = {count: Math.trunc(screens)};
    } else if (typeof screens === 'string' && screens.trim()) {
      const text = screens.trim();
      if (/^-?\d+$/.test(text)) {
        condition = {count: Number(text)};
      } else {
        condition = {
          resolutions: text
            .split(/[;,]/)
            .map((s) => s.trim())
            .filter(Boolean)
            .sort(),
        };
      }
    } else if (Array.isArray(screens)) {
      condition = {resolutions: screens.filter((s) => typeof s === 'string').sort()};
    } else {
      this._report('error', `slate.default needs a screen count or an array of resolutions like ["1920x1080"], got ${this._describe(screens)}.`);
      return;
    }
    let defaultTarget;
    if (typeof target === 'string') {
      defaultTarget = {name: target};
    } else if (this._isOperation(target)) {
      const action = this._staticAction(target);
      defaultTarget = action?.op === 'layout' ? {name: action.name} : {callback: this._register({kind: 'operation', operation: target})};
    } else if (typeof target === 'function') {
      defaultTarget = {callback: this._register({kind: 'function', fn: target})};
    } else {
      this._report('error', `slate.default needs a layout name, an operation or a function, got ${this._describe(target)}.`);
      return;
    }
    this._defaults.push({condition, target: defaultTarget});
  }

  // --- shell, on -----------------------------------------------------------------------------------

  _shell(command, wait, path) {
    if (typeof command !== 'string') {
      this._report('error', `slate.shell needs a command (a string), got ${this._describe(command)}.`);
      return undefined;
    }
    let shouldWait = false;
    if (!isNullish(wait)) {
      if (typeof wait !== 'boolean') {
        this._report('error', `slate.shell's second argument (wait) must be true or false, got ${this._describe(wait)}.`);
        return undefined;
      }
      shouldWait = wait;
    }
    let directory = null;
    if (!isNullish(path)) {
      if (typeof path !== 'string') {
        this._report('error', `slate.shell's third argument (path) must be a string, got ${this._describe(path)}.`);
        return undefined;
      }
      directory = expandHome(path, this.home);
    }
    const output = this.host.runShell(command, shouldWait, directory);
    return output === null ? undefined : output;
  }

  _on(event, callback) {
    if (typeof event !== 'string' || !EVENT_NAMES.includes(event)) {
      this._report('error', `slate.on doesn't know the event ${this._describe(event)}. Use one of: ${EVENT_NAMES.join(', ')}.`);
      return;
    }
    if (typeof callback !== 'function') {
      this._report('error', `slate.on("${event}", …) needs a function, got ${this._describe(callback)}.`);
      return;
    }
    if (!this._eventHandlers.has(event)) this._eventHandlers.set(event, []);
    this._eventHandlers.get(event).push(callback);
  }

  // --- Callbacks and events --------------------------------------------------------------------------

  _runCallback(id, window) {
    const callback = this._callbacks.get(id);
    if (!callback) {
      this._report('error', 'This JavaScript binding is from an earlier load of the config. Reload Slated to use it.', {
        file: this._currentFile(),
        line: null,
      });
      return false;
    }
    if (callback.kind === 'function') return this._callFunction(callback.fn, window);
    return this._runOperation(callback.operation, window);
  }

  /** What Slate passed to event callbacks after the event name. */
  _eventPayload(event) {
    switch (event.name) {
      case 'windowOpened':
      case 'windowFocused':
      case 'windowTitleChanged':
        return isNullish(event.window) ? undefined : this._windowObject(event.window);
      case 'windowMoved':
      case 'windowResized': {
        const info = this._windowInfo(event.window);
        if (!info) return undefined;
        return this._appObject(this._hostApp(info.pid) ?? {pid: info.pid, name: ''});
      }
      case 'screenConfigurationChanged':
        return undefined;
      default:
        return event.app ? this._appObject(event.app) : undefined;
    }
  }
}

// --- underscore.js subset --------------------------------------------------------------------------

/** A small, independent subset of underscore.js's API, which Slate preloaded for configs. */
export function makeUnderscore() {
  const _ = {};
  const isArrayLike = (obj) => obj !== null && obj !== undefined && typeof obj !== 'function' && typeof obj.length === 'number';
  const pairsOf = (obj) => {
    if (obj === null || obj === undefined) return [];
    if (isArrayLike(obj)) return Array.prototype.map.call(obj, (value, index) => [value, index]);
    return Object.keys(obj).map((key) => [obj[key], key]);
  };
  const iteratee = (f) => {
    if (typeof f === 'function') return f;
    if (f === null || f === undefined) return (value) => value;
    return (value) => (value === null || value === undefined ? undefined : value[f]);
  };
  const slice = (list, start, end) => Array.prototype.slice.call(list || [], start, end);

  _.each = _.forEach = (obj, f, context) => {
    for (const [value, key] of pairsOf(obj)) f.call(context, value, key, obj);
    return obj;
  };
  _.map = _.collect = (obj, f, context) => {
    const g = iteratee(f);
    return pairsOf(obj).map(([value, key]) => g.call(context, value, key, obj));
  };
  _.filter = _.select = (obj, f, context) => {
    const g = iteratee(f);
    return pairsOf(obj)
      .filter(([value, key]) => g.call(context, value, key, obj))
      .map(([value]) => value);
  };
  _.reject = (obj, f, context) => {
    const g = iteratee(f);
    return _.filter(obj, (value, key, list) => !g.call(context, value, key, list));
  };
  _.find = _.detect = (obj, f, context) => {
    const g = iteratee(f);
    const hit = pairsOf(obj).find(([value, key]) => g.call(context, value, key, obj));
    return hit === undefined ? undefined : hit[0];
  };
  _.some = _.any = (obj, f, context) => {
    const g = iteratee(f);
    return pairsOf(obj).some(([value, key]) => g.call(context, value, key, obj));
  };
  _.every = _.all = (obj, f, context) => {
    const g = iteratee(f);
    return pairsOf(obj).every(([value, key]) => g.call(context, value, key, obj));
  };
  _.reduce = _.inject = _.foldl = function (obj, f, memo, context) {
    const pairs = pairsOf(obj);
    let start = 0;
    if (arguments.length < 3) {
      memo = pairs.length > 0 ? pairs[0][0] : undefined;
      start = 1;
    }
    for (let i = start; i < pairs.length; i++) memo = f.call(context, memo, pairs[i][0], pairs[i][1], obj);
    return memo;
  };
  _.values = (obj) => pairsOf(obj).map(([value]) => value);
  _.keys = (obj) => (obj === null || obj === undefined ? [] : Object.keys(obj));
  _.size = (obj) => pairsOf(obj).length;
  _.contains = _.include = (obj, target) => _.values(obj).indexOf(target) >= 0;
  _.pluck = (obj, key) => _.map(obj, key);
  _.sortBy = (obj, f, context) => {
    const g = iteratee(f);
    return pairsOf(obj)
      .map(([value, key]) => ({value, rank: g.call(context, value, key, obj)}))
      .sort((a, b) => (a.rank < b.rank ? -1 : a.rank > b.rank ? 1 : 0))
      .map((entry) => entry.value);
  };
  _.first = _.head = (list, n) => (n === undefined ? slice(list)[0] : slice(list, 0, n));
  _.last = (list, n) => {
    const items = slice(list);
    return n === undefined ? items[items.length - 1] : items.slice(Math.max(items.length - n, 0));
  };
  _.rest = _.tail = (list, n) => slice(list, n === undefined ? 1 : n);
  _.without = (list, ...values) => slice(list).filter((value) => values.indexOf(value) < 0);
  _.uniq = _.unique = (list) => slice(list).filter((value, index, items) => items.indexOf(value) === index);
  _.flatten = (list, shallow) =>
    slice(list).reduce((out, value) => out.concat(Array.isArray(value) && !shallow ? _.flatten(value) : value), []);
  _.range = function (start, stop, step) {
    if (arguments.length <= 1) {
      stop = start || 0;
      start = 0;
    }
    step = step || 1;
    const out = [];
    for (let x = start; step > 0 ? x < stop : x > stop; x += step) out.push(x);
    return out;
  };
  _.indexOf = (list, value) => slice(list).indexOf(value);
  _.times = (n, f, context) => _.range(n).map((i) => f.call(context, i));
  _.extend = (obj, ...sources) => Object.assign(obj, ...sources);
  _.defaults = (obj, ...sources) => {
    for (const source of sources) {
      for (const key in source) if (obj[key] === undefined) obj[key] = source[key];
    }
    return obj;
  };
  _.clone = (obj) =>
    obj === null || typeof obj !== 'object' ? obj : Array.isArray(obj) ? obj.slice() : Object.assign({}, obj);
  _.has = (obj, key) => obj !== null && obj !== undefined && Object.prototype.hasOwnProperty.call(obj, key);
  _.identity = (value) => value;
  _.bind = (f, context, ...args) => f.bind(context, ...args);
  _.isString = (x) => typeof x === 'string' || x instanceof String;
  _.isNumber = (x) => typeof x === 'number' || x instanceof Number;
  _.isBoolean = (x) => x === true || x === false || x instanceof Boolean;
  _.isFunction = (x) => typeof x === 'function';
  _.isArray = Array.isArray;
  _.isObject = (x) => typeof x === 'function' || (typeof x === 'object' && x !== null);
  _.isUndefined = (x) => x === undefined;
  _.isNull = (x) => x === null;
  _.isEmpty = (x) => x === null || x === undefined || (isArrayLike(x) ? x.length === 0 : Object.keys(x).length === 0);
  return _;
}

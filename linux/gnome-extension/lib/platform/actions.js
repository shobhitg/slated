// Performs actions: window geometry, focus, app visibility, shell commands, text, layouts, snapshots
// and undo. A port of the macOS ActionRunner (Sources/Slated/Engine/ActionRunner.swift).
//
// Geometry comes from the core (`targetFrame`/`targetOrigin`); everything that touches GNOME goes
// through `platform` (see gnomePlatform.js), so this file has no GNOME imports and the logic is
// unit-tested in Node with a fake platform.
//
// Actions are plain JSON objects exactly as in config.json (`{op: "move", x, y, width, height}`); a
// bare string is Slate operation syntax and is parsed with the core.

import * as Core from '../core/index.js';

import {comboOf} from './combos.js';
import {
  appSelector,
  gridSizes,
  integralRect,
  isPortrait,
  isWindowGeometry,
  screenContaining,
  sequenceSteps,
  stableStringify,
  truncate,
  truthyText,
} from './util.js';

export const DEFAULT_HINT_CHARACTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const MAX_CHAINS = 500;

/**
 * A copy of `action` safe for the event log: `insert-text` content is replaced by its length, like
 * hotstring replacements, which are never logged.
 */
export function redactForLog(action) {
  if (Array.isArray(action)) return action.map(redactForLog);
  if (!action || typeof action !== 'object') return action;
  const copy = {};
  for (const [key, value] of Object.entries(action)) {
    if (key === 'text' && action.op === 'insert-text') copy[key] = `(${[...String(value)].length} characters)`;
    else copy[key] = typeof value === 'object' ? redactForLog(value) : value;
  }
  return copy;
}

/** The text of an error thrown by the core or GNOME. */
export function errorMessage(error) {
  if (error === null || error === undefined) return 'Unknown error';
  if (typeof error === 'string') return error;
  return String(error.message ?? error);
}

function normalizeFocusDirection(raw) {
  const value = String(raw ?? '').toLowerCase();
  if (value === 'top' || value === 'above') return 'up';
  if (value === 'bottom' || value === 'below') return 'down';
  return value;
}

const midX = (r) => r.x + r.width / 2;
const midY = (r) => r.y + r.height / 2;

export class ActionRunner {
  /**
   * @param {object} options
   * @param {object} options.platform  GNOME access (see gnomePlatform.js for the contract).
   * @param {object} [options.core]    The engine API (lib/core/index.js); tests pass a fake.
   * @param {object} [options.log]     An EventLog.
   * @param {object} [options.overlays]  `showHints(characters)`, `showGrid({padding, grids, window})`.
   * @param {object} [options.snapshots] `take`, `activate`, `delete` (see snapshots.js).
   */
  constructor({platform, core = Core, log = null, overlays = null, snapshots = null}) {
    this.platform = platform;
    this.core = core;
    this.log = log;
    this.overlays = overlays;
    this.snapshots = snapshots;
    /** Slate settings (`{defaultToCurrentScreen: true, …}`), merged from every source. */
    this.settings = {};
    this.layouts = new Map();
    /** Something happened worth showing ("Left half · Firefox"). */
    this.onPerformed = null;
    this.onError = null;
    /** Slate's `relaunch`: reload all configuration. */
    this.onRelaunch = null;
    /** Runs a layout defined in JavaScript. Returns false if there's no such layout. */
    this.externalLayout = null;

    this._undo = [];
    this._chains = new Map();
    this._lastApp = null;
    this._lastFailure = null;
  }

  /** Why the last `run` failed (null if it didn't). */
  get lastFailure() {
    return this._lastFailure;
  }

  /** Layouts by name; later ones replace earlier ones with the same name (Slated's own win). */
  setLayouts(layouts) {
    this.layouts = new Map();
    for (const layout of layouts ?? []) if (layout?.name) this.layouts.set(layout.name, layout);
  }

  /**
   * Runs `action` for `trigger` (e.g. "hotkey hyper+a") and logs one event with the outcome: what ran,
   * on which app, how long it took, and the error if it failed.
   */
  run(action, {window = null, label = null, chainKey = null, trigger = 'unknown', source = null} = {}) {
    const start = this.platform.now();
    this._lastApp = null;
    this._lastFailure = null;
    let ok;
    try {
      ok = this.perform(action, {window, label, chainKey});
    } catch (e) {
      ok = this._fail(errorMessage(e));
    }
    let app = this._lastApp;
    if (!app) {
      try {
        app = this.platform.appInfo(this.platform.focusedApp())?.id ?? null;
      } catch {
        app = null;
      }
    }
    this.log?.record(
      ok ? 'action.done' : 'action.failed',
      {
        trigger,
        action: truncate(this.describe(redactForLog(action)), 200),
        ms: this.platform.now() - start,
        label,
        source,
        app,
        error: this._lastFailure,
      },
      ok ? 'info' : 'error',
    );
    return ok;
  }

  /** Slate syntax for an action, for logs and the HUD. */
  describe(action) {
    if (typeof action === 'string') return action;
    try {
      return this.core.formatOperation(action);
    } catch {
      return stableStringify(action);
    }
  }

  /**
   * Runs `action` without logging (nested steps of chains, sequences and layouts; use `run` at the top
   * level). Window actions target `window`, or the focused window when null. `chainKey` identifies a
   * binding so each `chain` cycles independently.
   */
  perform(action, {window = null, label = null, chainKey = null} = {}) {
    if (typeof action === 'string') action = this.core.parseOperation(action);
    if (!action || typeof action !== 'object') return this._fail('Not an operation');
    switch (action.op) {
      case 'move':
      case 'resize':
      case 'push':
      case 'nudge':
      case 'throw':
      case 'corner':
        return this._applyGeometry(action, window ?? this.platform.focusedWindow(), label);

      case 'by-orientation': {
        const target = window ?? this.platform.focusedWindow();
        const frame = target ? this.platform.frame(target) : null;
        const screen = frame ? screenContaining(this.platform.screens(), frame) : null;
        return this.perform(isPortrait(screen) ? action.portrait : action.landscape, {window: target, label, chainKey});
      }

      case 'chain': {
        const operations = action.operations ?? [];
        if (operations.length === 0) return false;
        const key = chainKey ?? stableStringify(action);
        const target = window ?? this.platform.focusedWindow();
        const state = this._chains.get(key) ?? {next: 0, window: null};
        // Start over when the chain is used on a different window.
        if (state.window && target && !this.platform.sameWindow(state.window, target)) state.next = 0;
        const index = state.next % operations.length;
        if (this._chains.size > MAX_CHAINS) this._chains.clear();
        this._chains.set(key, {next: index + 1, window: target});
        return this.perform(operations[index], {window: target, label, chainKey: `${key}/${index}`});
      }

      case 'sequence': {
        // Plain steps act on whatever is focused when they run; `keepWindow` steps (Slate's `>`) act on
        // the window that was focused when their run began.
        let anchor = window ?? this.platform.focusedWindow();
        let ok = true;
        sequenceSteps(action).forEach((step, i) => {
          if (i > 0 && !step.keepWindow) anchor = this.platform.focusedWindow();
          ok = this.perform(step.action, {window: anchor, chainKey: chainKey ? `${chainKey}/${i}` : null}) && ok;
        });
        return ok;
      }

      case 'layout': {
        const layout = this.layouts.get(action.name);
        if (!layout) {
          if (this.externalLayout?.(action.name)) {
            this._report(`Layout ${action.name}`);
            return true;
          }
          return this._fail(`No layout named "${action.name}"`);
        }
        this._applyLayout(layout);
        this._report(`Layout ${action.name}`);
        return true;
      }

      case 'focus': {
        if (action.app !== undefined && action.app !== null) {
          const app = this.platform.findApp(String(action.app));
          if (!app) return this._fail(`${action.app} isn't running`);
          this.platform.activateApp(app);
          this._report(label ?? `Focus ${action.app}`);
          return true;
        }
        const current = window ?? this.platform.focusedWindow();
        if (!current) return this._fail('No focused window');
        const direction = normalizeFocusDirection(action.direction);
        if (!['left', 'right', 'up', 'down', 'behind'].includes(direction)) {
          return this._fail(`Unknown focus direction "${action.direction}"`);
        }
        const next = direction === 'behind' ? this._windowBehind(current) : this._nearestWindow(direction, current);
        if (!next) return false;
        this.platform.focus(next);
        this._report(label ?? `Focus ${direction}`, next);
        return true;
      }

      case 'hide':
        for (const app of this._apps(action.app)) this.platform.hideApp(app);
        return true;
      case 'show':
        for (const app of this._apps(action.app)) this.platform.showApp(app);
        return true;
      case 'toggle':
        for (const app of this._apps(action.app)) {
          if (this.platform.isAppHidden(app)) this.platform.showApp(app);
          else this.platform.hideApp(app);
        }
        return true;

      case 'shell': {
        const result = this.platform.runShell(String(action.command ?? ''), {
          wait: action.wait === true,
          path: action.path ?? null,
        });
        return result.ok ? true : this._fail(`Couldn't run ${action.command}: ${result.error}`);
      }

      case 'undo':
        while (this._undo.length > 0) {
          const last = this._undo.pop();
          if (!this.platform.isAlive(last.window)) continue;
          this.platform.setFrame(last.window, last.frame);
          this._report('Undo', last.window);
          return true;
        }
        return false;

      case 'relaunch':
        this.onRelaunch?.();
        return true;

      case 'snapshot':
        if (!this.snapshots) return this._fail("Snapshots aren't available");
        this.snapshots.take(action.name, {save: !!action.save, stack: !!action.stack});
        this._report(`Snapshot ${action.name}`);
        return true;
      case 'activate-snapshot':
        if (!this.snapshots) return this._fail("Snapshots aren't available");
        if (!this.snapshots.activate(action.name, {delete: !!action.delete})) {
          return this._fail(`No snapshot named "${action.name}"`);
        }
        this._report(`Snapshot ${action.name}`);
        return true;
      case 'delete-snapshot':
        if (!this.snapshots) return this._fail("Snapshots aren't available");
        this.snapshots.delete(action.name, {all: !!action.all});
        return true;

      case 'hint':
        if (!this.overlays) return this._fail("Window hints aren't available");
        this.overlays.showHints(action.characters ?? this._setting('windowHintsCharacters', DEFAULT_HINT_CHARACTERS));
        return true;
      case 'grid': {
        if (!this.overlays) return this._fail("The grid isn't available");
        const target = window ?? this.platform.focusedWindow();
        if (!target) return this._fail('No focused window to place');
        this.overlays.showGrid({padding: action.padding ?? 2, grids: gridSizes(action.grids), window: target});
        return true;
      }

      case 'switch':
        return this._fail("Slate's app switcher (switch) isn't supported yet");

      case 'insert-text': {
        const result = this.platform.insertText(String(action.text ?? ''), action.method ?? 'auto');
        return result.ok ? true : this._fail(result.error);
      }
      case 'open-url': {
        const result = this.platform.openURL(String(action.url ?? ''));
        return result.ok ? true : this._fail(result.error);
      }
      case 'keystroke': {
        let combo = null;
        try {
          combo = comboOf(action.keys, this.core);
        } catch {
          combo = null;
        }
        if (!combo) return this._fail(`Unknown keys ${JSON.stringify(action.keys)}`);
        const result = this.platform.pressKeys(combo);
        return result.ok ? true : this._fail(result.error);
      }

      default:
        return this._fail(`Unknown operation "${action.op}"`);
    }
  }

  // --- Geometry ----------------------------------------------------------------------------------

  _applyGeometry(action, window, label, record = true) {
    if (!window) return this._fail('No focused window to move');
    const frame = this.platform.frame(window);
    if (!frame) return this._fail("Couldn't read the window's position");
    const context = {frame, screens: this.platform.screens(), settings: this.settings};
    let target;
    try {
      target = integralRect(this.core.targetFrame(action, context));
    } catch (e) {
      return this._fail(errorMessage(e));
    }
    if (record) this._pushUndo(window, frame);
    if (!this.platform.setFrame(window, target)) {
      return this._fail(`${this.platform.appInfo(this.platform.appOfWindow(window))?.name || 'The app'} didn't allow moving that window`);
    }
    // Apps with minimum or stepped sizes may not take the requested size, and Wayland apps take a
    // moment to resize. Once settled, re-anchor using the size the window really took (keeps
    // bottom/right placements flush with the screen edge), or retry a move that didn't stick.
    this.platform.afterSettle(window, () => this._settle(action, context, window, target));
    this._report(label ?? this.describe(action), window);
    return true;
  }

  _settle(action, context, window, target) {
    if (!this.platform.isAlive(window)) return;
    const actual = this.platform.frame(window);
    if (!actual) return;
    const sizeDiffers = Math.abs(actual.width - target.width) > 1 || Math.abs(actual.height - target.height) > 1;
    if (sizeDiffers) {
      let origin;
      try {
        origin = this.core.targetOrigin(action, context, {width: actual.width, height: actual.height});
      } catch {
        return;
      }
      const rect = integralRect({x: origin.x, y: origin.y, width: actual.width, height: actual.height});
      if (Math.abs(rect.x - actual.x) > 1 || Math.abs(rect.y - actual.y) > 1) this.platform.setFrame(window, rect);
    } else if (Math.abs(actual.x - target.x) > 1 || Math.abs(actual.y - target.y) > 1) {
      this.platform.setFrame(window, target);
    }
  }

  /** Places a window at an explicit frame (used by the grid), with undo. */
  place(window, target, label) {
    const frame = this.platform.frame(window);
    if (frame) this._pushUndo(window, frame);
    this.platform.setFrame(window, integralRect(target));
    this._report(label, window);
  }

  _pushUndo(window, frame) {
    this._undo.push({window, frame});
    const limit = Math.max(Math.trunc(this._settingNumber('undoMaxStackSize', 10)), 1);
    if (this._undo.length > limit) this._undo.splice(0, this._undo.length - limit);
  }

  // --- Layouts (Slate's `layout`) ----------------------------------------------------------------

  _applyLayout(layout) {
    for (const action of layout.before ?? []) this.perform(action);
    for (const entry of layout.apps ?? []) {
      const operations = entry.operations ?? [];
      const app = this.platform.findApp(entry.app);
      if (!app || operations.length === 0) continue;
      const options = entry.options ?? {};
      const windows = this._ordered(this.platform.appWindows(app), options);
      for (let i = 0; i < windows.length; i++) {
        let index;
        if (i < operations.length) index = i;
        else if (options.repeat) index = i % operations.length;
        else if (options.repeatLast) index = operations.length - 1;
        else break;
        const action = operations[index];
        const ok = isWindowGeometry(action)
          ? this._applyGeometry(action, windows[i], null, false)
          : this.perform(action, {window: windows[i]});
        if (!ok && !options.ignoreFail) break;
      }
    }
    for (const action of layout.after ?? []) this.perform(action);
    if (this._settingBool('layoutFocusOnActivate', false) && layout.apps?.[0]) {
      const app = this.platform.findApp(layout.apps[0].app);
      if (app) this.platform.activateApp(app);
    }
  }

  /** Slate's window ordering options: SORT_TITLE, TITLE_ORDER, TITLE_ORDER_REGEX, MAIN_FIRST/LAST. */
  _ordered(windows, options) {
    let result = [...windows];
    const title = (w) => this.platform.windowTitle(w) ?? '';
    if (options.sortTitle) result.sort((a, b) => (title(a) < title(b) ? -1 : title(a) > title(b) ? 1 : 0));
    if (Array.isArray(options.titleOrder)) {
      const rank = (w) => {
        const i = options.titleOrder.indexOf(title(w));
        return i < 0 ? Number.MAX_SAFE_INTEGER : i;
      };
      result = result
        .map((w, offset) => ({w, offset}))
        .sort((a, b) => rank(a.w) - rank(b.w) || a.offset - b.offset)
        .map((item) => item.w);
    }
    if (Array.isArray(options.titleOrderRegex)) {
      const remaining = [...result];
      const picked = [];
      for (const pattern of options.titleOrderRegex) {
        let regex;
        try {
          regex = new RegExp(pattern);
        } catch {
          continue;
        }
        const i = remaining.findIndex((w) => regex.test(title(w)));
        if (i >= 0) picked.push(...remaining.splice(i, 1));
      }
      result = [...picked, ...remaining];
    }
    if (options.mainFirst) {
      const i = result.findIndex((w) => this.platform.isMainWindow(w));
      if (i > 0) result.unshift(...result.splice(i, 1));
    }
    if (options.mainLast) {
      const i = result.findIndex((w) => this.platform.isMainWindow(w));
      if (i >= 0) result.push(...result.splice(i, 1));
    }
    return result;
  }

  // --- Focus -------------------------------------------------------------------------------------

  /**
   * The nearest window whose center lies in `direction`, preferring windows that overlap the current
   * one along the other axis (Slate's focusCheckWidth idea).
   */
  _nearestWindow(direction, current) {
    const from = this.platform.frame(current);
    if (!from) return null;
    const preferSameApp = this._settingBool('focusPreferSameApp', true);
    const currentApp = this.platform.appInfo(this.platform.appOfWindow(current))?.id ?? null;
    let best = null;
    let bestScore = Infinity;
    for (const candidate of this.platform.windowsOnWorkspace()) {
      if (this.platform.sameWindow(candidate, current)) continue;
      const to = this.platform.frame(candidate);
      if (!to) continue;
      const dx = midX(to) - midX(from);
      const dy = midY(to) - midY(from);
      const overlapsVertically = to.y < from.y + from.height && to.y + to.height > from.y;
      const overlapsHorizontally = to.x < from.x + from.width && to.x + to.width > from.x;
      let along;
      let across;
      let overlaps;
      switch (direction) {
        case 'right':
          [along, across, overlaps] = [dx, Math.abs(dy), overlapsVertically];
          break;
        case 'left':
          [along, across, overlaps] = [-dx, Math.abs(dy), overlapsVertically];
          break;
        case 'down':
          [along, across, overlaps] = [dy, Math.abs(dx), overlapsHorizontally];
          break;
        default:
          [along, across, overlaps] = [-dy, Math.abs(dx), overlapsHorizontally];
          break;
      }
      if (along <= 1) continue;
      let score = along + across * 2;
      if (!overlaps) score += 10_000;
      if (preferSameApp && currentApp && this.platform.appInfo(this.platform.appOfWindow(candidate))?.id === currentApp) {
        score -= 1;
      }
      if (score < bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  /** The next window down in the stacking order of the current workspace. */
  _windowBehind(current) {
    const stack = this.platform.windowsOnWorkspace();
    const index = stack.findIndex((w) => this.platform.sameWindow(w, current));
    return index >= 0 ? stack[index + 1] ?? null : null;
  }

  // --- Apps --------------------------------------------------------------------------------------

  _apps(value) {
    const selector = appSelector(value);
    switch (selector.kind) {
      case 'current': {
        const app = this.platform.focusedApp();
        return app ? [app] : [];
      }
      case 'all':
        return this.platform.runningApps();
      case 'allBut':
        return this.platform.runningApps().filter((app) => !this.platform.appMatches(app, selector.name));
      default:
        return this.platform
          .runningApps()
          .filter((app) => selector.names.some((name) => this.platform.appMatches(app, name)));
    }
  }

  // --- Settings ----------------------------------------------------------------------------------

  _setting(key, fallback) {
    const value = this.settings?.[key];
    return value === undefined || value === null ? fallback : value;
  }

  _settingNumber(key, fallback) {
    const value = Number(this._setting(key, fallback));
    return Number.isFinite(value) ? value : fallback;
  }

  _settingBool(key, fallback) {
    const value = this._setting(key, fallback);
    if (typeof value === 'boolean') return value;
    if (typeof value === 'number') return value !== 0;
    return truthyText(value);
  }

  // --- Reporting ---------------------------------------------------------------------------------

  _report(what, window = null) {
    let info = null;
    if (window) {
      try {
        info = this.platform.appInfo(this.platform.appOfWindow(window));
      } catch {
        info = null;
      }
    }
    if (info?.id) this._lastApp = info.id;
    this.onPerformed?.(info?.name ? `${what} · ${info.name}` : what);
  }

  _fail(message) {
    this._lastFailure = this._lastFailure ? `${this._lastFailure}; ${message}` : message;
    this.onError?.(message);
    return false;
  }

  destroy() {
    this._undo = [];
    this._chains.clear();
    this.onPerformed = this.onError = this.onRelaunch = this.externalLayout = null;
  }
}

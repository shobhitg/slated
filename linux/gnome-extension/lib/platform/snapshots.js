// Slate's snapshots: remember where every window is and put them back later. A port of the macOS
// SnapshotStore. Snapshots taken with `save` persist in `~/.local/state/slated/snapshots.json`.
//
// The file holds window titles (to tell an app's windows apart when restoring); like on macOS it
// stays local and titles never go to the log.

import {readText, writeTextAtomic} from './files.js';

/**
 * Pairs saved window states with current windows: by app and title first, then the app's remaining
 * windows in order. `windows` are `{window, app, title}`; returns `[{window, frame}]`.
 */
export function matchSnapshot(states, windows) {
  const wantedByApp = new Map();
  for (const state of states) {
    if (!wantedByApp.has(state.app)) wantedByApp.set(state.app, []);
    wantedByApp.get(state.app).push(state);
  }
  const placements = [];
  const unmatchedByApp = new Map();
  for (const item of windows) {
    const wanted = wantedByApp.get(item.app);
    if (!wanted) continue;
    const i = wanted.findIndex((s) => s.title === item.title);
    if (i >= 0) {
      placements.push({window: item.window, frame: wanted.splice(i, 1)[0].frame});
    } else {
      if (!unmatchedByApp.has(item.app)) unmatchedByApp.set(item.app, []);
      unmatchedByApp.get(item.app).push(item.window);
    }
  }
  for (const [app, unmatched] of unmatchedByApp) {
    const wanted = wantedByApp.get(app) ?? [];
    unmatched.forEach((window, i) => {
      if (i < wanted.length) placements.push({window, frame: wanted[i].frame});
    });
  }
  return placements;
}

export class SnapshotStore {
  /**
   * @param {object} options
   * @param {string|null} options.path  snapshots.json; null keeps everything in memory (tests).
   * @param {object} options.platform   `snapshotWindows()` → [{window, app, title, frame}], `setFrame`.
   * @param {object} [options.log]
   */
  constructor({path, platform, log = null}) {
    this._path = path;
    this._platform = platform;
    this._log = log;
    /** Snapshot name → stack of snapshots (the top is used; non-stack snapshots have one entry). */
    this._stacks = new Map();
    this._persisted = new Set();
    this._load();
  }

  take(name, {save = false, stack = false} = {}) {
    const states = this._platform.snapshotWindows().map((w) => ({app: w.app, title: w.title ?? '', frame: w.frame}));
    if (stack) this._stacks.set(name, [...(this._stacks.get(name) ?? []), states]);
    else this._stacks.set(name, [states]);
    if (save) this._persisted.add(name);
    this._persist();
  }

  /** Restores the snapshot. Returns false when there's no snapshot by that name. */
  activate(name, {delete: deleteAfter = false} = {}) {
    const stack = this._stacks.get(name);
    if (!stack?.length) return false;
    for (const placement of matchSnapshot(stack[stack.length - 1], this._platform.snapshotWindows())) {
      this._platform.setFrame(placement.window, placement.frame);
    }
    if (deleteAfter) this.delete(name, {all: false});
    return true;
  }

  delete(name, {all = false} = {}) {
    const stack = this._stacks.get(name) ?? [];
    if (all || stack.length <= 1) {
      this._stacks.delete(name);
      this._persisted.delete(name);
    } else {
      this._stacks.set(name, stack.slice(0, -1));
    }
    this._persist();
  }

  _load() {
    if (!this._path) return;
    try {
      const saved = JSON.parse(readText(this._path) ?? '{}');
      for (const [name, stack] of Object.entries(saved)) {
        if (!Array.isArray(stack)) continue;
        this._stacks.set(name, stack.filter(Array.isArray));
        this._persisted.add(name);
      }
    } catch (e) {
      this._log?.error('snapshots.unreadable', e.message ?? String(e), {path: this._path});
    }
  }

  _persist() {
    if (!this._path) return;
    const saved = {};
    for (const name of [...this._persisted].sort()) if (this._stacks.has(name)) saved[name] = this._stacks.get(name);
    try {
      writeTextAtomic(this._path, `${JSON.stringify(saved)}\n`);
    } catch (e) {
      this._log?.error('snapshots.save_failed', e.message ?? String(e), {path: this._path});
    }
  }
}

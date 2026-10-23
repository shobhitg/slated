// Main-loop timeouts and idles that are always removed on `clearAll()`, so `disable()` leaves no
// GLib sources behind (an extensions.gnome.org review rule).

import GLib from 'gi://GLib';

export class Timers {
  constructor() {
    this._ids = new Set();
  }

  /** Runs `callback` once after `ms` milliseconds. Returns an id for `clear`. */
  timeout(ms, callback) {
    const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, Math.max(0, Math.round(ms)), () => {
      this._ids.delete(id);
      try {
        callback();
      } catch (e) {
        console.error(`Slated: timer callback failed: ${e}\n${e?.stack ?? ''}`);
      }
      return GLib.SOURCE_REMOVE;
    });
    this._ids.add(id);
    return id;
  }

  /** Runs `callback` every `ms` milliseconds while it returns true. */
  interval(ms, callback) {
    const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, Math.max(1, Math.round(ms)), () => {
      let again = false;
      try {
        again = callback() === true;
      } catch (e) {
        console.error(`Slated: timer callback failed: ${e}\n${e?.stack ?? ''}`);
      }
      if (!again) this._ids.delete(id);
      return again ? GLib.SOURCE_CONTINUE : GLib.SOURCE_REMOVE;
    });
    this._ids.add(id);
    return id;
  }

  /** Runs `callback` once the main loop is idle. */
  idle(callback) {
    const id = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
      this._ids.delete(id);
      try {
        callback();
      } catch (e) {
        console.error(`Slated: idle callback failed: ${e}\n${e?.stack ?? ''}`);
      }
      return GLib.SOURCE_REMOVE;
    });
    this._ids.add(id);
    return id;
  }

  clear(id) {
    if (id && this._ids.delete(id)) GLib.source_remove(id);
    return 0;
  }

  clearAll() {
    for (const id of this._ids) GLib.source_remove(id);
    this._ids.clear();
  }
}

/** Calls `callback` once things have been quiet for `ms` (coalesces bursts of file events). */
export class Debouncer {
  constructor(timers, ms, callback) {
    this._timers = timers;
    this._ms = ms;
    this._callback = callback;
    this._id = 0;
  }

  trigger() {
    this._timers.clear(this._id);
    this._id = this._timers.timeout(this._ms, () => {
      this._id = 0;
      this._callback();
    });
  }

  cancel() {
    this._id = this._timers.clear(this._id);
  }
}

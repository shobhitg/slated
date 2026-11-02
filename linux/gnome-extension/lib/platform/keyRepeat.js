// config.json's `keyboard.keyRepeat` on GNOME: how long a held key waits before it repeats, and how
// fast it repeats then, in milliseconds. The Mac does the same in SlatedSystem, where macOS keeps
// 1/60 s ticks (SlatedCore's MacKeyRepeatTicks); GNOME keeps milliseconds, so nothing
// converts here.
//
// - Applied through GSettings, org.gnome.desktop.peripherals.keyboard (`repeat`, `delay`,
//   `repeat-interval`), which is what GNOME Settings → Keyboard → Repeat Keys changes. Mutter takes it
//   at once. Only values that differ are written. Absent: GNOME's own setting stays as it is.
// - Never undone on disable(): it's your preference, not a temporary mapping (the Mac does the same).
// - Captured once per computer: the first time this version runs, with no keyRepeat in config.json,
//   GNOME's current values are copied into it, so copying config.json to another computer (a Mac
//   too) takes them along. A marker in the state folder (key-repeat.json) remembers that it happened
//   here, so turning the switch off afterwards sticks. It's written on that first run even when
//   config.json already has a keyRepeat (copied from elsewhere: that one is simply applied), and when
//   GNOME's key repeat is off (Slated then captures nothing rather than turn repeating on).

import Gio from 'gi://Gio';

import {clampKeyRepeat} from '../core/index.js';
import {exists, writeTextAtomic} from './files.js';

export const KEYBOARD_SCHEMA = 'org.gnome.desktop.peripherals.keyboard';

/** GNOME's key repeat: {enabled, delay, interval} in ms, or null when the schema can't be read. */
export function readGnomeKeyRepeat(settings) {
  try {
    return {enabled: settings.get_boolean('repeat'), delay: settings.get_uint('delay'), interval: settings.get_uint('repeat-interval')};
  } catch {
    return null;
  }
}

/** What to write so GNOME repeats as `wanted` says: [[method, key, value]…], nothing when it already does. */
export function keyRepeatWrites(current, wanted) {
  const writes = [];
  if (current?.enabled !== true) writes.push(['set_boolean', 'repeat', true]);
  if (current?.delay !== wanted.delay) writes.push(['set_uint', 'delay', wanted.delay]);
  if (current?.interval !== wanted.interval) writes.push(['set_uint', 'repeat-interval', wanted.interval]);
  return writes;
}

export class KeyRepeatManager {
  /**
   * @param {object} options
   * @param {object} [options.log]
   * @param {string} options.markerPath  key-repeat.json: this computer's setting was captured.
   * @param {() => object} [options.settings]  Makes the Gio.Settings (tests pass a fake).
   */
  constructor({log = null, markerPath, settings = () => new Gio.Settings({schema_id: KEYBOARD_SCHEMA})}) {
    this._log = log;
    this._markerPath = markerPath;
    this._makeSettings = settings;
    this._settings = null;
    this._logged = '';
  }

  _gsettings() {
    this._settings ??= this._makeSettings();
    return this._settings;
  }

  /** GNOME's key repeat right now: {enabled, delay, interval} in ms, or null when it can't be read. */
  read() {
    try {
      return readGnomeKeyRepeat(this._gsettings());
    } catch {
      return null;
    }
  }

  /** GNOME's current key repeat as config.json would hold it (clamped), or null when it can't be read. */
  current() {
    const raw = this.read();
    return raw ? clampKeyRepeat(raw) : null;
  }

  /** Whether this computer's key repeat was captured (or found in config.json) on an earlier run. */
  get captured() {
    return exists(this._markerPath);
  }

  markCaptured(keyRepeat = null) {
    try {
      writeTextAtomic(this._markerPath, `${JSON.stringify({captured: true, keyRepeat}, null, 2)}\n`);
      return true;
    } catch (e) {
      this._log?.error('keyboard.state_file_failed', e?.message ?? String(e), {path: this._markerPath});
      return false;
    }
  }

  /**
   * Makes GNOME repeat keys as `keyRepeat` says ({delay, interval} ms); null leaves it alone. Returns
   * status.json's {state: "applied"|"failed"|"off", delay, interval}.
   */
  apply(keyRepeat) {
    const wanted = keyRepeat ? clampKeyRepeat(keyRepeat) : null;
    if (!wanted) {
      this._logged = '';
      return {state: 'off', delay: null, interval: null};
    }
    const signature = JSON.stringify(wanted);
    try {
      const settings = this._gsettings();
      const writes = keyRepeatWrites(readGnomeKeyRepeat(settings), wanted);
      for (const [method, key, value] of writes) settings[method](key, value);
      // Log the setting once, not every reload; `changed` says whether GNOME had to be told.
      if (signature !== this._logged) {
        this._logged = signature;
        this._log?.record('keyboard.key_repeat_applied', {delay: wanted.delay, interval: wanted.interval, live: true, changed: writes.length > 0});
      }
      return {state: 'applied', ...wanted};
    } catch (e) {
      if (signature !== this._logged) {
        this._logged = signature;
        this._log?.error('keyboard.key_repeat_failed', e?.message ?? String(e), {delay: wanted.delay, interval: wanted.interval});
      }
      return {state: 'failed', ...wanted};
    }
  }
}

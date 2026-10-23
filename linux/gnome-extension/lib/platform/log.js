// Slated's event log on GNOME: one JSON object per line in `$XDG_STATE_HOME/slated/slated.log`
// (default `~/.local/state/slated/slated.log`).
//
// Same schema and event names as the macOS app (Sources/Slated/Logging/EventLog.swift), so
// `scripts/logs.py --home …` and anyone reading logs from both platforms see one format:
//
//   {"data":{…},"event":"action.done","level":"info","session":"1a2b3c4d","ts":"2026-10-22T18:21:03.123Z"}
//
// Keys are sorted at every level; `data` is left out when empty. Fractional numbers keep one decimal.
//
// Privacy: events never contain typed text, hotstring replacements or window titles. They do contain
// shortcut names, hotstring triggers, app ids and error messages. The file stays on this computer.
//
// GNOME APIs are only touched inside `LogFile`, so the pure helpers can be unit-tested in Node.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {dirname, sortKeysDeep} from './util.js';

export const MAX_LOG_BYTES = 5_000_000;
export const KEPT_LOG_FILES = 3;
export const LEVELS = Object.freeze(['debug', 'info', 'notice', 'error', 'fault']);

/** Identifies one run (one `enable()`), so a log spanning several runs can be split by session. */
export function newSessionId(random = Math.random) {
  let id = '';
  for (let i = 0; i < 8; i++) id += Math.floor(random() * 16).toString(16);
  return id;
}

/**
 * A JSON-safe copy of `value`: objects and arrays are kept, `undefined`/`null` object members are
 * dropped (like assigning nil in a Swift dictionary), fractional numbers keep one decimal, and anything
 * else becomes a string.
 */
export function sanitize(value, depth = 0) {
  if (depth > 12) return String(value);
  if (value === null || value === undefined) return null;
  switch (typeof value) {
    case 'string':
    case 'boolean':
      return value;
    case 'number':
      if (!Number.isFinite(value)) return String(value);
      return Number.isInteger(value) ? value : Math.round(value * 10) / 10;
    case 'bigint':
      return Number(value);
    case 'object': {
      if (Array.isArray(value)) return value.map((item) => sanitize(item, depth + 1));
      if (value instanceof Error) return value.message;
      if (value instanceof Set) return [...value].map((item) => sanitize(item, depth + 1));
      if (value instanceof Date) return value.toISOString();
      const out = {};
      for (const [key, item] of Object.entries(value)) {
        if (item === undefined || item === null) continue;
        out[key] = sanitize(item, depth + 1);
      }
      return out;
    }
    default:
      return String(value);
  }
}

/** One log line (without the trailing newline). */
export function formatEvent({ts, level = 'info', event, session, data}) {
  const entry = {ts, level, event, session};
  const clean = data ? sanitize(data) : null;
  if (clean && Object.keys(clean).length > 0) entry.data = clean;
  return JSON.stringify(sortKeysDeep(entry));
}

/** "action.done app=firefox ms=12" — the short form mirrored to the journal. */
export function summarizeEvent(event, data) {
  const clean = data ? sanitize(data) : {};
  const details = Object.keys(clean)
    .sort()
    .map((key) => `${key}=${typeof clean[key] === 'object' ? JSON.stringify(clean[key]) : clean[key]}`)
    .join(' ');
  return details ? `${event} ${details}` : event;
}

/** The renames that rotate `slated.log`: slated.log → slated.1.log → … → slated.<kept>.log. */
export function rotationPlan(path, kept = KEPT_LOG_FILES) {
  const base = path.endsWith('.log') ? path.slice(0, -4) : path;
  const rotated = (n) => `${base}.${n}.log`;
  const moves = [];
  for (let n = kept - 1; n >= 1; n--) moves.push([rotated(n), rotated(n + 1)]);
  moves.push([path, rotated(1)]);
  return {remove: rotated(kept), moves};
}

/**
 * Records events to a sink (normally a `LogFile`) and optionally mirrors them (the journal).
 *
 * `record(event, data, level)`: `event` is a dotted name like `action.done`.
 */
export class EventLog {
  constructor({sink = null, session = newSessionId(), now = () => new Date(), mirror = null} = {}) {
    this.session = session;
    this._sink = sink;
    this._now = now;
    this._mirror = mirror;
  }

  record(event, data = {}, level = 'info') {
    if (!LEVELS.includes(level)) level = 'info';
    const line = formatEvent({ts: this._now().toISOString(), level, event, session: this.session, data});
    if (this._sink) {
      try {
        this._sink.write(`${line}\n`);
      } catch (e) {
        this._mirror?.('error', `Slated couldn't write its log: ${e?.message ?? e}`);
      }
    }
    this._mirror?.(level, summarizeEvent(event, data));
  }

  notice(event, data = {}) {
    this.record(event, data, 'notice');
  }

  /** An error with a human-readable message, like Swift's `Log.error`. */
  error(event, message, data = {}) {
    this.record(event, {...data, message: String(message)}, 'error');
  }

  close() {
    try {
      this._sink?.close();
    } catch {
      // Nothing useful to do: the log itself is what failed.
    }
    this._sink = null;
  }
}

/** Appends lines to a file and rotates it at `maxBytes`, keeping `kept` old files. */
export class LogFile {
  constructor(path, {maxBytes = MAX_LOG_BYTES, kept = KEPT_LOG_FILES} = {}) {
    this.path = path;
    this._maxBytes = maxBytes;
    this._kept = kept;
    this._stream = null;
    this._size = 0;
    this._encoder = new TextEncoder();
  }

  write(text) {
    if (!this._stream) this._open();
    const bytes = this._encoder.encode(text);
    this._stream.write_all(bytes, null);
    this._size += bytes.length;
    if (this._size > this._maxBytes) this._rotate();
  }

  close() {
    if (!this._stream) return;
    try {
      this._stream.close(null);
    } finally {
      this._stream = null;
    }
  }

  _open() {
    GLib.mkdir_with_parents(dirname(this.path), 0o755);
    const file = Gio.File.new_for_path(this.path);
    this._stream = file.append_to(Gio.FileCreateFlags.NONE, null);
    try {
      this._size = file.query_info('standard::size', Gio.FileQueryInfoFlags.NONE, null).get_size();
    } catch {
      this._size = 0;
    }
  }

  _rotate() {
    this.close();
    const plan = rotationPlan(this.path, this._kept);
    try {
      Gio.File.new_for_path(plan.remove).delete(null);
    } catch {
      // Not there yet.
    }
    for (const [from, to] of plan.moves) {
      try {
        Gio.File.new_for_path(from).move(Gio.File.new_for_path(to), Gio.FileCopyFlags.OVERWRITE, null, null);
      } catch {
        // A missing older file is normal.
      }
    }
    this._size = 0;
  }
}

/**
 * Mirrors events to the journal (`journalctl --user -g Slated`). Only errors by default, so Slated
 * doesn't flood the journal; everything when `SLATED_DEBUG=1`.
 */
export function journalMirror({verbose = false} = {}) {
  return (level, message) => {
    if (level === 'error' || level === 'fault') console.error(`Slated: ${message}`);
    else if (verbose) console.log(`Slated: ${message}`);
  };
}

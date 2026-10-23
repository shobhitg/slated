// Slated's event log format: one JSON object per line, keys sorted, the same schema and event names
// as the macOS app (Sources/Slated/Logging/EventLog.swift):
//
//   {"data":{"pane":"windows"},"event":"ui.pane","level":"info","session":"1a2b3c4d","ts":"2026-10-22T18:21:00.123Z"}
//
// The preferences append `ui.*`, `config.saved` and `slate.imported` events to the extension's log
// ($XDG_STATE_HOME/slated/slated.log), under the running extension's session when there is one, so
// `scripts/logs.py --session last` shows them together. This module only formats and parses; the
// writing (open, append, close) is in io.js.
//
// Privacy, as on macOS: never log typed text, hotstring replacements or window titles.
//
// Pure ES module.

import {isObject, stableStringify} from './util.js';

export const LEVELS = ['debug', 'info', 'notice', 'error', 'fault'];

/** JSON-safe copy: nested objects and arrays kept, finite numbers rounded to 0.1 like Swift, the rest as strings. */
export function sanitize(value) {
  if (value instanceof Error) return value.message;
  if (Array.isArray(value)) return value.map(sanitize);
  if (isObject(value)) return Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined).map(([k, v]) => [k, sanitize(v)]));
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return String(value);
    return Number.isInteger(value) ? value : Math.round(value * 10) / 10;
  }
  return String(value);
}

/** One log line (with the trailing newline). */
export function formatEvent(event, {session, level = 'info', data = {}, now = new Date()} = {}) {
  const entry = {ts: now.toISOString(), level: LEVELS.includes(level) ? level : 'info', event, session};
  if (data && Object.keys(data).length) entry.data = sanitize(data);
  return `${stableStringify(entry)}\n`;
}

/** Parses log text (JSON Lines), skipping unreadable lines. */
export function parseEvents(text) {
  const events = [];
  for (const line of String(text ?? '').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const event = JSON.parse(trimmed);
      if (isObject(event)) events.push(event);
    } catch {
      // A half-written last line, or something else's output: ignore.
    }
  }
  return events;
}

/** The newest `app.start` event, for `session` when given. */
export function lastStart(text, session = null) {
  const events = parseEvents(text);
  for (let i = events.length - 1; i >= 0; i--) {
    const e = events[i];
    if (e.event === 'app.start' && (!session || e.session === session)) return e;
  }
  return null;
}

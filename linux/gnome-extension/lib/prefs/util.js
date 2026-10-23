// Small pure helpers shared by the preferences modules.
//
// Pure ES module: no `gi://` imports and no Node built-ins, so it runs in GJS (the preferences window)
// and in Node (linux/tests/prefs).

/** JSON with object keys sorted at every level, so equal values always produce equal text. */
export function stableStringify(value, indent = 0) {
  return JSON.stringify(sortKeys(value), null, indent);
}

function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) {
      if (value[key] !== undefined) out[key] = sortKeys(value[key]);
    }
    return out;
  }
  return value;
}

/** Deep equality for JSON-shaped values (key order doesn't matter; `undefined` keys are ignored). */
export function deepEqual(a, b) {
  return stableStringify(a) === stableStringify(b);
}

/** A deep copy of a JSON-shaped value. */
export function clone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

/**
 * A random RFC 4122 version 4 UUID in upper case, the way Swift's `UUID` writes them, so ids made
 * here look like the ones the macOS app writes into the same config.json.
 */
export function uuid(random = Math.random) {
  const hex = [];
  for (let i = 0; i < 16; i++) hex.push(Math.floor(random() * 256));
  hex[6] = (hex[6] & 0x0f) | 0x40;
  hex[8] = (hex[8] & 0x3f) | 0x80;
  const s = hex.map(b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`;
}

/** Eight lowercase hex characters: an event-log session id, like the macOS app's. */
export function sessionId(random = Math.random) {
  return uuid(random).slice(0, 8).toLowerCase();
}

/** "a", "a and b", "a, b and c". */
export function formatList(items) {
  const list = items.filter(item => item !== undefined && item !== null && item !== '');
  if (list.length <= 1) return list.join('');
  return `${list.slice(0, -1).join(', ')} and ${list[list.length - 1]}`;
}

/** "1 binding", "3 bindings". */
export function plural(count, singular, pluralForm = `${singular}s`) {
  return `${count} ${count === 1 ? singular : pluralForm}`;
}

export function truncate(text, max) {
  const s = String(text ?? '');
  return [...s].length <= max ? s : `${[...s].slice(0, max - 1).join('')}…`;
}

/** Replaces line breaks with a visible return symbol, for one-line previews of multi-line text. */
export function singleLine(text) {
  return String(text ?? '').replace(/\r?\n/g, ' ⏎ ');
}

/**
 * Text made safe for widgets that always parse Pango markup (Adw.StatusPage's description,
 * Adw.Toast's title), like GLib.markup_escape_text. Rows are built with use_markup: false instead.
 */
export function escapeMarkup(text) {
  const entities = {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'};
  return String(text ?? '').replace(/[&<>"']/g, c => entities[c]);
}

/** Expands a leading `~` to `home`. */
export function expandHome(path, home) {
  if (path === '~') return home;
  if (path.startsWith('~/')) return `${home.replace(/\/$/, '')}/${path.slice(2)}`;
  return path;
}

/** Shows a path under `home` with a leading `~`. */
export function tildify(path, home) {
  const base = home.replace(/\/$/, '');
  if (path === base) return '~';
  return path.startsWith(`${base}/`) ? `~/${path.slice(base.length + 1)}` : path;
}

/** Levenshtein edit distance, for "did you mean" suggestions. */
export function editDistance(a, b) {
  const x = [...a];
  const y = [...b];
  if (!x.length) return y.length;
  if (!y.length) return x.length;
  let previous = Array.from({length: y.length + 1}, (_, i) => i);
  for (let i = 1; i <= x.length; i++) {
    const current = [i];
    for (let j = 1; j <= y.length; j++) {
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] === y[j - 1] ? 0 : 1));
    }
    previous = current;
  }
  return previous[y.length];
}

/** True when `value` is a plain object (not an array, not null). */
export function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** A tiny event emitter: `on(name, fn)` returns a function that removes the listener. */
export class Emitter {
  constructor() {
    this._listeners = new Map();
  }

  on(name, listener) {
    if (!this._listeners.has(name)) this._listeners.set(name, new Set());
    this._listeners.get(name).add(listener);
    return () => this._listeners.get(name)?.delete(listener);
  }

  emit(name, ...args) {
    for (const listener of [...(this._listeners.get(name) ?? [])]) {
      try {
        listener(...args);
      } catch (error) {
        // A broken listener must not stop the others (or the save that triggered it).
        (globalThis.logError ?? console.error)(error, `Slated: listener for "${name}" failed`);
      }
    }
  }
}

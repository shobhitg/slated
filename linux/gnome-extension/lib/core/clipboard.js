// Clipboard history (port of ClipboardHistory.swift): newest first, de-duplicated, bounded, with
// pinning, retention and search. Pure; the GNOME extension adds watching the clipboard and saving.
//
// Items are {id, text, copiedAt, sourceApp, pinned}, exactly the Mac app's clipboard.json entries:
// `copiedAt` is in Swift's Date encoding (seconds since 2001-01-01 UTC, see `referenceSeconds`),
// `id` an uppercase UUID, `sourceApp` the app it was copied from or null.

import {SlatedError} from './errors.js';
import {randomUUID} from './config.js';
import {asDouble, isNumberValue} from './json.js';
import {splitCharacters} from './model.js';
import {graphemes, isWhitespace, stringEquals, trimWhitespaceAndNewlines} from './text.js';

/** Seconds from 1970-01-01 to 2001-01-01, where Swift's dates count from. */
const REFERENCE_EPOCH = 978_307_200;

/** A JavaScript time (milliseconds since 1970, default now) as Swift's Date encoding. */
export function referenceSeconds(ms = Date.now()) {
  return ms / 1000 - REFERENCE_EPOCH;
}

/** Swift's Date encoding back to JavaScript milliseconds since 1970. */
export function referenceToMilliseconds(seconds) {
  return (seconds + REFERENCE_EPOCH) * 1000;
}

const swiftMax = (x, y) => (y >= x ? y : x);

export class ClipboardHistory {
  /**
   * @param {object[]} [items]  Newest first, as `items` or `toJSON().items`.
   * @param {object} [options]
   * @param {() => string} [options.newId]  Makes ids for new items (tests pass a counter).
   */
  constructor(items = [], {newId = randomUUID} = {}) {
    this._items = items.map((item) => ({
      id: item.id,
      text: item.text,
      copiedAt: item.copiedAt,
      sourceApp: item.sourceApp ?? null,
      pinned: !!item.pinned,
    }));
    this._newId = newId;
  }

  /** The items, newest first. */
  get items() {
    return this._items;
  }

  /**
   * Records a copy. Returns false when there's nothing worth keeping (empty or whitespace only).
   * Copying something already in the history moves it to the top with a new id, keeping its pin.
   * @param {string} text
   * @param {{app?: string|null, at: number, limit: number}} options  `at` in Swift's Date encoding.
   */
  add(text, {app = null, at, limit}) {
    if (trimWhitespaceAndNewlines(text) === '') return false;
    let pinned = false;
    const existing = this._items.findIndex((item) => stringEquals(item.text, text));
    if (existing >= 0) {
      pinned = this._items[existing].pinned;
      this._items.splice(existing, 1);
    }
    this._items.unshift({id: this._newId(), text, copiedAt: at, sourceApp: app ?? null, pinned});
    this.enforce(limit);
    return true;
  }

  /** Drops the oldest unpinned items beyond `limit` (at least 1). */
  enforce(limit) {
    const max = swiftMax(limit, 1);
    let unpinnedSeen = 0;
    this._items = this._items.filter((item) => {
      if (item.pinned) return true;
      unpinnedSeen += 1;
      return unpinnedSeen <= max;
    });
  }

  /** Forgets unpinned items copied more than `days` days before `now`. `days <= 0` keeps everything. */
  prune(days, now) {
    if (!(days > 0)) return;
    const cutoff = now + -days * 86_400;
    this._items = this._items.filter((item) => item.pinned || !(item.copiedAt < cutoff));
  }

  remove(id) {
    this._items = this._items.filter((item) => item.id !== id);
  }

  togglePin(id) {
    const item = this._items.find((i) => i.id === id);
    if (item) item.pinned = !item.pinned;
  }

  /** Removes everything, except pinned items when `keepPinned` (the default). */
  clear({keepPinned = true} = {}) {
    this._items = keepPinned ? this._items.filter((item) => item.pinned) : [];
  }

  /**
   * Items matching every word of `query` (case- and diacritic-insensitive, like Foundation's
   * `range(of:options: [.caseInsensitive, .diacriticInsensitive])`), pinned items first, newest first.
   * An empty query returns everything.
   */
  search(query) {
    const words = splitCharacters(String(query), isWhitespace);
    const matches =
      words.length === 0 ? this._items : this._items.filter((item) => words.every((word) => foldedContains(item.text, word)));
    return [...matches.filter((item) => item.pinned), ...matches.filter((item) => !item.pinned)];
  }

  /** The Codable form the Mac app writes to clipboard.json: {"items": [{id, text, copiedAt, sourceApp?, pinned}]}. */
  toJSON() {
    return {
      items: this._items.map((item) => {
        const out = {id: item.id, text: item.text, copiedAt: item.copiedAt};
        if (item.sourceApp !== null && item.sourceApp !== undefined) out.sourceApp = item.sourceApp;
        out.pinned = item.pinned;
        return out;
      }),
    };
  }

  /**
   * Reads the Codable form (a parsed clipboard.json). Throws SlatedError("invalidConfiguration")
   * where Swift's decoder would fail: a missing or mistyped field, or an id that isn't a UUID.
   */
  static fromJSON(value, options = {}) {
    const top = keyed(value, []);
    const items = required(top, 'items', [], (v, path) => {
      if (!Array.isArray(v)) throw mismatch(path, 'Array<Any>', v);
      return v.map((entry, i) => decodeItem(entry, [...path, i]));
    });
    return new ClipboardHistory(items, options);
  }
}

// --- Decoding (Swift's synthesized Decodable for ClipboardItem) ------------------------------------

const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const failure = (path, message) => new SlatedError('invalidConfiguration', message, {codingPath: path});
const mismatch = (path, type, v) =>
  failure(path, v === null ? `Cannot get value of type ${type} -- found null value instead` : `Expected to decode ${type}.`);

function keyed(value, path) {
  if (!isObject(value)) throw mismatch(path, 'Dictionary<String, Any>', value);
  return value;
}

function required(object, key, path, decode) {
  if (!Object.prototype.hasOwnProperty.call(object, key)) throw failure([...path, key], `No value associated with key "${key}".`);
  return decode(object[key], [...path, key]);
}

function decodeItem(value, path) {
  const object = keyed(value, path);
  const id = required(object, 'id', path, (v, p) => {
    if (typeof v !== 'string') throw mismatch(p, 'String', v);
    if (!UUID_PATTERN.test(v)) throw failure(p, 'Attempted to decode UUID from invalid UUID string.');
    return v.toUpperCase();
  });
  const text = required(object, 'text', path, (v, p) => {
    if (typeof v !== 'string') throw mismatch(p, 'String', v);
    return v;
  });
  const copiedAt = required(object, 'copiedAt', path, (v, p) => {
    const d = isNumberValue(v) ? asDouble(v) : null;
    if (d === null) throw mismatch(p, 'Double', v);
    return d;
  });
  let sourceApp = null;
  if (object.sourceApp !== undefined && object.sourceApp !== null) {
    if (typeof object.sourceApp !== 'string') throw mismatch([...path, 'sourceApp'], 'String', object.sourceApp);
    sourceApp = object.sourceApp;
  }
  const pinned = required(object, 'pinned', path, (v, p) => {
    if (typeof v !== 'boolean') throw mismatch(p, 'Bool', v);
    return v;
  });
  return {id, text, copiedAt, sourceApp, pinned};
}

// --- Search (Foundation's case- and diacritic-insensitive `range(of:)`) ----------------------------
//
// Foundation compares character by character (extended grapheme clusters), each folded: decomposed,
// with nonspacing and enclosing marks (and emoji skin tones) dropped, then case-folded, so "É" is
// "e", "ß" is "ss" and "ﬁ" is "fi". A match starts and ends at character boundaries of the text. A
// query character that folds to several letters is compared only against what the current text
// character folded to; its remaining letters then skip that many letters of the text unchecked. So
// "ß" finds "sx" but not a lone "s", and "ﬃ" finds "file" but not "ﬁle". The golden vectors in
// fixtures/clipboard.json pin all of this to what macOS does.

const MARKS = /[\p{Mn}\p{Me}\u{1F3FB}-\u{1F3FF}]/gu;

const stripMarks = (s) => s.normalize('NFD').replace(MARKS, '');

/** Full case folding, near enough: upper then lower case twice (ẞ → ß → ss), except dotless ı. */
function caseFold(s) {
  let out = '';
  for (const ch of s) out += ch === 'ı' ? ch : ch.toUpperCase().toLowerCase().toUpperCase().toLowerCase();
  return out;
}

const foldCharacter = (c) => stripMarks(caseFold(stripMarks(c)));

/** Whether `word` occurs in `text` the way Foundation's folding search finds it. */
export function foldedContains(text, word) {
  const pattern = graphemes(word).map(foldCharacter).filter((f) => f !== '');
  if (pattern.length === 0) return false;
  const characters = graphemes(text).map(foldCharacter);
  for (let start = 0; start < characters.length; start++) {
    if (characters[start] !== '' && matchesAt(characters, start, pattern)) return true;
  }
  return false;
}

function matchesAt(characters, start, pattern) {
  let next = start;
  let pending = '';
  const refill = () => {
    while (pending === '' && next < characters.length) pending = characters[next++];
    return pending !== '';
  };
  for (const folded of pattern) {
    if (!refill()) return false;
    const n = Math.min(folded.length, pending.length);
    if (folded.slice(0, n) !== pending.slice(0, n)) return false;
    let skip = folded.length;
    while (skip > 0) {
      if (!refill()) return false;
      const k = Math.min(skip, pending.length);
      pending = pending.slice(k);
      skip -= k;
    }
  }
  // The match ends at a character boundary too: "s" doesn't match half of "ß".
  return pending === '';
}

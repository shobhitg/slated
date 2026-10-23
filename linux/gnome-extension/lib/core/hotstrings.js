// Hotstrings (port of HotstringMatcher.swift and HotstringTemplate.swift).
//
// `HotstringMatcher` watches typed characters and reports when a trigger has been typed; it only
// holds the last few characters needed for matching. `expandTemplate` fills in `{date}`, `{time}`,
// `{datetime}`, `{clipboard}` and `{date:FORMAT}` (a Unicode date pattern such as yyyy-MM-dd), with
// `{{`/`}}` for literal braces, formatting dates the way ICU (and so macOS) does for en_US_POSIX.

import {hotstringDefaults} from './config.js';
import {
  graphemes,
  hasPrefix,
  isNewline,
  isPunctuation,
  isSymbol,
  isWhitespace,
  lowercased,
  stringEquals,
} from './text.js';

/** Characters that end a word: whitespace and punctuation (except `_`) and symbols. */
export function isDelimiter(c) {
  return isWhitespace(c) || isNewline(c) || (isPunctuation(c) && c !== '_') || isSymbol(c);
}

function isAvailable(h, appId) {
  if (appId !== null && appId !== undefined && h.exceptInApps.includes(appId)) return false;
  if (h.onlyInApps.length === 0) return true;
  if (appId === null || appId === undefined) return false;
  return h.onlyInApps.includes(appId);
}

/**
 * Typed-text matcher. `new HotstringMatcher(hotstrings).feed(text, appId)` returns
 * `{hotstring, deleteCount, delimiter}` when this key completes a trigger, else null.
 * `deleteCount` is how many characters already typed must be deleted (the key that completed the
 * match is assumed to be swallowed); `delimiter` is the delimiter that completed an afterDelimiter
 * trigger, to re-type after the replacement. Reset it on clicks, app switches and shortcuts.
 */
export class HotstringMatcher {
  /** @param {Object[]} [hotstrings] hotstrings in config.json's form (missing fields take Swift's defaults) */
  constructor(hotstrings = []) {
    this._buffer = [];
    this._capacity = 1;
    this._entries = [];
    this.update(hotstrings);
  }

  /** The hotstrings that can fire (enabled, non-empty trigger), as given. */
  get hotstrings() {
    return this._entries.map((e) => e.source);
  }

  update(hotstrings) {
    this._entries = (hotstrings ?? [])
      .map((source) => ({source, ...hotstringDefaults(source)}))
      .filter((e) => e.enabled && e.trigger !== '')
      .map((e) => ({...e, chars: graphemes(e.trigger)}));
    // One extra character so word-boundary checks can see what precedes the trigger.
    this._capacity = this._entries.reduce((m, e) => Math.max(m, e.chars.length), 0) + 1;
    if (this._buffer.length > this._capacity) this._buffer.splice(0, this._buffer.length - this._capacity);
  }

  reset() {
    this._buffer = [];
  }

  backspace() {
    this._buffer.pop();
  }

  /** Feeds the text one key produced. Returns a match when this key completes a trigger. */
  feed(text, appId = null) {
    if (this._entries.length === 0 || !text) return null;
    let result = null;
    for (const c of graphemes(text)) {
      result = this._feedCharacter(c, appId) ?? result;
      if (result !== null) break;
    }
    return result;
  }

  _feedCharacter(c, appId) {
    const candidates = this._entries.filter((e) => isAvailable(e, appId));
    // A delimiter can complete an afterDelimiter trigger already in the buffer.
    if (isDelimiter(c)) {
      const hit = this._longestMatch(candidates.filter((e) => e.fire === 'afterDelimiter'));
      if (hit !== null) {
        this.reset();
        return {hotstring: hit.source, deleteCount: hit.chars.length, delimiter: c};
      }
    }
    this._buffer.push(c);
    if (this._buffer.length > this._capacity) this._buffer.splice(0, this._buffer.length - this._capacity);
    const hit = this._longestMatch(candidates.filter((e) => e.fire === 'immediately'));
    if (hit !== null) {
      this.reset();
      return {hotstring: hit.source, deleteCount: hit.chars.length - 1, delimiter: null};
    }
    return null;
  }

  _longestMatch(candidates) {
    const buffer = this._buffer;
    let best = null;
    for (const e of candidates) {
      const n = e.chars.length;
      if (n > buffer.length) continue;
      const tail = buffer.slice(buffer.length - n);
      const matches = e.caseSensitive
        ? tail.every((c, k) => stringEquals(c, e.chars[k]))
        : stringEquals(lowercased(tail.join('')), lowercased(e.trigger));
      if (!matches) continue;
      if (e.wordBoundary) {
        const before = buffer.length - n - 1;
        if (before >= 0 && !isDelimiter(buffer[before])) continue;
      }
      if ((best?.chars.length ?? 0) < n) best = e;
    }
    return best;
  }

  static isDelimiter(c) {
    return isDelimiter(c);
  }
}

// --- Templates -------------------------------------------------------------------------------------

/**
 * Expands placeholders: `{date}`, `{time}`, `{datetime}`, `{clipboard}`, `{date:FORMAT}`. Unknown
 * placeholders stay as written; `{{` and `}}` are literal braces.
 * @param {string} text
 * @param {{now?: Date|number, clipboard?: string|null, locale?: string, timeZone?: "local"|"UTC"|number}} [options]
 *   `now` (a Date or milliseconds since 1970, default now); `locale` for {date}/{time}/{datetime}
 *   (default "en_US_POSIX"; others use Intl when available); `timeZone`: "local" (default), "UTC", or
 *   minutes east of UTC.
 */
export function expandTemplate(text, {now = undefined, clipboard = null, locale = 'en_US_POSIX', timeZone = 'local'} = {}) {
  if (!text.includes('{')) return text;
  const date = now === undefined ? new Date() : new Date(typeof now === 'number' ? now : now.getTime());
  const chars = graphemes(text);
  let output = '';
  let i = 0;
  while (i < chars.length) {
    const c = chars[i];
    if (c === '{' && chars[i + 1] === '{') {
      output += '{';
      i += 2;
      continue;
    }
    if (c === '}' && chars[i + 1] === '}') {
      output += '}';
      i += 2;
      continue;
    }
    if (c === '{') {
      const close = chars.indexOf('}', i);
      if (close >= 0) {
        const value = placeholder(chars.slice(i + 1, close).join(''), date, clipboard, locale, timeZone);
        if (value !== null) {
          output += value;
          i = close + 1;
          continue;
        }
      }
    }
    output += c;
    i++;
  }
  return output;
}

const POSIX_DATE = 'MMM d, y';
const POSIX_TIME = 'h:mm\u202Fa';

function placeholder(token, date, clipboard, locale, timeZone) {
  const lower = lowercased(token);
  switch (lower) {
    case 'date': return styled(date, locale, timeZone, true, false);
    case 'time': return styled(date, locale, timeZone, false, true);
    case 'datetime': return styled(date, locale, timeZone, true, true);
    case 'clipboard': return clipboard ?? '';
    default:
      if (!hasPrefix(lower, 'date:')) return null;
      return formatDate(date, graphemes(token).slice(5).join(''), {timeZone});
  }
}

/** Medium date and/or short time, like DateFormatter's styles. */
function styled(date, locale, timeZone, withDate, withTime) {
  const posix = !locale || locale === 'en_US_POSIX' || typeof Intl === 'undefined';
  if (posix) {
    if (withDate && withTime) return formatDate(date, `${POSIX_DATE} 'at' ${POSIX_TIME}`, {timeZone});
    return formatDate(date, withDate ? POSIX_DATE : POSIX_TIME, {timeZone});
  }
  const options = {};
  if (withDate) options.dateStyle = 'medium';
  if (withTime) options.timeStyle = 'short';
  if (timeZone === 'UTC') options.timeZone = 'UTC';
  try {
    if (typeof timeZone === 'number') {
      return new Intl.DateTimeFormat(locale.replace(/_/g, '-'), {...options, timeZone: 'UTC'}).format(new Date(date.getTime() + timeZone * 60000));
    }
    return new Intl.DateTimeFormat(locale.replace(/_/g, '-'), options).format(date);
  } catch {
    return styled(date, 'en_US_POSIX', timeZone, withDate, withTime);
  }
}

// --- Unicode date patterns (ICU's SimpleDateFormat for en_US_POSIX) ------------------------------------

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const QUARTERS = ['1st quarter', '2nd quarter', '3rd quarter', '4th quarter'];
const PATTERN_LETTERS = 'GyMdkHmsSEDFwWahKzYeugAZvcLQqVUOXxrbB';
const isSyntax = (c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
const pad = (n, width) => String(n).padStart(width, '0');
const DAY = 86400000;

function offsetMinutes(date, timeZone) {
  if (timeZone === 'UTC') return 0;
  if (typeof timeZone === 'number') return timeZone;
  return -date.getTimezoneOffset();
}

/** Calendar fields of `date` in the given time zone (Gregorian; US weeks: Sunday first, 1 day minimum). */
function fields(date, timeZone) {
  const offset = offsetMinutes(date, timeZone);
  const t = date.getTime() + offset * 60000;
  const local = new Date(t);
  const year = local.getUTCFullYear();
  const month = local.getUTCMonth();
  const day = local.getUTCDate();
  const weekday = local.getUTCDay(); // 0 = Sunday
  const dayStart = Date.UTC(year, month, day);
  const dayOfYear = Math.round((dayStart - Date.UTC(year, 0, 1)) / DAY) + 1;
  const ms = ((t % DAY) + DAY) % DAY;
  // Week of year: the week holding January 1 is week 1; the days before next year's January 1 in its
  // week belong to week 1 of next year.
  const jan1Weekday = new Date(Date.UTC(year, 0, 1)).getUTCDay();
  const nextJan1 = Date.UTC(year + 1, 0, 1);
  const weekStart = dayStart - weekday * DAY;
  let weekOfYear;
  let weekYear = year;
  if (weekStart + 6 * DAY >= nextJan1) {
    weekOfYear = 1;
    weekYear = year + 1;
  } else {
    weekOfYear = Math.floor((dayOfYear - 1 + jan1Weekday) / 7) + 1;
  }
  const firstWeekday = new Date(Date.UTC(year, month, 1)).getUTCDay();
  return {
    offset,
    year,
    month,
    day,
    weekday,
    dayOfYear,
    weekOfYear,
    weekYear,
    weekOfMonth: Math.floor((day - 1 + firstWeekday) / 7) + 1,
    hour: Math.floor(ms / 3600000),
    minute: Math.floor(ms / 60000) % 60,
    second: Math.floor(ms / 1000) % 60,
    millisecond: ms % 1000,
    msInDay: ms,
    julianDay: Math.floor(t / DAY) + 2440588,
  };
}

function yearText(y, count) {
  if (count === 2) return pad(((y % 100) + 100) % 100, 2);
  return pad(y, count);
}

function offsetText(minutes, {separator = '', withMinutes = true, optionalMinutes = false, z = false}) {
  if (z && minutes === 0) return 'Z';
  const sign = minutes < 0 ? '-' : '+';
  const h = Math.floor(Math.abs(minutes) / 60);
  const m = Math.abs(minutes) % 60;
  if (optionalMinutes && m === 0) return `${sign}${pad(h, 2)}`;
  return withMinutes ? `${sign}${pad(h, 2)}${separator}${pad(m, 2)}` : `${sign}${pad(h, 2)}`;
}

function gmtText(minutes, long) {
  if (minutes === 0) return 'GMT';
  const sign = minutes < 0 ? '-' : '+';
  const h = Math.floor(Math.abs(minutes) / 60);
  const m = Math.abs(minutes) % 60;
  if (long) return `GMT${sign}${pad(h, 2)}:${pad(m, 2)}`;
  return m === 0 ? `GMT${sign}${h}` : `GMT${sign}${h}:${pad(m, 2)}`;
}

function zoneName(date, f, timeZone, long) {
  // ICU names UTC after the GMT metazone only from 1970 on; before that it falls back to "GMT".
  if (timeZone === 'UTC') return long && date.getTime() >= 0 ? 'Greenwich Mean Time' : 'GMT';
  if (timeZone === 'local' && typeof Intl !== 'undefined') {
    try {
      const parts = new Intl.DateTimeFormat('en-US', {timeZoneName: long ? 'long' : 'short'}).formatToParts(date);
      const name = parts.find((p) => p.type === 'timeZoneName');
      if (name) return name.value;
    } catch {
      // fall through to the GMT form
    }
  }
  return gmtText(f.offset, long);
}

/** One run of a pattern letter, or null when ICU rejects the letter (formatting stops there). */
function field(letter, count, f, date, timeZone) {
  switch (letter) {
    case 'G': return count === 4 ? (f.year > 0 ? 'Anno Domini' : 'Before Christ') : count === 5 ? (f.year > 0 ? 'A' : 'B') : f.year > 0 ? 'AD' : 'BC';
    case 'y': return yearText(f.year > 0 ? f.year : 1 - f.year, count);
    case 'Y': return yearText(f.weekYear, count);
    case 'u': case 'U': case 'r': return pad(f.year, count);
    case 'Q': case 'q': {
      const q = Math.floor(f.month / 3) + 1;
      if (count <= 2) return pad(q, count);
      return count === 3 ? `Q${q}` : count === 4 ? QUARTERS[q - 1] : String(q);
    }
    case 'M': case 'L':
      if (count <= 2) return pad(f.month + 1, count);
      return count === 3 ? MONTHS[f.month].slice(0, 3) : count === 4 ? MONTHS[f.month] : MONTHS[f.month][0];
    case 'w': return pad(f.weekOfYear, count);
    case 'W': return pad(f.weekOfMonth, count);
    case 'd': return pad(f.day, count);
    case 'D': return pad(f.dayOfYear, count);
    case 'F': return pad(Math.floor((f.day - 1) / 7) + 1, count);
    case 'g': return pad(f.julianDay - 2400001, count);
    case 'E': case 'e': case 'c': {
      if (letter !== 'E' && count <= 2) return pad(f.weekday + 1, letter === 'c' ? 1 : count);
      const name = DAYS[f.weekday];
      return count <= 3 ? name.slice(0, 3) : count === 4 ? name : count === 5 ? name[0] : name.slice(0, 2);
    }
    case 'a': case 'b': case 'B': {
      const pm = f.hour >= 12;
      return count === 5 ? (pm ? 'p' : 'a') : pm ? 'PM' : 'AM';
    }
    case 'h': return pad(f.hour % 12 === 0 ? 12 : f.hour % 12, count);
    case 'H': return pad(f.hour, count);
    case 'k': return pad(f.hour === 0 ? 24 : f.hour, count);
    case 'K': return pad(f.hour % 12, count);
    case 'm': return pad(f.minute, count);
    case 's': return pad(f.second, count);
    case 'S': return pad(f.millisecond, 3).padEnd(count, '0').slice(0, count);
    case 'A': return pad(f.msInDay, count);
    case 'z': case 'v': return zoneName(date, f, timeZone, count >= 4);
    case 'V': return timeZone === 'UTC' ? 'UTC' : gmtText(f.offset, true);
    case 'Z':
      if (count <= 3) return offsetText(f.offset, {});
      return count === 4 ? gmtText(f.offset, true) : offsetText(f.offset, {separator: ':', z: true});
    case 'O': return gmtText(f.offset, count >= 4);
    case 'X': case 'x': {
      const z = letter === 'X';
      if (count === 1) return offsetText(f.offset, {optionalMinutes: true, z});
      return offsetText(f.offset, {separator: count === 3 || count === 5 ? ':' : '', z});
    }
    default: return null;
  }
}

/**
 * Formats `date` with a Unicode date pattern ("yyyy-MM-dd", "EEEE, MMMM d", "h:mm a", "'week' w")
 * in English, the way ICU does: letters are fields, '…' quotes literal text ('' is a quote), and an
 * unknown letter ends the output there.
 * @param {Date} date
 * @param {string} pattern
 * @param {{timeZone?: "local"|"UTC"|number}} [options]
 */
export function formatDate(date, pattern, {timeZone = 'local'} = {}) {
  const f = fields(date, timeZone);
  let out = '';
  let inQuote = false;
  let previous = '';
  let count = 0;
  let ok = true;
  const flush = () => {
    if (count === 0) return;
    const text = PATTERN_LETTERS.includes(previous) ? field(previous, count, f, date, timeZone) : null;
    if (text === null) ok = false;
    else out += text;
    count = 0;
  };
  for (let i = 0; i < pattern.length && ok; i++) {
    const c = pattern[i];
    if (c !== previous && count > 0) flush();
    if (c === "'") {
      if (pattern[i + 1] === "'") {
        out += "'";
        i++;
      } else {
        inQuote = !inQuote;
      }
    } else if (!inQuote && isSyntax(c)) {
      previous = c;
      count++;
    } else {
      out += c;
    }
  }
  if (ok) flush();
  return out;
}

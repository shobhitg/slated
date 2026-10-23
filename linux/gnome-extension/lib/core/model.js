// Slate's small value types (private module; from Action.swift and SlateSettings.swift).
//
// In the canonical JSON form of an action these are plain strings: a direction ("up"), a corner
// ("top-left"), a screen reference ("ordered:1", "1920x1080", "next"), a push style
// ("bar-resize:screenSizeX/2"). This module parses and prints them exactly like Swift.

import {
  graphemes,
  hasPrefix,
  lowercased,
  parseDouble,
  parseInt64,
  shortNumber,
  stringEquals,
  trimWhitespace,
} from './text.js';

/**
 * The order a grid's screens were written in Slate syntax. JSON objects can't keep "1" before "0",
 * so the parser records it here (hidden from JSON) and formatting follows it, like Swift's array.
 */
export const GRID_ORDER = Symbol('gridOrder');

/** Drops the first `count` characters (grapheme clusters). */
export const dropFirst = (s, count) => graphemes(s).slice(count).join('');
/** Drops the last `count` characters. */
export const dropLast = (s, count) => {
  const chars = graphemes(s);
  return chars.slice(0, Math.max(0, chars.length - count)).join('');
};

/** Splits at characters for which `isSeparator` is true (Swift's `split(whereSeparator:)`). */
export function splitCharacters(s, isSeparator, omittingEmpty = true) {
  const parts = [];
  let current = '';
  for (const c of graphemes(s)) {
    if (isSeparator(c)) {
      if (!omittingEmpty || current !== '') parts.push(current);
      current = '';
    } else {
      current += c;
    }
  }
  if (!omittingEmpty || current !== '') parts.push(current);
  return parts;
}

// --- Directions and corners ------------------------------------------------------------------------

/** Slate's direction names: also `top`/`above` for up and `bottom`/`below` for down. */
export function directionFromSlate(raw) {
  switch (lowercased(raw)) {
    case 'left': return 'left';
    case 'right': return 'right';
    case 'up': case 'top': case 'above': return 'up';
    case 'down': case 'bottom': case 'below': return 'down';
    default: return null;
  }
}

export const CORNERS = ['top-left', 'top-right', 'bottom-left', 'bottom-right'];
/** `Corner(rawValue:)`: exact spelling. */
export const cornerFromRaw = (raw) => (CORNERS.includes(raw) ? raw : null);

export function focusDirectionFromSlate(raw) {
  if (lowercased(raw) === 'behind') return 'behind';
  return directionFromSlate(raw);
}

export const INSERT_METHODS = ['auto', 'type', 'paste'];

// --- Screen references ---------------------------------------------------------------------------

/**
 * Parses Slate's screen reference syntax (ScreenRef(slate:)): an index, `ordered:N`, a resolution
 * like 1680x1050, a direction, `next` or `previous`/`prev`.
 * @returns {{kind: "index"|"ordered", index: number|bigint} | {kind: "resolution", width, height} |
 *   {kind: "relative", direction: string} | {kind: "next"|"previous"} | null}
 */
export function screenRefFromSlate(raw) {
  const s = trimWhitespace(raw);
  const index = parseInt64(s);
  if (index !== null) return {kind: 'index', index};
  const lower = lowercased(s);
  if (hasPrefix(lower, 'ordered:')) {
    const ordered = parseInt64(dropFirst(s, 'ordered:'.length));
    if (ordered !== null) return {kind: 'ordered', index: ordered};
  }
  if (lower === 'next') return {kind: 'next'};
  if (lower === 'previous' || lower === 'prev') return {kind: 'previous'};
  const direction = directionFromSlate(s);
  if (direction !== null) return {kind: 'relative', direction};
  const parts = splitCharacters(lower, (c) => c === 'x');
  if (parts.length !== 2) return null;
  const width = parseInt64(parts[0]);
  const height = parseInt64(parts[1]);
  if (width === null || height === null) return null;
  return {kind: 'resolution', width, height};
}

/** The canonical text of a parsed screen reference (`ScreenRef.slate`). */
export function screenRefToSlate(ref) {
  switch (ref.kind) {
    case 'index': return String(ref.index);
    case 'ordered': return `ordered:${ref.index}`;
    case 'resolution': return `${ref.width}x${ref.height}`;
    case 'relative': return ref.direction;
    default: return ref.kind;
  }
}

// --- Push styles -----------------------------------------------------------------------------------

/** PushStyle(slate:) → canonical text ("none", "center", "bar", "bar-resize:<expr>") or null. */
export function pushStyleFromSlate(raw) {
  const s = trimWhitespace(raw);
  const lower = lowercased(s);
  if (lower === '' || lower === 'none') return 'none';
  if (lower === 'center' || lower === 'bar') return lower;
  if (!hasPrefix(lower, 'bar-resize:')) return null;
  return `bar-resize:${dropFirst(s, 'bar-resize:'.length)}`;
}

/** The expression of a `bar-resize:` style, or null for other styles. */
export const barResizeExpression = (style) =>
  style.startsWith('bar-resize:') ? style.slice('bar-resize:'.length) : null;

// --- App selectors (hide/show/toggle) -----------------------------------------------------------

/** AppSelector's JSON decoding from a string: current, all, all-but:Name or one app name. */
export function appSelectorFromString(raw) {
  const lower = lowercased(raw);
  if (lower === 'current') return 'current';
  if (lower === 'all') return 'all';
  if (hasPrefix(lower, 'all-but:')) return `all-but:${dropFirst(raw, 'all-but:'.length)}`;
  return [raw];
}

// --- Slate settings (`config name value`) ----------------------------------------------------------

/** SettingValue(slate:): booleans (true/yes/false/no), numbers, otherwise the text. */
export function settingFromSlate(raw) {
  const s = trimWhitespace(raw);
  switch (lowercased(s)) {
    case 'true': case 'yes': return true;
    case 'false': case 'no': return false;
    default: {
      const n = parseDouble(s);
      return n === null ? s : n;
    }
  }
}

export function settingBool(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  const lower = lowercased(String(value));
  if (['true', 'yes', '1'].includes(lower)) return true;
  if (['false', 'no', '0'].includes(lower)) return false;
  return null;
}

export function settingDouble(value) {
  if (typeof value === 'boolean') return value ? 1 : 0;
  if (typeof value === 'number') return value;
  return parseDouble(String(value));
}

export function settingString(value) {
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') return shortNumber(value);
  return String(value);
}

/** Sets `key` in a settings object, reusing an existing key that is equal as a Swift string. */
export function setSetting(settings, key, value) {
  const existing = Object.keys(settings).find((k) => stringEquals(k, key));
  settings[existing ?? key] = value;
}

function lookup(values, key) {
  return values && Object.prototype.hasOwnProperty.call(values, key) ? values[key] : undefined;
}

/**
 * Typed reading of Slate's global settings with Slate's defaults (SlateSettings' accessors).
 * @param {Object<string, boolean|number|string>} [values]
 */
export function readSettings(values = {}) {
  const bool = (key, d) => {
    const v = lookup(values, key);
    return v === undefined ? d : settingBool(v) ?? d;
  };
  const double = (key, d) => {
    const v = lookup(values, key);
    return v === undefined ? d : settingDouble(v) ?? d;
  };
  const string = (key, d) => {
    const v = lookup(values, key);
    return v === undefined ? d : settingString(v);
  };
  return {
    bool,
    double,
    string,
    /** Use the window's screen when a named screen doesn't exist (Slate's default: false). */
    defaultToCurrentScreen: bool('defaultToCurrentScreen', false),
    /** `windowSize` or `screenSize`: what nudge percentages are relative to. */
    nudgePercentOf: string('nudgePercentOf', 'screenSize'),
    /** `windowSize` or `screenSize`: what resize percentages are relative to. */
    resizePercentOf: string('resizePercentOf', 'screenSize'),
    orderScreensLeftToRight: bool('orderScreensLeftToRight', true),
    /** Action names that repeat while their hotkey is held. */
    repeatOnHoldOps: splitCharacters(string('repeatOnHoldOps', 'resize,nudge'), (c) => c === ',').map(trimWhitespace),
    secondsBeforeRepeat: double('secondsBeforeRepeat', 0.4),
    secondsBetweenRepeat: double('secondsBetweenRepeat', 0.1),
    undoMaxStackSize: Math.trunc(double('undoMaxStackSize', 10)),
    focusCheckWidth: double('focusCheckWidth', 100),
    focusCheckWidthMax: double('focusCheckWidthMax', 100),
    focusPreferSameApp: bool('focusPreferSameApp', true),
    checkDefaultsOnLoad: bool('checkDefaultsOnLoad', false),
    windowHintsCharacters: string('windowHintsCharacters', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'),
  };
}

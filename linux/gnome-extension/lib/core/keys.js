// Key combos (port of KeyCombo.swift), plus their GNOME accelerator form.
//
// A KeyCombo is `{key, modifiers}`: `key` uses Slate's key names (letters and digits, punctuation
// such as `'` and `;`, and named keys like `left`, `return`, `f1`…`f20`, `pad1`, `padEnter`);
// `modifiers` is a subset of ["ctrl", "alt", "shift", "cmd", "fn"] in that order. In config.json a
// combo is a string such as "hyper+a" (hyper = ctrl+alt+shift+cmd; "cmd" is Super on Linux).

import {SlatedError} from './errors.js';
import {characterCount, graphemes, hasPrefix, hasSuffix, lowercased, trimWhitespace, uppercased} from './text.js';

const CTRL = 1, ALT = 2, SHIFT = 4, CMD = 8, FN = 16;
const HYPER = CTRL | ALT | SHIFT | CMD;
const MEH = CTRL | ALT | SHIFT;
const ORDER = [['ctrl', CTRL], ['alt', ALT], ['shift', SHIFT], ['cmd', CMD], ['fn', FN]];

/** One modifier token (Slate's names plus aliases and glyphs) as a bit mask, or null. */
export function modifierMask(raw) {
  switch (lowercased(raw)) {
    case 'ctrl': case 'control': case '⌃': return CTRL;
    case 'alt': case 'opt': case 'option': case '⌥': return ALT;
    case 'shift': case '⇧': return SHIFT;
    case 'cmd': case 'command': case '⌘': return CMD;
    case 'fn': case 'function': return FN;
    case 'hyper': case '✦': return HYPER;
    case 'meh': return MEH;
    default: return null;
  }
}

/** A token's modifiers as a list in canonical order, or null for an unknown token. */
export function modifierToken(raw) {
  const mask = modifierMask(raw);
  return mask === null ? null : modifiersFromMask(mask);
}

export const modifiersFromMask = (mask) => ORDER.filter(([, bit]) => mask & bit).map(([name]) => name);

function maskOf(modifiers) {
  let mask = 0;
  for (const token of modifiers ?? []) {
    const m = modifierMask(token);
    if (m === null) throw new SlatedError('invalidSyntax', `Unknown modifier "${token}"`);
    mask |= m;
  }
  return mask;
}

// --- Key names -------------------------------------------------------------------------------------

/**
 * Modifier keys on their own: holdable for automation (`hold key:shift` toggles sprint), but not usable
 * as shortcuts by themselves.
 */
export const MODIFIER_KEYS = Object.freeze(['shift', 'ctrl', 'alt', 'cmd', 'rightShift', 'rightCtrl', 'rightAlt', 'rightCmd']);

/** Extra mouse buttons usable as triggers on macOS: middle (3), back (4) and forward (5). */
export const MOUSE_BUTTON_KEYS = Object.freeze(['mouse3', 'mouse4', 'mouse5']);

const NAMED = new Map();
for (const n of [
  'left', 'right', 'up', 'down', 'return', 'tab', 'space', 'delete', 'forwardDelete', 'esc', 'home', 'end', 'pageUp',
  'pageDown', 'help', 'caps', 'mute', 'volumeUp', 'volumeDown', 'backslash', 'padClear', 'padEnter', 'pad=', 'pad*',
  'pad+', 'pad-', 'pad.', 'pad/', ...MODIFIER_KEYS, ...MOUSE_BUTTON_KEYS,
]) {
  NAMED.set(n.toLowerCase(), n);
}
for (let i = 0; i <= 9; i++) NAMED.set(`pad${i}`, `pad${i}`);
for (let i = 1; i <= 20; i++) NAMED.set(`f${i}`, `f${i}`);
NAMED.set('escape', 'esc');
NAMED.set('enter', 'return');
NAMED.set('backspace', 'delete');
NAMED.set('pageup', 'pageUp');
NAMED.set('pagedown', 'pageDown');

/** Every named key's canonical spelling ("left", "f10", "pad=", "rightShift"…): KeyNames.named's values. */
export function namedKeys() {
  return [...new Set(NAMED.values())];
}

/** Normalizes a key name: named keys get their canonical spelling, single characters are lowercased. */
export function canonicalKey(key) {
  const named = NAMED.get(lowercased(key));
  if (named !== undefined) return named;
  return characterCount(key) === 1 ? lowercased(key) : key;
}

/** Whether Slate knows the key: a named key or a single character. */
export function isValidKey(key) {
  return NAMED.has(lowercased(key)) || characterCount(key) === 1;
}

/** A modifier key on its own (`shift`, `rightCmd`…), which can be held but isn't a shortcut. */
export function isModifierKey(key) {
  return MODIFIER_KEYS.includes(canonicalKey(String(key)));
}

/** Mouse button 3, 4 or 5 as a shortcut key (macOS only; GNOME can't grab mouse buttons). */
export function isMouseButton(key) {
  return MOUSE_BUTTON_KEYS.includes(canonicalKey(String(key)));
}

const DISPLAY = {
  left: '←', right: '→', up: '↑', down: '↓', return: '↩', tab: '⇥', space: 'Space', delete: '⌫', forwardDelete: '⌦',
  esc: '⎋', home: '↖', end: '↘', pageUp: '⇞', pageDown: '⇟', padEnter: '⌤', backslash: '\\', caps: '⇪',
  shift: '⇧', ctrl: '⌃', alt: '⌥', cmd: '⌘', rightShift: 'Right ⇧', rightCtrl: 'Right ⌃', rightAlt: 'Right ⌥',
  rightCmd: 'Right ⌘', mouse3: 'Middle Click', mouse4: 'Mouse 4', mouse5: 'Mouse 5',
};

/** How a key is shown in menus and settings: arrows and symbols for named keys, "Pad 1", "F5", "A". */
export function keyDisplayName(key) {
  if (Object.prototype.hasOwnProperty.call(DISPLAY, key)) return DISPLAY[key];
  if (hasPrefix(key, 'pad')) return `Pad ${graphemes(key).slice(3).join('')}`;
  return uppercased(key);
}

// --- Combos ------------------------------------------------------------------------------------------

function combo(key, mask) {
  return {key: canonicalKey(key), modifiers: modifiersFromMask(mask)};
}

/**
 * Parses "hyper+a", "ctrl+cmd+left", "cmd+shift+'", "pad+" (the keypad plus key). The key is the
 * last `+`-separated part, so "cmd++" is ⌘ and the + key. Returns null if invalid.
 * @returns {{key: string, modifiers: string[]} | null}
 */
export function parseKeyCombo(string) {
  if (typeof string !== 'string') return null;
  const trimmed = trimWhitespace(string);
  if (trimmed === '') return null;
  const parts = trimmed.split('+');
  let key;
  if (hasSuffix(trimmed, '+')) {
    if (hasSuffix(lowercased(trimmed), 'pad+')) {
      key = 'pad+';
    } else if (trimmed === '+' || hasSuffix(trimmed, '++')) {
      key = '+';
    } else {
      return null; // "cmd+": modifiers but no key
    }
    parts.splice(-2, 2);
  } else {
    key = parts.pop();
  }
  let mask = 0;
  for (const part of parts) {
    if (part === '') continue;
    const m = modifierMask(trimWhitespace(part));
    if (m === null) return null;
    mask |= m;
  }
  key = trimWhitespace(key);
  if (key === '') return null;
  return combo(key, mask);
}

function toCombo(value) {
  if (typeof value === 'string') return parseKeyCombo(value);
  if (value === null || typeof value !== 'object') return null;
  return combo(String(value.key ?? ''), maskOf(value.modifiers));
}

function tokens(mask) {
  if ((mask & HYPER) === HYPER) return mask & FN ? ['fn', 'hyper'] : ['hyper'];
  const names = [];
  if (mask & FN) names.push('fn');
  if (mask & CTRL) names.push('ctrl');
  if (mask & ALT) names.push('alt');
  if (mask & SHIFT) names.push('shift');
  if (mask & CMD) names.push('cmd');
  return names;
}

/**
 * The canonical config string, e.g. "hyper+a", "fn+ctrl+f1", "shift+cmd+4".
 * @param {{key: string, modifiers: string[]} | string} value a KeyCombo (or a combo string)
 */
export function formatKeyCombo(value) {
  const c = toCombo(value);
  if (c === null) throw new SlatedError('invalidSyntax', `Invalid key combo "${value}"`);
  return [...tokens(maskOf(c.modifiers)), c.key].join('+');
}

/**
 * The display form, e.g. "⌃⌥⇧⌘A", or "✦A" when `hyperGlyph` is true (the default) and all four
 * modifiers are held.
 */
export function displayKeyCombo(value, {hyperGlyph = true} = {}) {
  const c = toCombo(value);
  if (c === null) return '';
  const mask = maskOf(c.modifiers);
  let mods;
  if (hyperGlyph && (mask & HYPER) === HYPER) {
    mods = mask & FN ? 'fn✦' : '✦';
  } else {
    mods = `${mask & FN ? 'fn' : ''}${mask & CTRL ? '⌃' : ''}${mask & ALT ? '⌥' : ''}${mask & SHIFT ? '⇧' : ''}${mask & CMD ? '⌘' : ''}`;
  }
  return mods + keyDisplayName(c.key);
}

// --- GNOME accelerators ------------------------------------------------------------------------------

const NAMED_KEYSYMS = {
  left: 'Left', right: 'Right', up: 'Up', down: 'Down', return: 'Return', tab: 'Tab', space: 'space',
  delete: 'BackSpace', forwardDelete: 'Delete', esc: 'Escape', home: 'Home', end: 'End', pageUp: 'Page_Up',
  pageDown: 'Page_Down', help: 'Help', caps: 'Caps_Lock', mute: 'XF86AudioMute', volumeUp: 'XF86AudioRaiseVolume',
  volumeDown: 'XF86AudioLowerVolume', backslash: 'backslash',
  // The Mac keypad's Clear key sits where PC keyboards (and Apple keyboards on Linux) have Num Lock.
  padClear: 'Num_Lock', padEnter: 'KP_Enter', 'pad=': 'KP_Equal', 'pad*': 'KP_Multiply', 'pad+': 'KP_Add',
  'pad-': 'KP_Subtract', 'pad.': 'KP_Decimal', 'pad/': 'KP_Divide',
  // Modifier keys, for holding them (automation). The left-hand key is the plain name.
  shift: 'Shift_L', ctrl: 'Control_L', alt: 'Alt_L', cmd: 'Super_L', rightShift: 'Shift_R', rightCtrl: 'Control_R',
  rightAlt: 'Alt_R', rightCmd: 'Super_R',
};

// X keysym names of the printable ASCII punctuation.
const ASCII_KEYSYMS = {
  ' ': 'space', '!': 'exclam', '"': 'quotedbl', '#': 'numbersign', $: 'dollar', '%': 'percent', '&': 'ampersand',
  "'": 'apostrophe', '(': 'parenleft', ')': 'parenright', '*': 'asterisk', '+': 'plus', ',': 'comma', '-': 'minus',
  '.': 'period', '/': 'slash', ':': 'colon', ';': 'semicolon', '<': 'less', '=': 'equal', '>': 'greater', '?': 'question',
  '@': 'at', '[': 'bracketleft', '\\': 'backslash', ']': 'bracketright', '^': 'asciicircum', _: 'underscore', '`': 'grave',
  '{': 'braceleft', '|': 'bar', '}': 'braceright', '~': 'asciitilde',
};

// X keysym names of Latin-1 (U+00A0–U+00FF); their keysym values equal the code points.
const LATIN1_KEYSYMS = (
  'nobreakspace exclamdown cent sterling currency yen brokenbar section diaeresis copyright ordfeminine ' +
  'guillemotleft notsign hyphen registered macron degree plusminus twosuperior threesuperior acute mu paragraph ' +
  'periodcentered cedilla onesuperior masculine guillemotright onequarter onehalf threequarters questiondown ' +
  'Agrave Aacute Acircumflex Atilde Adiaeresis Aring AE Ccedilla Egrave Eacute Ecircumflex Ediaeresis Igrave Iacute ' +
  'Icircumflex Idiaeresis ETH Ntilde Ograve Oacute Ocircumflex Otilde Odiaeresis multiply Oslash Ugrave Uacute ' +
  'Ucircumflex Udiaeresis Yacute THORN ssharp agrave aacute acircumflex atilde adiaeresis aring ae ccedilla egrave ' +
  'eacute ecircumflex ediaeresis igrave iacute icircumflex idiaeresis eth ntilde ograve oacute ocircumflex otilde ' +
  'odiaeresis division oslash ugrave uacute ucircumflex udiaeresis yacute thorn ydiaeresis'
).split(' ');

/** The X/GDK keysym name for a Slate key name, or null when there is none. */
export function keysymName(key) {
  const k = canonicalKey(key);
  if (Object.prototype.hasOwnProperty.call(NAMED_KEYSYMS, k)) return NAMED_KEYSYMS[k];
  const f = /^f([0-9]+)$/.exec(k);
  if (f && NAMED.has(k)) return `F${f[1]}`;
  const pad = /^pad([0-9])$/.exec(k);
  if (pad) return `KP_${pad[1]}`;
  if (characterCount(k) !== 1) return null;
  const points = Array.from(k);
  if (points.length !== 1) return null; // a character made of several code points has no keysym
  const cp = points[0].codePointAt(0);
  if ((cp >= 0x30 && cp <= 0x39) || (cp >= 0x61 && cp <= 0x7a)) return k;
  if (Object.prototype.hasOwnProperty.call(ASCII_KEYSYMS, k)) return ASCII_KEYSYMS[k];
  if (cp >= 0xa0 && cp <= 0xff) return LATIN1_KEYSYMS[cp - 0xa0];
  if (cp === 0x20ac) return 'EuroSign';
  if (cp < 0x20 || cp === 0x7f) return null;
  return `U${cp.toString(16).toUpperCase().padStart(4, '0')}`;
}

/**
 * A GNOME accelerator string, e.g. {key: "a", modifiers: ["ctrl", "alt", "shift", "cmd"]} →
 * "<Control><Alt><Shift><Super>a". With `hyperMode: "xkb"`, a combo holding all four Hyper
 * modifiers becomes "<Hyper>a" (for a Caps Lock mapped to XKB's Hyper modifier). `fn` has no
 * accelerator form and is ignored. Returns null when the key has no keysym.
 * @param {{key: string, modifiers: string[]} | string} value a KeyCombo or a config string like "hyper+a"
 * @param {{hyperMode?: "modifiers"|"xkb"}} [options]
 */
export function toGnomeAccelerator(value, {hyperMode = 'modifiers'} = {}) {
  const c = toCombo(value);
  if (c === null) return null;
  const keysym = keysymName(c.key);
  if (keysym === null) return null;
  const mask = maskOf(c.modifiers);
  if (hyperMode === 'xkb' && (mask & HYPER) === HYPER) return `<Hyper>${keysym}`;
  return `${mask & CTRL ? '<Control>' : ''}${mask & ALT ? '<Alt>' : ''}${mask & SHIFT ? '<Shift>' : ''}${mask & CMD ? '<Super>' : ''}${keysym}`;
}

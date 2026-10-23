// Swift String semantics the engine depends on (private module).
//
// SlatedCore works on Swift Characters (extended grapheme clusters), Character properties, Foundation's
// CharacterSet trimming, Int(String)/Double(String) parsing and Double's description. Error columns,
// key validity ("a single character") and hotstring buffers all count Characters, so this module
// reproduces those rules on JavaScript strings. Plain ES2020: runs in GJS, Node and JavaScriptCore.

// --- Grapheme clusters (Unicode UAX #29, as Swift's Character implements it) --------------------

const CR = 1, LF = 2, CONTROL = 3, EXTEND = 4, ZWJ = 5, RI = 6, PREPEND = 7, SPACING_MARK = 8;
const L = 9, V = 10, T = 11, LV = 12, LVT = 13, PICTOGRAPHIC = 14, OTHER = 0;

// Prepended_Concatenation_Mark and Indic prefixes (Grapheme_Cluster_Break=Prepend).
const PREPEND_POINTS = new Set([
  0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06dd, 0x070f, 0x0890, 0x0891, 0x08e2, 0x0d4e, 0x110bd, 0x110cd,
  0x111c2, 0x111c3, 0x1193f, 0x11941, 0x11a3a, 0x11a84, 0x11a85, 0x11a86, 0x11a87, 0x11a88, 0x11a89, 0x11d46, 0x11f02,
]);

// Spacing combining marks that UAX #29 does not treat as SpacingMark.
const NOT_SPACING_MARK = new Set([
  0x102b, 0x102c, 0x1038, 0x1062, 0x1063, 0x1064, 0x1067, 0x1068, 0x1069, 0x106a, 0x106b, 0x106c, 0x106d, 0x1083,
  0x1087, 0x1088, 0x1089, 0x108a, 0x108b, 0x108c, 0x108f, 0x109a, 0x109b, 0x109c, 0x1a61, 0x1a63, 0x1a64, 0xaa7b,
  0xaa7d, 0x11720, 0x11721,
]);

// Indic_Conjunct_Break (GB9c): the viramas that link consonants into one character, and the
// consonants of Devanagari, Bengali, Gujarati, Oriya, Telugu and Malayalam.
const INDIC_LINKERS = new Set([0x094d, 0x09cd, 0x0acd, 0x0b4d, 0x0c4d, 0x0d4d]);
const INDIC_CONSONANTS = [
  [0x0915, 0x0939], [0x0958, 0x095f], [0x0978, 0x097f], [0x0995, 0x09a8], [0x09aa, 0x09b0], [0x09b2, 0x09b2],
  [0x09b6, 0x09b9], [0x09dc, 0x09dd], [0x09df, 0x09df], [0x09f0, 0x09f1], [0x0a95, 0x0aa8], [0x0aaa, 0x0ab0],
  [0x0ab2, 0x0ab3], [0x0ab5, 0x0ab9], [0x0af9, 0x0af9], [0x0b15, 0x0b28], [0x0b2a, 0x0b30], [0x0b32, 0x0b33],
  [0x0b35, 0x0b39], [0x0b5c, 0x0b5d], [0x0b5f, 0x0b5f], [0x0b71, 0x0b71], [0x0c15, 0x0c28], [0x0c2a, 0x0c39],
  [0x0c58, 0x0c5a], [0x0d15, 0x0d3a],
];
const isIndicConsonant = (cp) => cp >= 0x0915 && cp <= 0x0d3a && INDIC_CONSONANTS.some(([a, b]) => cp >= a && cp <= b);

const reControl = /^[\p{Zl}\p{Zp}\p{Cc}\p{Cf}]$/u;
const reExtend = /^[\p{Grapheme_Extend}\p{Emoji_Modifier}]$/u;
const reSpacingMark = /^\p{Mc}$/u;
const rePictographic = /^\p{Extended_Pictographic}$/u;

const categoryCache = new Map();

function category(cp) {
  if (cp < 0x7f) return cp === 0x0d ? CR : cp === 0x0a ? LF : cp < 0x20 ? CONTROL : OTHER;
  if (cp < 0xa0) return CONTROL;
  if (cp === 0x200d) return ZWJ;
  if (cp === 0x200c) return EXTEND;
  if ((cp >= 0x1100 && cp <= 0x115f) || (cp >= 0xa960 && cp <= 0xa97c)) return L;
  if ((cp >= 0x1160 && cp <= 0x11a7) || (cp >= 0xd7b0 && cp <= 0xd7c6)) return V;
  if ((cp >= 0x11a8 && cp <= 0x11ff) || (cp >= 0xd7cb && cp <= 0xd7fb)) return T;
  if (cp >= 0xac00 && cp <= 0xd7a3) return (cp - 0xac00) % 28 === 0 ? LV : LVT;
  if (cp >= 0x1f1e6 && cp <= 0x1f1ff) return RI;
  let cached = categoryCache.get(cp);
  if (cached !== undefined) return cached;
  const c = String.fromCodePoint(cp);
  if (PREPEND_POINTS.has(cp)) cached = PREPEND;
  else if (reControl.test(c)) cached = CONTROL;
  else if (reExtend.test(c)) cached = EXTEND;
  else if (cp === 0x0e33 || cp === 0x0eb3 || (reSpacingMark.test(c) && !NOT_SPACING_MARK.has(cp))) cached = SPACING_MARK;
  else if (rePictographic.test(c)) cached = PICTOGRAPHIC;
  else cached = OTHER;
  categoryCache.set(cp, cached);
  return cached;
}

/** Splits `s` into Swift Characters (extended grapheme clusters). */
export function graphemes(s) {
  const out = [];
  let current = '';
  let previous = -1;
  let regionalCount = 0; // regional indicators immediately before this point
  let emoji = 0; // 1: after Extended_Pictographic Extend*, 2: …followed by ZWJ
  let indic = 0; // 1: after an Indic consonant [Extend|Linker]*, 2: …with a linker among them
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    const cat = category(cp);
    const consonant = isIndicConsonant(cp);
    if (previous === -1) {
      current = ch;
    } else if (joins(previous, cat, regionalCount, emoji) || (consonant && indic === 2)) {
      current += ch; // GB9c: consonant (extend|linker)* linker (extend|linker)* × consonant
    } else {
      out.push(current);
      current = ch;
    }
    regionalCount = cat === RI ? regionalCount + 1 : 0;
    if (cat === PICTOGRAPHIC) emoji = 1;
    else if (emoji === 1 && cat === EXTEND) emoji = 1;
    else if (emoji === 1 && cat === ZWJ) emoji = 2;
    else emoji = 0;
    if (consonant) indic = 1;
    else if (indic !== 0 && INDIC_LINKERS.has(cp)) indic = 2;
    else if (indic !== 0 && (cat === EXTEND || cat === ZWJ)) indic = Math.max(indic, 1);
    else indic = 0;
    previous = cat;
  }
  if (previous !== -1) out.push(current);
  return out;
}

function joins(previous, cat, regionalCount, emoji) {
  if (previous === CR && cat === LF) return true; // GB3
  if (previous === CONTROL || previous === CR || previous === LF) return false; // GB4
  if (cat === CONTROL || cat === CR || cat === LF) return false; // GB5
  if (previous === L && (cat === L || cat === V || cat === LV || cat === LVT)) return true; // GB6
  if ((previous === LV || previous === V) && (cat === V || cat === T)) return true; // GB7
  if ((previous === LVT || previous === T) && cat === T) return true; // GB8
  if (cat === EXTEND || cat === ZWJ) return true; // GB9
  if (cat === SPACING_MARK) return true; // GB9a
  if (previous === PREPEND) return true; // GB9b
  if (previous === ZWJ && cat === PICTOGRAPHIC && emoji === 2) return true; // GB11
  if (previous === RI && cat === RI && regionalCount % 2 === 1) return true; // GB12, GB13
  return false;
}

/** Swift's `String.count`. */
export function characterCount(s) {
  return graphemes(s).length;
}

/** True when `index` (a UTF-16 offset) falls between two Characters of `s`. */
export function isCharacterBoundary(s, index) {
  if (index <= 0 || index >= s.length) return true;
  let offset = 0;
  for (const g of graphemes(s)) {
    offset += g.length;
    if (offset === index) return true;
    if (offset > index) return false;
  }
  return false;
}

/** Swift's `hasPrefix` (Character-wise: the prefix must end on a Character boundary). */
export function hasPrefix(s, prefix) {
  return s.startsWith(prefix) && isCharacterBoundary(s, prefix.length);
}

/** Swift's `hasSuffix`. */
export function hasSuffix(s, suffix) {
  return s.endsWith(suffix) && isCharacterBoundary(s, s.length - suffix.length);
}

// --- Character properties (Swift looks at a Character's first scalar) ------------------------------

const reWhiteSpace = /^\p{White_Space}/u;
const reNewline = /^[\n\v\f\r\u0085\u2028\u2029]/;
const reAlphabetic = /^\p{Alphabetic}/u;
const reNumeric = /^\p{N}/u;
const rePunctuation = /^\p{P}/u;
const reSymbol = /^\p{S}/u;

export const isWhitespace = (c) => reWhiteSpace.test(c);
export const isNewline = (c) => reNewline.test(c);
export const isLetter = (c) => reAlphabetic.test(c);
export const isNumber = (c) => reNumeric.test(c);
export const isPunctuation = (c) => rePunctuation.test(c);
export const isSymbol = (c) => reSymbol.test(c);
/** Swift's `Character.isASCII` ("\r\n" counts, as its asciiValue is a line feed). */
export const isASCII = (c) => c === '\r\n' || (c.length === 1 && c.charCodeAt(0) < 0x80);
export const isASCIIDigit = (c) => c.length === 1 && c >= '0' && c <= '9';

// --- Foundation CharacterSet trimming (by Unicode scalar, like NSString) ----------------------------
//
// CoreFoundation's whitespace set is the space separators (Zs) plus tab plus ZERO WIDTH SPACE
// (U+200B, a space separator in old Unicode versions); `whitespacesAndNewlines` adds the line breaks.
// (Swift's Character.isWhitespace, used elsewhere, is Unicode's White_Space property instead.)

const reWhitespaces = /^[\t\u200b\p{Zs}]$/u;
const reWhitespacesAndNewlines = /^[\t\n\v\f\r\u0085\u2028\u2029\u200b\p{Zs}]$/u;

function trimSet(s, re) {
  const points = Array.from(s);
  let start = 0;
  let end = points.length;
  while (start < end && re.test(points[start])) start++;
  while (end > start && re.test(points[end - 1])) end--;
  return start === 0 && end === points.length ? s : points.slice(start, end).join('');
}

/** `trimmingCharacters(in: .whitespaces)`: spaces (Zs), tabs and U+200B. */
export const trimWhitespace = (s) => trimSet(s, reWhitespaces);
/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export const trimWhitespaceAndNewlines = (s) => trimSet(s, reWhitespacesAndNewlines);

// --- Case mapping (Swift maps scalar by scalar, without context-sensitive rules) -------------------

export function lowercased(s) {
  let out = '';
  for (const ch of s) out += ch.toLowerCase();
  return out;
}

export function uppercased(s) {
  let out = '';
  for (const ch of s) out += ch.toUpperCase();
  return out;
}

/** Swift String equality (canonical equivalence). */
export function stringEquals(a, b) {
  return a === b || a.normalize('NFC') === b.normalize('NFC');
}

/** Swift's String `<`: Unicode scalar order of the NFC forms. */
export function compareStrings(a, b) {
  const x = Array.from(a.normalize('NFC'), (c) => c.codePointAt(0));
  const y = Array.from(b.normalize('NFC'), (c) => c.codePointAt(0));
  const n = Math.min(x.length, y.length);
  for (let i = 0; i < n; i++) if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  return x.length - y.length;
}

// --- Numbers ---------------------------------------------------------------------------------------

const INT_MIN = -(2n ** 63n);
const INT_MAX = 2n ** 63n - 1n;

/** A Swift `Int` as a JavaScript number when it is exact, otherwise a BigInt. */
export function intValue(big) {
  const n = Number(big);
  return Number.isSafeInteger(n) ? n : big;
}

/** Swift's `Int(String)`: optional sign and ASCII digits only, within 64 bits; null otherwise. */
export function parseInt64(text) {
  if (!/^[+-]?[0-9]+$/.test(text)) return null;
  const big = BigInt(text.startsWith('+') ? text.slice(1) : text);
  if (big < INT_MIN || big > INT_MAX) return null;
  return intValue(big);
}

/** Integer check for parsed Int values, which may be BigInt. */
export function isInt(value) {
  return typeof value === 'bigint' || Number.isInteger(value);
}

const hexDigitValue = (c) => parseInt(c, 16);

/** The value of hexadecimal digits with an optional fraction and binary exponent (C's strtod). */
export function hexFloatValue(intDigits, fracDigits, exponent) {
  let mantissa = 0n;
  for (const c of intDigits + fracDigits) mantissa = mantissa * 16n + BigInt(hexDigitValue(c));
  let power = (exponent || 0) - 4 * fracDigits.length;
  if (mantissa === 0n) return 0;
  // Keep the conversion exact: scale by powers of two only.
  let value = Number(mantissa);
  if (!Number.isFinite(value) || BigInt(value) !== mantissa) {
    // More than 53 significant bits: round to nearest via the top bits.
    const bits = mantissa.toString(2).length;
    const shift = bits - 64;
    value = Number(mantissa >> BigInt(shift));
    power += shift;
  }
  return value * 2 ** power;
}

/**
 * Swift's `Double(String)`: optional sign, then a decimal or hexadecimal floating-point number,
 * `inf`/`infinity` or `nan` (any case). The whole text must match; no surrounding whitespace.
 * Returns null when Swift returns nil.
 */
export function parseDouble(text) {
  const m = /^([+-]?)(?:(inf|infinity)|(nan(?:\([0-9A-Za-z_]*\))?)|0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?[0-9]+))?|((?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?))$/i.exec(
    text,
  );
  if (!m) return null;
  const sign = m[1] === '-' ? -1 : 1;
  if (m[2]) return sign * Infinity;
  if (m[3]) return NaN;
  if (m[7] !== undefined) return sign * Number(m[7]);
  const intDigits = m[4] ?? '';
  const fracDigits = m[5] ?? '';
  if (intDigits === '' && fracDigits === '') return null;
  return sign * hexFloatValue(intDigits, fracDigits, m[6] === undefined ? 0 : Number(m[6]));
}

/**
 * Swift's `Double.description` (also `String(d)`): the shortest digits that read back as the same
 * double; exponential below 1e-4 or above 2^53, with at least two exponent digits ("1e-05").
 */
export function doubleDescription(d) {
  if (Number.isNaN(d)) return 'nan';
  if (d === Infinity) return 'inf';
  if (d === -Infinity) return '-inf';
  if (d === 0) return Object.is(d, -0) ? '-0.0' : '0.0';
  const sign = d < 0 ? '-' : '';
  const [mantissa, exponentText] = Math.abs(d).toExponential().split('e');
  const digits = mantissa.replace('.', '');
  const exponent = Number(exponentText);
  if (exponent < -4 || Math.abs(d) > 2 ** 53) {
    const m = digits.length > 1 ? `${digits[0]}.${digits.slice(1)}` : digits;
    return `${sign}${m}e${exponent < 0 ? '-' : '+'}${String(Math.abs(exponent)).padStart(2, '0')}`;
  }
  if (exponent < 0) return `${sign}0.${'0'.repeat(-exponent - 1)}${digits}`;
  if (digits.length <= exponent + 1) return `${sign}${digits}${'0'.repeat(exponent + 1 - digits.length)}.0`;
  return `${sign}${digits.slice(0, exponent + 1)}.${digits.slice(exponent + 1)}`;
}

/**
 * How SlatedCore prints a number it shows to people or stores as text: whole numbers below 1e15
 * without a fraction, everything else as Swift's description.
 */
export function shortNumber(d) {
  return Number.isFinite(d) && d === Math.round(d) && Math.abs(d) < 1e15 ? String(Math.trunc(d) || 0) : doubleDescription(d);
}

/** `Double.rounded(.towardZero)`. */
export function truncate(d) {
  return Math.trunc(d);
}

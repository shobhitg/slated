// JSON the way Slated's Swift code reads and writes config.json (private module).
//
// - `parseJSON5` reads the JSON5 dialect of Foundation's JSONDecoder (`allowsJSON5 = true`): comments,
//   trailing commas, unquoted keys, single quotes, hex numbers, Infinity/NaN. Where Foundation differs
//   from the JSON5 spec, this follows Foundation (golden vectors in /fixtures/config.json pin it):
//   no `\0` or unknown escapes, raw control characters are errors, a line continuation keeps the line
//   break, only ASCII whitespace (plus a leading BOM), and the first of two equal keys wins.
// - Numbers stay as text (`JSONNumber`) until a decoder asks for a Double or an Int, because
//   Foundation converts them differently for each type (e.g. `0x1p4` is a valid Int but not a Double).
// - `formatJSON` writes what JSONEncoder writes with `.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`.

import {SlatedError} from './errors.js';
import {compareStrings, doubleDescription, hexFloatValue, intValue} from './text.js';

/** A number as written in JSON5 text; converted on demand with `toDouble`/`toInt`. */
export class JSONNumber {
  constructor(raw) {
    this.raw = raw;
  }
}

/** Thrown for JSON text Foundation can't read at all (as opposed to a value of the wrong type). */
function syntaxError(message, offset) {
  return new SlatedError('invalidConfiguration', `${message} (at offset ${offset})`, {codingPath: [], offset});
}

const WHITESPACE = new Set([' ', '\t', '\n', '\r', '\v', '\f']);
const NUMBER_START = /^[0-9+\-.IN]$/;
const NUMBER_PART = /^[0-9A-Za-z.+\-]$/;
const HEX = /^[0-9a-fA-F]$/;
const KEY_START = /^[\p{Lu}\p{Ll}\p{Lt}\p{Lm}\p{Lo}\p{Nl}$_\\]$/u;
const KEY_PART = /^[\p{Lu}\p{Ll}\p{Lt}\p{Lm}\p{Lo}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}$_\\\u200C\u200D]$/u;

/**
 * Parses JSON5 text into plain values: null-prototype objects, arrays, strings, booleans, null and
 * `JSONNumber`s. Throws SlatedError('invalidConfiguration') for malformed text.
 */
export function parseJSON5(text) {
  let i = text.startsWith('\uFEFF') ? 1 : 0;

  const fail = (message) => {
    throw syntaxError(message, i);
  };

  function skipSpace() {
    for (;;) {
      const c = text[i];
      if (WHITESPACE.has(c)) {
        i++;
      } else if (c === '/' && text[i + 1] === '/') {
        i += 2;
        while (i < text.length && text[i] !== '\n' && text[i] !== '\r') i++;
      } else if (c === '/' && text[i + 1] === '*') {
        const end = text.indexOf('*/', i + 2);
        if (end < 0) fail('Unterminated block comment');
        i = end + 2;
      } else {
        return;
      }
    }
  }

  function hexDigits(count) {
    const digits = text.slice(i, i + count);
    if (digits.length < count || ![...digits].every((c) => HEX.test(c))) fail('Invalid escape sequence');
    i += count;
    return parseInt(digits, 16);
  }

  /** `\uXXXX` (with surrogate pairs) or `\xXX`, the backslash and letter already consumed. */
  function escapedScalar(letter) {
    if (letter === 'x') {
      const value = hexDigits(2);
      if (value === 0) fail('Invalid escaped null value');
      return String.fromCharCode(value);
    }
    const unit = hexDigits(4);
    if (unit >= 0xdc00 && unit <= 0xdfff) fail('Unexpected low surrogate');
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (text[i] !== '\\' || text[i + 1] !== 'u') fail('Missing low surrogate');
      i += 2;
      const low = hexDigits(4);
      if (low < 0xdc00 || low > 0xdfff) fail('Invalid low surrogate');
      return String.fromCharCode(unit, low);
    }
    return String.fromCharCode(unit);
  }

  function parseString(quote) {
    i++;
    let out = '';
    for (;;) {
      if (i >= text.length) fail('Unterminated string');
      const c = text[i];
      if (c === quote) {
        i++;
        return out;
      }
      if (c.charCodeAt(0) < 0x20) fail('Unescaped control character in string');
      if (c !== '\\') {
        out += c;
        i++;
        continue;
      }
      const e = text[i + 1];
      i += 2;
      switch (e) {
        case '"': case "'": case '\\': case '/': out += e; break;
        case 'b': out += '\b'; break;
        case 'f': out += '\f'; break;
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        case 't': out += '\t'; break;
        case 'u': case 'x': out += escapedScalar(e); break;
        case '\n': out += '\n'; break;
        case '\r':
          if (text[i] === '\n') {
            out += '\r\n';
            i++;
          } else {
            out += '\r';
          }
          break;
        default:
          i -= 2;
          fail('Invalid escape sequence');
      }
    }
  }

  function parseIdentifier() {
    let out = '';
    let first = true;
    for (;;) {
      const cp = text.codePointAt(i);
      if (cp === undefined) break;
      const c = String.fromCodePoint(cp);
      if (!(first ? KEY_START : KEY_PART).test(c)) break;
      if (c === '\\') {
        const e = text[i + 1];
        if (e !== 'u' && e !== 'x') fail('Invalid escape sequence in key');
        i += 2;
        out += escapedScalar(e);
      } else {
        out += c;
        i += c.length;
      }
      first = false;
    }
    if (first) fail('Expected a key');
    return out;
  }

  function parseKey() {
    const c = text[i];
    if (c === '"' || c === "'") return parseString(c);
    return parseIdentifier();
  }

  function parseObject() {
    i++;
    const object = Object.create(null);
    const seen = new Set();
    skipSpace();
    if (text[i] === '}') {
      i++;
      return object;
    }
    for (;;) {
      const key = parseKey();
      skipSpace();
      if (text[i] !== ':') fail('Expected ":"');
      i++;
      skipSpace();
      const value = parseValue();
      // Foundation keeps the first of two keys that are equal as Swift strings.
      const normalized = key.normalize('NFC');
      if (!seen.has(normalized)) {
        seen.add(normalized);
        object[key] = value;
      }
      skipSpace();
      if (text[i] === ',') {
        i++;
        skipSpace();
        if (text[i] === '}') {
          i++;
          return object;
        }
      } else if (text[i] === '}') {
        i++;
        return object;
      } else {
        fail('Expected "," or "}"');
      }
    }
  }

  function parseArray() {
    i++;
    const array = [];
    skipSpace();
    if (text[i] === ']') {
      i++;
      return array;
    }
    for (;;) {
      array.push(parseValue());
      skipSpace();
      if (text[i] === ',') {
        i++;
        skipSpace();
        if (text[i] === ']') {
          i++;
          return array;
        }
      } else if (text[i] === ']') {
        i++;
        return array;
      } else {
        fail('Expected "," or "]"');
      }
    }
  }

  function literal(word, value) {
    if (text.startsWith(word, i)) {
      i += word.length;
      return value;
    }
    return fail('Unexpected character');
  }

  function parseValue() {
    const c = text[i];
    if (c === '{') return parseObject();
    if (c === '[') return parseArray();
    if (c === '"' || c === "'") return parseString(c);
    if (c === 't') return literal('true', true);
    if (c === 'f') return literal('false', false);
    if (c === 'n') return literal('null', null);
    if (c !== undefined && NUMBER_START.test(c)) {
      // Foundation reads letters, digits and . + - as one number, then validates it on conversion.
      const start = i++;
      while (i < text.length && NUMBER_PART.test(text[i])) i++;
      return new JSONNumber(text.slice(start, i));
    }
    return fail(c === undefined ? 'Unexpected end of text' : 'Unexpected character');
  }

  skipSpace();
  const value = parseValue();
  skipSpace();
  if (i < text.length) fail('Unexpected text after the end');
  return value;
}

// --- Number conversion (Foundation's JSON5 rules) --------------------------------------------------

const DIGIT = /^[0-9]$/;
const isDigit = (c) => c !== undefined && DIGIT.test(c);
const DECIMAL = /^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/;
const HEX_FLOAT = /^([+-]?)0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?[0-9]+))?$/;

class NumberFormatError extends Error {}

/** Foundation's prevalidation of a JSON5 number: leading zeros, signs, Infinity/NaN, trailing exponent. */
function prevalidate(raw) {
  let isHex = false;
  let special = false;
  const leadingZero = (rest) => {
    if (rest === '') return;
    const c = rest[0];
    if (c === '.' || c === 'e' || c === 'E') return;
    if ((c === 'x' || c === 'X') && rest[1] !== undefined && HEX.test(rest[1])) {
      isHex = true;
      return;
    }
    throw new NumberFormatError(raw);
  };
  const leadingDecimal = (rest) => {
    if (!isDigit(rest[0])) throw new NumberFormatError(raw);
  };
  const c = raw[0];
  if (c === '0') leadingZero(raw.slice(1));
  else if (isDigit(c)) {
    // fine
  } else if (c === '-' || c === '+') {
    const next = raw[1];
    if (next === '0') leadingZero(raw.slice(2));
    else if (isDigit(next)) {
      // fine
    } else if (next === 'I' || next === 'N') {
      if (raw.slice(1) !== (next === 'I' ? 'Infinity' : 'NaN')) throw new NumberFormatError(raw);
      special = true;
    } else if (next === '.') leadingDecimal(raw.slice(2));
    else throw new NumberFormatError(raw);
  } else if (c === 'I' || c === 'N') {
    if (raw !== (c === 'I' ? 'Infinity' : 'NaN')) throw new NumberFormatError(raw);
    special = true;
  } else if (c === '.') {
    leadingDecimal(raw.slice(1));
  } else {
    throw new NumberFormatError(raw);
  }
  if (!isHex && !special && /[eE+\-]$/.test(raw)) throw new NumberFormatError(raw);
  return {isHex, special};
}

/** Foundation's underflow check. It reads 4-byte chunks forward but the leftover bytes backward. */
function isTrueZero(raw) {
  const n = raw.length;
  let i = 0;
  const decide = (c) => (c >= '1' && c <= '9' ? false : c === 'e' || c === 'E' ? true : null);
  for (; i + 4 <= n; i += 4) {
    for (let j = i; j < i + 4; j++) {
      const d = decide(raw[j]);
      if (d !== null) return d;
    }
  }
  for (let j = n - 1; j >= i; j--) {
    const d = decide(raw[j]);
    if (d !== null) return d;
  }
  return true;
}

/** C's strtod over the whole text (decimal, or hexadecimal with optional fraction and exponent). */
function strtodFull(raw) {
  if (DECIMAL.test(raw)) return Number(raw);
  const m = HEX_FLOAT.exec(raw);
  if (!m || (m[2] === '' && (m[3] ?? '') === '')) return null;
  const value = hexFloatValue(m[2], m[3] ?? '', m[4] === undefined ? 0 : Number(m[4]));
  return m[1] === '-' ? -value : value;
}

const INT_MIN = -(2n ** 63n);
const INT_MAX = 2n ** 63n - 1n;
const UINT64_MAX = 2n ** 64n - 1n;

function hexMagnitude(raw) {
  const digits = raw.replace(/^[+-]/, '').slice(2);
  if (digits === '' || ![...digits].every((c) => HEX.test(c))) return null;
  return BigInt(`0x${digits}`);
}

/** The JSON5 number as a Double, or throws NumberFormatError. */
function json5Double(raw) {
  const {isHex, special} = prevalidate(raw);
  if (special) return raw.includes('NaN') ? NaN : raw[0] === '-' ? -Infinity : Infinity;
  if (isHex) {
    const negative = raw[0] === '-';
    const magnitude = hexMagnitude(raw);
    if (magnitude === null || magnitude > (negative ? 2n ** 63n : UINT64_MAX)) throw new NumberFormatError(raw);
    const d = Number(magnitude);
    if (BigInt(d) !== magnitude) throw new NumberFormatError(raw);
    return negative && d !== 0 ? -d : d;
  }
  if (!DECIMAL.test(raw)) throw new NumberFormatError(raw);
  const d = Number(raw);
  if (!Number.isFinite(d)) throw new NumberFormatError(raw);
  if (d === 0 && !isTrueZero(raw)) throw new NumberFormatError(raw);
  return d;
}

/** An exact decimal integer for values beyond 2^53 (Foundation goes through Decimal). */
function exactDecimalInteger(raw) {
  const m = /^([+-]?)([0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?$/.exec(raw);
  if (!m) return null;
  let digits = (m[2] ?? '') + (m[3] ?? '');
  let exponent = Number(m[4] ?? 0) - (m[3] ?? '').length;
  digits = digits.replace(/^0+(?=.)/, '');
  if (exponent < 0) {
    const cut = digits.length + exponent;
    if (cut < 0 || /[^0]/.test(digits.slice(Math.max(cut, 0)))) return null;
    digits = digits.slice(0, cut) || '0';
    exponent = 0;
  }
  if (exponent > 40) return null;
  let value = BigInt(digits) * 10n ** BigInt(exponent);
  if (m[1] === '-') value = -value;
  return value;
}

/** The JSON5 number as a Swift Int (number, or BigInt beyond 2^53), or throws NumberFormatError. */
function json5Int(raw) {
  const {isHex, special} = prevalidate(raw);
  const negative = raw[0] === '-';
  const body = raw.replace(/^[+-]/, '');
  let fast = null;
  if (isHex) {
    const magnitude = hexMagnitude(raw);
    if (magnitude !== null) fast = negative ? -magnitude : magnitude;
  } else if (/^[0-9]+$/.test(body)) {
    fast = negative ? -BigInt(body) : BigInt(body);
  }
  if (fast !== null && fast >= INT_MIN && fast <= INT_MAX) return intValue(fast);
  if (special) throw new NumberFormatError(raw);
  const d = strtodFull(raw);
  if (d === null || !Number.isFinite(d)) throw new NumberFormatError(raw);
  if (Math.abs(d) < 2 ** 53) {
    if (!Number.isInteger(d)) throw new NumberFormatError(raw);
    return d === 0 ? 0 : d;
  }
  if (isHex) throw new NumberFormatError(raw);
  const exact = exactDecimalInteger(raw);
  if (exact === null || exact < INT_MIN || exact > INT_MAX) throw new NumberFormatError(raw);
  return intValue(exact);
}

/** True for a number from JSON5 text or a JavaScript number. */
export function isNumberValue(value) {
  return value instanceof JSONNumber || typeof value === 'number' || typeof value === 'bigint';
}

/** A JSON number as a Double; null when Foundation couldn't read it as one. */
export function asDouble(value) {
  if (typeof value === 'number') return value;
  if (typeof value === 'bigint') return Number(value);
  if (value instanceof JSONNumber) {
    try {
      return json5Double(value.raw);
    } catch (e) {
      if (e instanceof NumberFormatError) return null;
      throw e;
    }
  }
  return null;
}

/** A JSON number as a Swift Int (number or BigInt); null when it isn't a whole number in range. */
export function asInt(value) {
  if (typeof value === 'bigint') return value >= INT_MIN && value <= INT_MAX ? intValue(value) : null;
  if (typeof value === 'number') {
    if (!Number.isInteger(value) || value >= 2 ** 63 || value < -(2 ** 63)) return null;
    return value === 0 ? 0 : value;
  }
  if (value instanceof JSONNumber) {
    try {
      return json5Int(value.raw);
    } catch (e) {
      if (e instanceof NumberFormatError) return null;
      throw e;
    }
  }
  return null;
}

// --- Writing ---------------------------------------------------------------------------------------

/** A string literal as JSONEncoder writes it (control characters as lowercase \u00xx, `/` as is). */
export function quoteJSON(s) {
  let out = '"';
  for (let k = 0; k < s.length; k++) {
    const c = s[k];
    const code = s.charCodeAt(k);
    if (c === '"') out += '\\"';
    else if (c === '\\') out += '\\\\';
    else if (code < 0x20) {
      if (c === '\n') out += '\\n';
      else if (c === '\r') out += '\\r';
      else if (c === '\t') out += '\\t';
      else if (c === '\b') out += '\\b';
      else if (c === '\f') out += '\\f';
      else out += `\\u${code.toString(16).padStart(4, '0')}`;
    } else out += c;
  }
  return `${out}"`;
}

/** A number as JSONEncoder writes it: Swift's description without a trailing ".0". */
export function numberJSON(value, path = []) {
  if (typeof value === 'bigint') return String(value);
  if (!Number.isFinite(value)) {
    throw new SlatedError('invalidConfiguration', `Unable to encode ${doubleDescription(value)} directly in JSON.`, {
      codingPath: path,
    });
  }
  const text = doubleDescription(value);
  return text.endsWith('.0') ? text.slice(0, -2) : text;
}

/**
 * Pretty JSON with sorted keys, exactly as Swift's JSONEncoder writes it with `.prettyPrinted,
 * .sortedKeys, .withoutEscapingSlashes`: two-space indents, `"key" : value`, and empty containers
 * written over two lines. `undefined` members are left out, like Swift optionals.
 */
export function formatJSON(value) {
  return write(value, '', []);
}

function write(value, indent, path) {
  if (value === null) return 'null';
  if (typeof value === 'string') return quoteJSON(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number' || typeof value === 'bigint') return numberJSON(value, path);
  if (value instanceof JSONNumber) return numberJSON(asDouble(value), path);
  const inner = `${indent}  `;
  if (Array.isArray(value)) {
    if (value.length === 0) return `[\n\n${indent}]`;
    return `[\n${value.map((item, k) => inner + write(item, inner, [...path, k])).join(',\n')}\n${indent}]`;
  }
  const keys = Object.keys(value)
    .filter((k) => value[k] !== undefined)
    .sort(compareStrings);
  if (keys.length === 0) return `{\n\n${indent}}`;
  return `{\n${keys.map((k) => `${inner}${quoteJSON(k)} : ${write(value[k], inner, [...path, k])}`).join(',\n')}\n${indent}}`;
}

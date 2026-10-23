// Words of Slate operation syntax (private module; port of SlateTokenizer.swift).
//
// Whitespace separates words. '…' and "…" quote a stretch of text (spaces included) and the quote
// marks are dropped; the other kind of quote is literal inside. Quoted stretches join the text
// around them, as in a shell. There are no backslash escapes, matching Slate. Columns count
// characters (grapheme clusters), 1-based.

import {invalidSyntax} from './errors.js';
import {graphemes, isWhitespace, trimWhitespaceAndNewlines} from './text.js';

const isQuote = (c) => c === "'" || c === '"';

/** @returns {{text: string, raw: string, isQuoted: boolean, column: number}[]} */
export function tokenize(string) {
  return leadingTokens(string, Infinity).tokens;
}

/** The first `count` words of `string`, plus the rest of the string (trimmed) after them. */
export function leadingTokens(string, count) {
  const chars = graphemes(string);
  const tokens = [];
  let i = 0;
  while (i < chars.length && tokens.length < count) {
    if (isWhitespace(chars[i])) {
      i++;
      continue;
    }
    const start = i;
    let text = '';
    let quoted = false;
    let quote = null;
    let quoteColumn = 0;
    while (i < chars.length) {
      const c = chars[i];
      if (quote !== null) {
        if (c === quote) quote = null;
        else text += c;
      } else if (isWhitespace(c)) {
        break;
      } else if (isQuote(c)) {
        quote = c;
        quoted = true;
        quoteColumn = i + 1;
      } else {
        text += c;
      }
      i++;
    }
    if (quote !== null) {
      throw invalidSyntax(`Missing closing ${quote} for the quote at column ${quoteColumn} in "${string}"`);
    }
    tokens.push({text, raw: chars.slice(start, i).join(''), isQuoted: quoted, column: start + 1});
  }
  const rest = trimWhitespaceAndNewlines(chars.slice(Math.min(i, chars.length)).join(''));
  return {tokens, rest};
}

/**
 * Splits `string` at any of `separators` (a string of separator characters) outside quotes.
 * @returns {{separator: string|null, text: string}[]} each piece trimmed, quotes left in place
 */
export function split(string, separators) {
  const pieces = [];
  let current = '';
  let separator = null;
  let quote = null;
  let quoteColumn = 0;
  graphemes(string).forEach((c, index) => {
    if (quote !== null) {
      if (c === quote) quote = null;
      current += c;
    } else if (separators.includes(c) && c.length === 1) {
      pieces.push({separator, text: trimWhitespaceAndNewlines(current)});
      current = '';
      separator = c;
    } else {
      if (isQuote(c)) {
        quote = c;
        quoteColumn = index + 1;
      }
      current += c;
    }
  });
  if (quote !== null) throw invalidSyntax(`Missing closing ${quote} for the quote at column ${quoteColumn} in "${string}"`);
  pieces.push({separator, text: trimWhitespaceAndNewlines(current)});
  return pieces;
}

/** Index (in characters) of the first `character` outside quotes, or -1. */
export function firstIndexOutsideQuotes(string, character) {
  let quote = null;
  const chars = graphemes(string);
  for (let index = 0; index < chars.length; index++) {
    const c = chars[index];
    if (quote !== null) {
      if (c === quote) quote = null;
    } else if (c === character) {
      return index;
    } else if (isQuote(c)) {
      quote = c;
    }
  }
  return -1;
}

/** Splits `string` around the first `character` outside quotes: [before, after], or null. */
export function splitAtOutsideQuotes(string, character) {
  const index = firstIndexOutsideQuotes(string, character);
  if (index < 0) return null;
  const chars = graphemes(string);
  return [chars.slice(0, index).join(''), chars.slice(index + 1).join('')];
}

/** Removes quoting from a single word: `'Google Chrome'` → `Google Chrome`; other text comes back trimmed. */
export function unquote(string) {
  const trimmed = trimWhitespaceAndNewlines(string);
  let tokens;
  try {
    tokens = tokenize(trimmed);
  } catch {
    return trimmed;
  }
  return tokens.length === 1 && tokens[0].raw === trimmed ? tokens[0].text : trimmed;
}

/** Quotes `string` so `tokenize` reads it back as exactly one word with the same text. */
export function quote(string) {
  const chars = graphemes(string);
  if (!chars.includes("'")) return `'${string}'`;
  if (!chars.includes('"')) return `"${string}"`;
  let result = '';
  let piece = '';
  let pieceHasSingle = false;
  let pieceHasDouble = false;
  const flush = () => {
    if (piece === '') return;
    result += pieceHasSingle ? `"${piece}"` : `'${piece}'`;
    piece = '';
    pieceHasSingle = false;
    pieceHasDouble = false;
  };
  for (const c of chars) {
    if ((c === "'" && pieceHasDouble) || (c === '"' && pieceHasSingle)) flush();
    if (c === "'") pieceHasSingle = true;
    if (c === '"') pieceHasDouble = true;
    piece += c;
  }
  flush();
  return result;
}

const SPECIAL = new Set(["'", '"', '|', '>', '#', ',']);

/** `string` as is when it reads back as one word with the same text, otherwise quoted. */
export function quoteIfNeeded(string) {
  if (string === '' || graphemes(string).some((c) => isWhitespace(c) || SPECIAL.has(c))) return quote(string);
  return string;
}
